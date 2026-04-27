package com.household.watchnext

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Up Next home-screen widget. Reads the indexed SharedPreferences slots
 * `up_next_${i}_{title|episode_label|when|uri}` (i = 0..2) plus
 * `up_next_count`, populated from
 * `lib/services/home_widget_service.dart`'s `pushUpNext(...)`. Each row is
 * tappable — the `wn://title/tv/{tmdbId}` URI lands on MainActivity via the
 * <data android:scheme="wn"/> intent-filter and the home_widget bridge
 * surfaces it back through `HomeWidget.widgetClicked`.
 */
class UpNextWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        val count = widgetData.getInt("up_next_count", 0)

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.up_next_widget)

            if (count <= 0) {
                views.setViewVisibility(R.id.up_next_empty, View.VISIBLE)
                views.setViewVisibility(R.id.up_next_row_0, View.GONE)
                views.setViewVisibility(R.id.up_next_row_1, View.GONE)
                views.setViewVisibility(R.id.up_next_row_2, View.GONE)
            } else {
                views.setViewVisibility(R.id.up_next_empty, View.GONE)
                bindRow(context, views, 0, widgetData, count)
                bindRow(context, views, 1, widgetData, count)
                bindRow(context, views, 2, widgetData, count)
            }

            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun bindRow(
        context: Context,
        views: RemoteViews,
        index: Int,
        data: SharedPreferences,
        count: Int
    ) {
        val rowId = ROW_IDS[index]
        val titleId = TITLE_IDS[index]
        val whenId = WHEN_IDS[index]

        if (index >= count) {
            views.setViewVisibility(rowId, View.GONE)
            return
        }

        val title = data.getString("up_next_${index}_title", null)
        val epLabel = data.getString("up_next_${index}_episode_label", null)
        val whenText = data.getString("up_next_${index}_when", null)
        val uri = data.getString("up_next_${index}_uri", null)

        if (title.isNullOrEmpty()) {
            views.setViewVisibility(rowId, View.GONE)
            return
        }

        views.setViewVisibility(rowId, View.VISIBLE)

        // Title + episode label collapse into the same TextView; an em-dash
        // separator keeps them visually distinct without needing two spans.
        val combined = if (epLabel.isNullOrEmpty()) title else "$title — $epLabel"
        views.setTextViewText(titleId, combined)
        views.setTextViewText(whenId, whenText.orEmpty())

        if (!uri.isNullOrEmpty()) {
            val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse(uri)
            )
            views.setOnClickPendingIntent(rowId, pendingIntent)
        }
    }

    companion object {
        private val ROW_IDS = intArrayOf(
            R.id.up_next_row_0,
            R.id.up_next_row_1,
            R.id.up_next_row_2
        )
        private val TITLE_IDS = intArrayOf(
            R.id.up_next_row_0_title,
            R.id.up_next_row_1_title,
            R.id.up_next_row_2_title
        )
        private val WHEN_IDS = intArrayOf(
            R.id.up_next_row_0_when,
            R.id.up_next_row_1_when,
            R.id.up_next_row_2_when
        )
    }
}
