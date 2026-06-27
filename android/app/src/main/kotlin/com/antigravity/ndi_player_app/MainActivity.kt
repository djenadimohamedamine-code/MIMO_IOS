package com.antigravity.ndi_player_app

import android.content.Context
import android.net.wifi.WifiManager
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.antigravity/ndi"
    private var multicastLock: WifiManager.MulticastLock? = null

    companion object {
        init {
            System.loadLibrary("mimo_ndi_native")
        }
        @Volatile
        var lifecycleOwner: LifecycleOwner? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        lifecycleOwner = this
        acquireMulticastLock()

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ndi-view", NdiViewFactory()
        )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ndi-camera-preview", NdiCameraPreviewFactory()
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSources" -> {
                    val sources = getNativeSources()
                    result.success(sources)
                }
                "setupCamera" -> {
                    val instance = NdiCameraPreview.currentInstance
                    if (instance != null) {
                        instance.initSender("MIMO_NDI Camera")
                    }
                    result.success(true)
                }
                "startSend" -> {
                    val name = call.argument<String>("name") ?: "MIMO_NDI Camera"
                    val instance = NdiCameraPreview.currentInstance
                    if (instance != null) {
                        instance.initSender(name)
                        instance.startSending()
                    }
                    result.success(true)
                }
                "stopSend" -> {
                    val instance = NdiCameraPreview.currentInstance
                    if (instance != null) {
                        instance.stopSending()
                    }
                    result.success(true)
                }
                "startRelay" -> {
                    result.success(true)
                }
                "stopRelay" -> {
                    result.success(true)
                }
                "switchRelay" -> {
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    private fun acquireMulticastLock() {
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("MIMO_NDI_MulticastLock")
            multicastLock?.setReferenceCounted(false)
            multicastLock?.acquire()
        } catch (e: Exception) {
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
            multicastLock = null
        } catch (e: Exception) {
        }
    }

    private external fun getNativeSources(): List<String>
}
