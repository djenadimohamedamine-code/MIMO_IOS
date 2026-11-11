package com.antigravity.ndi_player_app

import android.content.Context
import android.util.Log

object NDIManager {
    private const val TAG = "NDIManager"
    private var isInitialized = false
    private val cachedSources = mutableListOf<String>()
    private val lock = Any()
    private var discoveryThread: Thread? = null
    @Volatile private var isRunning = false

    fun init(context: Context) {
        if (isInitialized) return
        isInitialized = true
        isRunning = true

        nativeInitFinder()

        discoveryThread = Thread {
            while (isRunning) {
                try {
                    val sources = nativeGetSources()
                    if (sources != null) {
                        synchronized(lock) {
                            cachedSources.clear()
                            cachedSources.addAll(sources)
                        }
                    }
                    Thread.sleep(1500)
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Discovery loop exception: ${e.message}")
                }
            }
        }.apply {
            name = "NDIDiscoveryThread"
            isDaemon = true
            start()
        }
        Log.d(TAG, "NDIManager background discovery started")
    }

    fun getSources(): List<String> {
        synchronized(lock) {
            return ArrayList(cachedSources)
        }
    }

    fun refreshSources() {
        Thread {
            try {
                val sources = nativeGetSources()
                if (sources != null) {
                    synchronized(lock) {
                        cachedSources.clear()
                        cachedSources.addAll(sources)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "refreshSources exception: ${e.message}")
            }
        }.start()
    }

    fun cleanup() {
        isRunning = false
        discoveryThread?.interrupt()
        discoveryThread = null
        nativeDestroyFinder()
        isInitialized = false
        Log.d(TAG, "NDIManager cleaned up")
    }

    private external fun nativeInitFinder(): Boolean
    private external fun nativeGetSources(): List<String>?
    private external fun nativeDestroyFinder()
}
