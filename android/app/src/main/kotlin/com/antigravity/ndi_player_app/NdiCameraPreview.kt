package com.antigravity.ndi_player_app

import android.content.Context
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import android.graphics.Color
import android.view.Gravity
import io.flutter.plugin.platform.PlatformView

class NdiCameraPreview(context: Context, id: Int, creationParams: Map<String?, Any?>?) : PlatformView {
    private val container = FrameLayout(context)

    init {
        val textView = TextView(context).apply {
            text = "Camera Preview Placeholder\n(Native CameraX not linked yet)"
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setBackgroundColor(Color.BLACK)
        }
        container.addView(textView)
    }

    override fun getView(): View = container

    override fun dispose() {}
}
