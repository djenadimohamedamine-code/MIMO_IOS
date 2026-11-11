package com.antigravity.ndi_player_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView

class NdiView(
    context: Context, 
    private val viewId: Int, 
    private val creationParams: Map<String?, Any?>?,
    binaryMessenger: BinaryMessenger?
) : PlatformView, MethodChannel.MethodCallHandler {

    private val textureView: TextureView = TextureView(context)
    private var isRunning = true
    private var pInstance: Long = 0
    private var lastFrameTime: Long = System.currentTimeMillis()
    private var isRecovering = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    
    // Audio Player
    private var audioTrack: AudioTrack? = null
    private var isMuted = creationParams?.get("muted") as? Boolean ?: false

    // Quality settings
    private var currentQuality = creationParams?.get("quality") as? String ?: "Highest"
    private var sourceName = creationParams?.get("name") as? String ?: ""

    private var methodChannel: MethodChannel? = null

    init {
        if (binaryMessenger != null) {
            methodChannel = MethodChannel(binaryMessenger, "com.antigravity/ndi_view_$viewId")
            methodChannel?.setMethodCallHandler(this)
        }

        if (!isMuted) setupAudioTrack()
        
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                synchronized(lock) {
                    if (pInstance == 0L) {
                        pInstance = createReceiver(sourceName, currentQuality == "480p")
                    }
                }
                startUnifiedCaptureLoop()
            }
            override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, w: Int, h: Int) {}
            override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                stopPlayback()
                return true
            }
            override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stop", "dispose" -> {
                stopPlayback()
                result.success(true)
            }
            "setMuted" -> {
                val m = call.arguments as? Boolean ?: false
                isMuted = m
                if (isMuted) {
                    audioTrack?.pause()
                    audioTrack?.flush()
                } else {
                    if (audioTrack == null) setupAudioTrack()
                    audioTrack?.play()
                }
                result.success(true)
            }
            "switchQuality" -> {
                val q = call.arguments as? String ?: "Highest"
                currentQuality = q
                synchronized(lock) {
                    if (pInstance != 0L) {
                        destroyReceiver(pInstance)
                        pInstance = createReceiver(sourceName, currentQuality == "480p")
                        lastFrameTime = System.currentTimeMillis()
                    }
                }
                result.success(true)
            }
            "refreshSources" -> {
                NDIManager.refreshSources()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun setupAudioTrack() {
        try {
            val minBufSize = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_FLOAT)
            val bufSize = if (minBufSize > 0) minBufSize * 2 else 4096 * 4

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
                    .setBufferSizeInBytes(bufSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                audioTrack = AudioTrack(
                    android.media.AudioManager.STREAM_MUSIC,
                    48000,
                    AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_FLOAT,
                    bufSize,
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

    private fun stopPlayback() {
        isRunning = false
        synchronized(lock) {
            if (pInstance != 0L) {
                destroyReceiver(pInstance)
                pInstance = 0
            }
        }
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
            audioTrack = null
        } catch (e: Exception) {}
    }

    override fun dispose() {
        stopPlayback()
        methodChannel?.setMethodCallHandler(null)
    }

    private fun startUnifiedCaptureLoop() {
        Thread {
            var targetW = 1920
            var targetH = 1080
            var bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            val dim = IntArray(2)
            val audioHolder = arrayOfNulls<FloatArray>(1)

            while (isRunning) {
                var ptr: Long = 0
                synchronized(lock) { ptr = pInstance }

                if (ptr == 0L) {
                    try { Thread.sleep(20) } catch (e: Exception) {}
                    continue
                }

                audioHolder[0] = null
                val result = captureFrame(ptr, bitmap, dim, audioHolder)

                if (result == 1) {
                    // Video frame received
                    lastFrameTime = System.currentTimeMillis()
                    drawToSurface(bitmap)
                } else if (result == 2) {
                    // Audio frame received
                    lastFrameTime = System.currentTimeMillis()
                    val floatData = audioHolder[0]
                    if (!isMuted && floatData != null && floatData.isNotEmpty()) {
                        audioTrack?.write(floatData, 0, floatData.size, AudioTrack.WRITE_NON_BLOCKING)
                    }
                } else if (result == -1) {
                    // Resolution changed!
                    val newW = dim[0]
                    val newH = dim[1]
                    if (newW > 0 && newH > 0 && (newW != targetW || newH != targetH)) {
                        Log.d("NDIView", "Adapting resolution dynamically to: ${newW}x${newH}")
                        targetW = newW
                        targetH = newH
                        bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                        lastFrameTime = System.currentTimeMillis()
                    }
                } else {
                    // Timeout (0)
                    if (System.currentTimeMillis() - lastFrameTime > 5000 && !isRecovering) {
                        performAutoRecovery()
                    }
                    try { Thread.sleep(1) } catch (e: Exception) {}
                }
            }
        }.apply {
            name = "NDICaptureThread"
            isDaemon = true
            start()
        }
    }

    private fun drawToSurface(bitmap: Bitmap) {
        if (!textureView.isAvailable) return
        val w = textureView.width
        val h = textureView.height
        if (w <= 0 || h <= 0) return

        val canvas: Canvas? = textureView.lockCanvas()
        if (canvas != null) {
            try {
                canvas.drawBitmap(bitmap, null, Rect(0, 0, w, h), null)
            } catch (e: Exception) {
                Log.e("NDIView", "drawBitmap error: ${e.message}")
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
                Log.d("NDIView", "Auto-recovery reconnection attempted.")
            }
            isRecovering = false
        }
    }

    private external fun createReceiver(name: String, lowBandwidth: Boolean): Long
    private external fun destroyReceiver(pInstance: Long)
    private external fun captureFrame(pInstance: Long, bitmap: Bitmap, outDim: IntArray, outAudio: Array<FloatArray?>): Int
}
