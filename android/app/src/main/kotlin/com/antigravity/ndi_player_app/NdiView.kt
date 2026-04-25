package com.antigravity.ndi_player_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import android.view.View
import io.flutter.plugin.platform.PlatformView
import android.util.Log

class NdiView(context: Context, id: Int, private val creationParams: Map<String?, Any?>?) : PlatformView {
    private val textureView: TextureView = TextureView(context)
    private var isRunning = true
    private var pInstance: Long = 0
    private var lastFrameTime: Long = System.currentTimeMillis()
    private var isRecovering = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    
    // Audio Player
    private var audioTrack: AudioTrack? = null
    private val isMuted = creationParams?.get("muted") as? Boolean ?: false

    // Quality settings
    private var currentQuality = creationParams?.get("quality") as? String ?: "480p"
    private var sourceName = creationParams?.get("name") as? String ?: ""

    init {
        if (!isMuted) setupAudioTrack()
        
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                synchronized(lock) {
                    pInstance = createReceiver(sourceName, currentQuality == "480p")
                }
                startNativeReceiverLoop()
                if (!isMuted) startAudioLoop()
            }
            override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, w: Int, h: Int) {}
            override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                isRunning = false
                synchronized(lock) {
                    if (pInstance != 0L) {
                        destroyReceiver(pInstance)
                        pInstance = 0
                    }
                }
                audioTrack?.stop()
                audioTrack?.release()
                return true
            }
            override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
        }
    }

    private fun setupAudioTrack() {
        try {
            val minBufSize = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
            
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                audioTrack = AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build())
                    .setAudioFormat(AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(48000)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build())
                    .setBufferSizeInBytes(minBufSize * 2)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            } else {
                // Pre-Marshmallow fallback
                @Suppress("DEPRECATION")
                audioTrack = AudioTrack(
                    android.media.AudioManager.STREAM_MUSIC,
                    48000,
                    AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_FLOAT,
                    minBufSize * 2,
                    AudioTrack.MODE_STREAM
                )
            }

            audioTrack?.play()
            Log.d("NDIView", "AudioTrack initialized successfully.")
        } catch (e: Exception) {
            Log.e("NDIView", "AudioTrack creation failed: ${e.message}")
        }
    }


    override fun getView(): View = textureView

    override fun dispose() {
        isRunning = false
        synchronized(lock) {
            if (pInstance != 0L) {
                destroyReceiver(pInstance)
                pInstance = 0
            }
        }
        audioTrack?.stop()
        audioTrack?.release()
    }

    private fun startAudioLoop() {
        Thread {
            while (isRunning) {
                var ptr: Long = 0
                synchronized(lock) { ptr = pInstance }
                
                if (ptr != 0L) {
                    val floatData = captureAudio(ptr)
                    // The JNI now always sends INTERLEAVED STEREO data
                    if (floatData != null && floatData.isNotEmpty()) {
                        audioTrack?.write(floatData, 0, floatData.size, AudioTrack.WRITE_BLOCKING)
                    } else {
                        try { Thread.sleep(5) } catch (e: Exception) {}
                    }
                } else {
                    try { Thread.sleep(100) } catch (e: Exception) {}
                }
            }
        }.start()
    }

    private fun startNativeReceiverLoop() {
        Thread {
            var targetW = if (currentQuality == "480p") 960 else 1920
            var targetH = if (currentQuality == "480p") 540 else 1080
            var bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            
            while (isRunning) {
                var ptr: Long = 0
                synchronized(lock) { ptr = pInstance }

                if (ptr != 0L) {
                    val captured = captureFrameToBitmap(ptr, bitmap)
                    if (captured == 1) {
                        lastFrameTime = System.currentTimeMillis()
                        drawToSurface(bitmap)
                    } else if (captured == -1) {
                        val res = getFrameResolution(ptr)
                        if (res[0] > 0 && res[1] > 0 && (res[0] != targetW || res[1] != targetH)) {
                            targetW = res[0]
                            targetH = res[1]
                            bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                            lastFrameTime = System.currentTimeMillis()
                        }
                    } else {
                        if (System.currentTimeMillis() - lastFrameTime > 3000 && !isRecovering) {
                            performAutoRecovery()
                        }
                        try { Thread.sleep(2) } catch (e: Exception) {}
                    }
                }
            }
        }.start()
    }

    private fun drawToSurface(bitmap: Bitmap) {
        val canvas: Canvas? = textureView.lockCanvas()
        if (canvas != null) {
            try {
                canvas.drawBitmap(bitmap, null, android.graphics.Rect(0, 0, textureView.width, textureView.height), null)
            } finally {
                textureView.unlockCanvasAndPost(canvas)
            }
        }
    }

    private fun performAutoRecovery() {
        if (isRecovering) return
        isRecovering = true
        mainHandler.post {
            synchronized(lock) {
                if (pInstance != 0L) destroyReceiver(pInstance)
                pInstance = createReceiver(sourceName, currentQuality == "480p")
                lastFrameTime = System.currentTimeMillis()
                Log.d("NDIView", "Reconnection attempted.")
            }
            isRecovering = false
        }
    }

    private external fun createReceiver(name: String, lowBandwidth: Boolean): Long
    private external fun destroyReceiver(pInstance: Long)
    private external fun getFrameResolution(pInstance: Long): IntArray
    private external fun captureFrameToBitmap(pInstance: Long, bitmap: Bitmap): Int
    private external fun captureAudio(pInstance: Long): FloatArray?
}
