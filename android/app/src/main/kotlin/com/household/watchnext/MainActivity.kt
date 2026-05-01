package com.household.watchnext

import android.content.Intent
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Adds diagnostic logging around launch + new-intent so we can verify
 * widget tap PendingIntents are delivered with the expected action and
 * data URI. Filter logcat with `adb logcat -s WnWidget` to read just
 * these breadcrumbs while debugging widget-routing complaints.
 *
 * Also hosts the `wn/app_icon` MethodChannel that backs the in-app
 * launcher-icon picker (Profile → Preferences → App icon).
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val APP_ICON_CHANNEL = "wn/app_icon"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        Log.d(
            "WnWidget",
            "MainActivity.onCreate action=${intent?.action} data=${intent?.data}"
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(
            "WnWidget",
            "MainActivity.onNewIntent action=${intent.action} data=${intent.data}"
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val switcher = AppIconSwitcher(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_ICON_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrent" -> result.success(switcher.getCurrentAlias())
                    "setAlias" -> {
                        val target = call.argument<String>("name")
                        if (target == null) {
                            result.error("INVALID_ARG", "name argument is required", null)
                        } else if (switcher.setAlias(target)) {
                            result.success(null)
                        } else {
                            result.error("UNKNOWN_ALIAS", "no alias matches $target", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
