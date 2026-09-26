package com.hqepl.audit360

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The Android release the app is running on. Dart has no way to ask, and
        // the foreground service's runtime cap applies only from Android 15
        // (API 35) — see kServiceMaxRuntime in background_entrypoints.dart.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.hqepl.audit360/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "sdkInt") result.success(Build.VERSION.SDK_INT) else result.notImplemented()
            }
    }
}
