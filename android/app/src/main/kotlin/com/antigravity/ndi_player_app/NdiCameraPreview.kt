package com.antigravity.ndi_player_app

import android.content.Context
import android.view.View
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NdiCameraPreview(private val context: Context) : PlatformView {
    private val previewView: PreviewView = PreviewView(context)
    private var cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    init {
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        startCamera()
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            val cameraProvider: ProcessCameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider.unbindAll()
                // On attache la preview au cycle de vie de l'activité Flask
                if (context is LifecycleOwner) {
                    cameraProvider.bindToLifecycle(context, cameraSelector, preview)
                }
            } catch (exc: Exception) {
                // Ignore for now
            }
        }, ContextCompat.getMainExecutor(context))
    }

    override fun getView(): View = previewView

    override fun dispose() {
        cameraExecutor.shutdown()
    }
}
