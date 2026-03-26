package com.antigravity.ndi_player_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import android.view.View
import android.view.Surface
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import android.util.Log

class NdiView(context: Context, id: Int, private val creationParams: Map<String?, Any?>?) : PlatformView {
    private val textureView: TextureView = TextureView(context)
    private var isRunning = true
    private var pInstance: Long = 0
    private var lastFrameTime: Long = System.currentTimeMillis()
    private var isRecovering = false
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Quality settings
    private var currentQuality = creationParams?.get("quality") as? String ?: "480p"
    private var sourceName = creationParams?.get("name") as? String ?: ""

    init {
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                pInstance = createReceiver(sourceName, currentQuality == "480p")
                startNativeReceiverLoop()
            }
            override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, w: Int, h: Int) {}
            override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                isRunning = false
                destroyReceiver(pInstance)
                return true
            }
            override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
        }
    }

    override fun getView(): View = textureView

    override fun dispose() {
        isRunning = false
        destroyReceiver(pInstance)
    }

    private fun startNativeReceiverLoop() {
        Thread {
            // Resolution-dependent Bitmap (Proxy uses small, Full uses large)
            val w = if (currentQuality == "480p") 960 else 1920
            val h = if (currentQuality == "480p") 540 else 1080
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            
            while (isRunning) {
                if (pInstance != 0L) {
                    val captured = captureFrameToBitmap(pInstance, bitmap)
                    if (captured == 1) {
                        lastFrameTime = System.currentTimeMillis()
                        drawToSurface(bitmap)
                    } else {
                        // Heartbeat Auto-Healing (2 seconds timeout)
                        if (System.currentTimeMillis() - lastFrameTime > 2000 && !isRecovering) {
                            performAutoRecovery()
                        }
                        Thread.sleep(10)
                    }
                } else {
                    Thread.sleep(100)
                }
            }
        }.start()
    }

    private fun drawToSurface(bitmap: Bitmap) {
        val canvas: Canvas? = textureView.lockCanvas()
        if (canvas != null) {
            canvas.drawBitmap(bitmap, null, android.graphics.Rect(0, 0, textureView.width, textureView.height), null)
            textureView.unlockCanvasAndPost(canvas)
        }
    }

    private fun performAutoRecovery() {
        if (isRecovering) return
        isRecovering = true
        Log.d("NDIView", "⚠️ Auto-Recovery system triggered. Retrying connection...")
        
        mainHandler.post {
            destroyReceiver(pInstance)
            pInstance = createReceiver(sourceName, currentQuality == "480p")
            lastFrameTime = System.currentTimeMillis()
            isRecovering = false
        }
    }

    // JNI Native Methods
    private external fun createReceiver(name: String, lowBandwidth: Boolean): Long
    private external fun destroyReceiver(pInstance: Long)
    private external fun captureFrameToBitmap(pInstance: Long, bitmap: Bitmap): Int
}
