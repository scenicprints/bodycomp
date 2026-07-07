package com.scenicprints.bodycomp

import android.content.Context
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// ═══════════════════════════════════════════════════════════════════════
//  WATCH BRIDGE — connects the Flutter run screen to the Wear OS app over the
//  Wearable Data Layer.
//
//  Flutter → watch : MethodChannel "bodycomp/watch"
//      sendState(jsonString)  push the live run onto every connected watch
//      end()                  mark the run finished (a done=true state)
//  watch → Flutter : EventChannel "bodycomp/watch_events"
//      emits "toggle" / "stop" when the wrist buttons are pressed
// ═══════════════════════════════════════════════════════════════════════

private const val METHOD_CHANNEL = "bodycomp/watch"
private const val EVENT_CHANNEL = "bodycomp/watch_events"
private const val PATH_STATE = "/bodycomp/run"
private const val PATH_ACTION = "/bodycomp/action"

class WatchBridge(private val context: Context) :
    MessageClient.OnMessageReceivedListener {

    private var events: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendState" -> {
                        val json = call.arguments as? String
                        if (json != null) {
                            sendToWatches(PATH_STATE, json.toByteArray(Charsets.UTF_8))
                        }
                        result.success(null)
                    }
                    "end" -> {
                        // A minimal done payload so the watch closes the run out
                        // even if the last per-second state was missed.
                        sendToWatches(
                            PATH_STATE,
                            "{\"done\":true}".toByteArray(Charsets.UTF_8),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                    Wearable.getMessageClient(context).addListener(this@WatchBridge)
                }

                override fun onCancel(arguments: Any?) {
                    Wearable.getMessageClient(context).removeListener(this@WatchBridge)
                    events = null
                }
            })
    }

    private fun sendToWatches(path: String, data: ByteArray) {
        val ctx = context
        Wearable.getNodeClient(ctx).connectedNodes.addOnSuccessListener { nodes ->
            val client = Wearable.getMessageClient(ctx)
            for (node in nodes) {
                client.sendMessage(node.id, path, data)
            }
        }
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path == PATH_ACTION) {
            val action = String(event.data, Charsets.UTF_8)
            events?.success(action)
        }
    }
}
