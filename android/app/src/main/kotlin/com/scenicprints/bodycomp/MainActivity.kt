package com.scenicprints.bodycomp

// Health Connect (the `health` plugin) requires the host Activity to be a
// FlutterFragmentActivity rather than a plain FlutterActivity.
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Bridge the coached-run screen to the Pixel Watch app.
        WatchBridge(applicationContext).register(flutterEngine)
    }
}
