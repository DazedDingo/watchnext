package com.household.watchnext

import android.content.Intent
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

/**
 * Adds diagnostic logging around launch + new-intent so we can verify
 * widget tap PendingIntents are delivered with the expected action and
 * data URI. Filter logcat with `adb logcat -s WnWidget` to read just
 * these breadcrumbs while debugging widget-routing complaints.
 */
class MainActivity : FlutterActivity() {
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
}
