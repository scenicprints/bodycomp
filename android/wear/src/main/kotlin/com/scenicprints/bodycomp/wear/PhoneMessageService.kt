package com.scenicprints.bodycomp.wear

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.WearableListenerService

// ═══════════════════════════════════════════════════════════════════════
//  Receives today's eaten calories from the phone's food log, for the watch
//  face. It arrives as a Data Layer item (path "/bodycomp/calories"), so it
//  is delivered even when this app is closed, and after a reconnect.
// ═══════════════════════════════════════════════════════════════════════

class PhoneMessageService : WearableListenerService() {

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED ||
                event.dataItem.uri.path != CalorieStore.PATH_CALORIES
            ) {
                continue
            }
            val map = DataMapItem.fromDataItem(event.dataItem).dataMap
            val date = map.getString("date") ?: continue
            CalorieStore.setEaten(this, date, map.getInt("eaten", 0))
            CalorieComplicationService.requestUpdate(this)
        }
    }
}
