package com.antigravity.ndi_player_app

import android.content.Context
import android.graphics.ImageFormat
import android.view.View
import android.view.ViewTreeObserver
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
    private var imageAnalysis: ImageAnalysis? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var cameraStarted = false

    @Volatile
    var isSending: Boolean = false
    private var sourceName: String = "MIMO_NDI Camera"

    companion object {
        @Volatile
        var currentInstance: NdiCameraPreview? = null
        @Volatile
        var pSender: Long = 0
    }

    init {
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        currentInstance = this
        previewView.viewTreeObserver.addOnGlobalLayoutListener(
            object : ViewTreeObserver.OnGlobalLayoutListener {
                override fun onGlobalLayout() {
                    if (previewView.width > 0 && previewView.height > 0 && !cameraStarted) {
                        previewView.viewTreeObserver.removeOnGlobalLayoutListener(this)
                        startCamera()
                    }
                }
            }
        )
    }

    fun initSender(name: String) {
        sourceName = name
        if (pSender != 0L) {
            destroySender(pSender)
            pSender = 0
        }
        pSender = createSender(name)
    }

    fun startSending() {
        isSending = true
    }

    fun stopSending() {
        isSending = false
    }

    fun destroySenderInstance() {
        isSending = false
        if (pSender != 0L) {
            destroySender(pSender)
            pSender = 0
        }
    }

    private fun startCamera() {
        cameraStarted = true
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
            val cp = cameraProvider ?: return@addListener

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            imageAnalysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setTargetResolution(android.util.Size(1280, 720))
                .build()

            imageAnalysis?.setAnalyzer(cameraExecutor) { imageProxy ->
                if (isSending && pSender != 0L) {
                    val rgba = yuv420ToRgba(imageProxy)
                    if (rgba != null) {
                        sendVideoFrame(pSender, imageProxy.width, imageProxy.height, rgba)
                    }
                }
                imageProxy.close()
            }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cp.unbindAll()
                val owner = (context as? LifecycleOwner) ?: MainActivity.lifecycleOwner
                if (owner != null) {
                    cp.bindToLifecycle(owner, cameraSelector, preview, imageAnalysis)
                }
            } catch (exc: Exception) {
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun yuv420ToRgba(image: ImageProxy): ByteArray? {
        if (image.format != ImageFormat.YUV_420_888) return null
        val w = image.width
        val h = image.height
        if (w <= 0 || h <= 0) return null

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer

        val yRowStride = yPlane.rowStride
        val uRowStride = uPlane.rowStride
        val vRowStride = vPlane.rowStride
        val uPixelStride = uPlane.pixelStride
        val vPixelStride = vPlane.pixelStride

        val ySize = minOf(yBuf.remaining(), yRowStride * h)
        val uvSize = minOf(uBuf.remaining(), uRowStride * (h / 2))
        val yArr = ByteArray(ySize)
        val uArr = ByteArray(uvSize)
        val vArr = ByteArray(minOf(vBuf.remaining(), vRowStride * (h / 2)))
        yBuf.get(yArr)
        uBuf.get(uArr)
        vBuf.get(vArr)

        val result = ByteArray(w * h * 4)
        var idx = 0
        for (row in 0 until h) {
            for (col in 0 until w) {
                val yIdx = row * yRowStride + col
                val uvRow = row / 2
                val uvCol = col / 2
                val uIdx = uvRow * uRowStride + uvCol * uPixelStride
                val vIdx = uvRow * vRowStride + uvCol * vPixelStride

                val y = (yArr[yIdx].toInt() and 0xFF) - 16
                val u = (uArr[uIdx].toInt() and 0xFF) - 128
                val v = (vArr[vIdx].toInt() and 0xFF) - 128

                val r = (298 * y + 409 * v + 128) shr 8
                val g = (298 * y - 100 * u - 208 * v + 128) shr 8
                val b = (298 * y + 516 * u + 128) shr 8

                result[idx++] = r.coerceIn(0, 255).toByte()
                result[idx++] = g.coerceIn(0, 255).toByte()
                result[idx++] = b.coerceIn(0, 255).toByte()
                result[idx++] = 0xFF.toByte()
            }
        }
        return result
    }

    override fun getView(): View = previewView

    override fun dispose() {
        currentInstance = null
        isSending = false
        imageAnalysis?.clearAnalyzer()
        cameraProvider?.unbindAll()
        cameraExecutor.shutdown()
        if (pSender != 0L) {
            destroySender(pSender)
            pSender = 0
        }
    }

    private external fun createSender(sourceName: String): Long
    private external fun sendVideoFrame(pSender: Long, width: Int, height: Int, rgbaData: ByteArray)
    private external fun destroySender(pSender: Long)
}
