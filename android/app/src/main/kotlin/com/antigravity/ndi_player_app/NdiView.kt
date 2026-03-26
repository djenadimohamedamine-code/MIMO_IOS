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
import io.flutter.plugin.platform.PlatformView
import android.util.Log

class NdiView(context: Context, id: Int, private val creationParams: Map<String?, Any?>?) : PlatformView {
    private val textureView: TextureView = TextureView(context)
    private var isRunning = true
    private var pInstance: Long = 0
    private var lastFrameTime: Long = System.currentTimeMillis()
    private var isRecovering = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any() // Safety Lock for pInstance pointer
    
    // Quality settings
    private var currentQuality = creationParams?.get("quality") as? String ?: "480p"
    private var sourceName = creationParams?.get("name") as? String ?: ""

    init {
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                synchronized(lock) {
                    pInstance = createReceiver(sourceName, currentQuality == "480p")
                    Log.d("NDIView", "Receiver initialisé (Ptr: $pInstance). Source: $sourceName")
                }
                startNativeReceiverLoop()
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
                return true
            }
            override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
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
    }

    private fun startNativeReceiverLoop() {
        Thread {
            // Initialisation avec une taille par défaut (sera corrigée dès la 1ère frame)
            var targetW = if (currentQuality == "480p") 960 else 1920
            var targetH = if (currentQuality == "480p") 540 else 1080
            var bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
            
            Log.d("NDIView", "Boucle de capture démarrée en ${targetW}x${targetH}")

            while (isRunning) {
                var ptr: Long = 0
                synchronized(lock) { ptr = pInstance }

                if (ptr != 0L) {
                    // Tente de capturer la frame
                    val captured = captureFrameToBitmap(ptr, bitmap)
                    
                    if (captured == 1) {
                        lastFrameTime = System.currentTimeMillis()
                        drawToSurface(bitmap)
                    } else if (captured == -1) {
                        // 🛠️ RÉSOLUTION DYNAMIQUE : Le C++ signale une taille différente
                        val res = getFrameResolution(ptr)
                        if (res[0] > 0 && res[1] > 0 && (res[0] != targetW || res[1] != targetH)) {
                            Log.w("NDIView", "⚡ Changement de résolution détecté : ${res[0]}x${res[1]} (Ancien: ${targetW}x${targetH})")
                            targetW = res[0]
                            targetH = res[1]
                            bitmap = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                            lastFrameTime = System.currentTimeMillis() // Reset du timeout car la source est active
                        }
                    } else {
                        // Auto-Heal (Reconnexion si pas de frame pendant 3s)
                        if (System.currentTimeMillis() - lastFrameTime > 3000 && !isRecovering) {
                            performAutoRecovery()
                        }
                    }
                }
                try { Thread.sleep(2) } catch (e: Exception) {}
            }
        }.start()
    }

    private fun drawToSurface(bitmap: Bitmap) {
        val canvas: Canvas? = textureView.lockCanvas()
        if (canvas != null) {
            try {
                // Dessine en adaptant à la taille du TextureView (Stretch/Scale)
                canvas.drawBitmap(bitmap, null, android.graphics.Rect(0, 0, textureView.width, textureView.height), null)
            } finally {
                textureView.unlockCanvasAndPost(canvas)
            }
        }
    }

    private fun performAutoRecovery() {
        if (isRecovering) return
        isRecovering = true
        Log.w("NDIView", "⚠️ Signal perdu. Tentative de reconnexion auto...")
        
        mainHandler.post {
            synchronized(lock) {
                if (pInstance != 0L) destroyReceiver(pInstance)
                pInstance = createReceiver(sourceName, currentQuality == "480p")
                lastFrameTime = System.currentTimeMillis()
            }
            isRecovering = false
        }
    }

    // JNI Native Methods
    private external fun createReceiver(name: String, lowBandwidth: Boolean): Long
    private external fun destroyReceiver(pInstance: Long)
    private external fun getFrameResolution(pInstance: Long): IntArray
    private external fun captureFrameToBitmap(pInstance: Long, bitmap: Bitmap): Int
}
