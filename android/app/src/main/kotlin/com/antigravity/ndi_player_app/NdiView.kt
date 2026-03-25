package com.antigravity.ndi_player_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.TextureView
import android.view.View
import android.view.Surface
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec

class NdiViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as Map<String?, Any?>?
        return NdiView(context, viewId, creationParams)
    }
}

class NdiView(context: Context, id: Int, creationParams: Map<String?, Any?>?) : PlatformView {
    private val textureView: TextureView = TextureView(context)
    private var isRendering = true

    init {
        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surfaceTexture: android.graphics.SurfaceTexture, width: Int, height: Int) {
                // Start a thread to pull frames from NDI and draw to surface
                startRenderThread(Surface(surfaceTexture))
            }

            override fun onSurfaceTextureSizeChanged(surface: android.graphics.SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: android.graphics.SurfaceTexture): Boolean {
                isRendering = false
                return true
            }
            override fun onSurfaceTextureUpdated(surface: android.graphics.SurfaceTexture) {}
        }
    }

    override fun getView(): View {
        return textureView
    }

    override fun dispose() {
        isRendering = false
    }

    private fun startRenderThread(surface: Surface) {
        Thread {
            while (isRendering) {
                // Here: Connect to LibNDI and pull a frame
                // Val bitmap = LibNDI.receiveFrame()
                
                // For now, this is a placeholder for the native rendering logic
                // Real implementation would lock the surface canvas and draw the pixel buffer
                try {
                    val canvas = surface.lockCanvas(null)
                    // Draw NDI frame content here
                    // Canvas?.drawBitmap(...) 
                    surface.unlockCanvasAndPost(canvas)
                } catch (e: Exception) {
                    // Silently fail if surface is gone
                }
                
                Thread.sleep(33) // ~30 fps
            }
        }.start()
    }
}
