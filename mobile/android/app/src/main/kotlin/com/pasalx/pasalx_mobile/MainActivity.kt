package com.pasalx.pasalx_mobile

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var toneGenerator: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.pasalx.pos/beep")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "beep" -> {
                        try {
                            val tg = toneGenerator ?: ToneGenerator(AudioManager.STREAM_MUSIC, 85).also {
                                toneGenerator = it
                            }
                            tg.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                        } catch (_: Throwable) {
                            // Ignore audio hardware failures so scanning never blocks.
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }
}
