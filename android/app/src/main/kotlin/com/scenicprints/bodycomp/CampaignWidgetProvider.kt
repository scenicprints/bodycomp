package com.scenicprints.bodycomp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

// The Flutter side renders the entire widget face as one PNG; this just
// blits it and forwards taps into the app.
class CampaignWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.campaign_widget)
            val path = widgetData.getString("cw_image", null)
            if (path != null) {
                val bmp = BitmapFactory.decodeFile(path)
                if (bmp != null) {
                    views.setImageViewBitmap(R.id.cw_img, bmp)
                }
            }
            val launch = Intent(context, MainActivity::class.java)
            val pi = PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.cw_img, pi)
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
