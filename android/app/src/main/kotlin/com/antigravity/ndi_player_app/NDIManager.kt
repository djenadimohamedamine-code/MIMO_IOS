package com.antigravity.ndi_player_app

import android.os.Handler
import android.os.Looper
import java.util.*

object NDIManager {
    private var cachedSources = mutableListOf<String>()
    
    // Periodically update sources in background
    fun startDiscovery() {
        val handler = Handler(Looper.getMainLooper())
        val runnable = object : Runnable {
            override fun run() {
                // Background scan (Simplified for now, real scan happens in C++)
                // List will be updated by MethodChannel calls or callback
                handler.postDelayed(this, 5000)
            }
        }
        handler.post(runnable)
    }

    fun setSources(sources: List<String>) {
        cachedSources.clear()
        cachedSources.addAll(sources)
    }

    fun getSources(): List<String> = cachedSources
}
