package com.antigravity.ndi_player_app

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.antigravity/ndi"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    companion object {
        init {
            System.loadLibrary("mimo_ndi_native")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        acquireWifiLocks()
        NDIManager.init(applicationContext)

        // Register the View Factories
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ndi-view", NdiViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "ndi-camera-preview", NdiCameraPreviewFactory()
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSources" -> {
                    val sources = NDIManager.getSources()
                    result.success(sources)
                }
                "startSend" -> {
                    val name = call.argument<String>("name") ?: "MIMO_NDI Camera"
                    result.success(true)
                }
                "stopSend" -> {
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun acquireWifiLocks() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager != null) {
                if (multicastLock == null) {
                    multicastLock = wifiManager.createMulticastLock("mimo_ndi_multicast_lock").apply {
                        setReferenceCounted(true)
                        acquire()
                    }
                    Log.d("MainActivity", "MulticastLock acquired successfully")
                }
                if (wifiLock == null) {
                    @Suppress("DEPRECATION")
                    wifiLock = wifiManager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "mimo_ndi_wifi_lock").apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                    Log.d("MainActivity", "WifiLock acquired successfully")
                }
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to acquire WiFi locks: ${e.message}")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {}
        NDIManager.cleanup()
    }
}
