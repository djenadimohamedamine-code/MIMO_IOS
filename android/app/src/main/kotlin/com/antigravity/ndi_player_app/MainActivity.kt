package com.antigravity.ndi_player_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.antigravity/ndi"

    companion object {
        init {
            System.loadLibrary("mimo_ndi_native")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register the View Factories
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
                "startSend" -> {
                    val name = call.argument<String>("name") ?: "MIMO_NDI Camera"
                    // NDIManager handles send logic (To be implemented or JNI call)
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

    // JNI Calls
    private external fun getNativeSources(): List<String>
}
