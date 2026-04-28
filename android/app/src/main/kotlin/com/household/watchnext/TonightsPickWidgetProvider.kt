package com.household.watchnext

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Tonight's Pick home-screen widget. Reads `tp_title`, `tp_score`,
 * `tp_genres`, `tp_uri`, `tp_poster_url`, `tp_updated_at` from the
 * home_widget SharedPreferences payload pushed by
 * `lib/services/home_widget_service.dart`'s `pushTonightsPick(...)`.
 *
 * Poster handling: the TMDB CDN URL is downloaded into
 * `filesDir/widget_posters/${url.hashCode()}.jpg` once and reused on every
 * subsequent re-render. First paint may show no poster while the download
 * lands; we kick off a request-coroutine and call
 * `notifyAppWidgetViewDataChanged` (effectively a re-render trigger) once
 * the bytes are on disk. Coroutines run on a process-scoped supervisor —
 * AppWidgetProvider itself is short-lived (the system tears down the
 * receiver after onUpdate returns) but the JVM process stays alive long
 * enough to finish the HTTP call and re-fire onUpdate via
 * AppWidgetManager.updateAppWidget on success.
 */
class TonightsPickWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        val title = widgetData.getString("tp_title", null)
        val score = if (widgetData.contains("tp_score")) widgetData.getInt("tp_score", -1) else -1
        val genres = widgetData.getString("tp_genres", null)
        val uri = widgetData.getString("tp_uri", null)
        val posterUrl = widgetData.getString("tp_poster_url", null)
        val updatedAt = if (widgetData.contains("tp_updated_at"))
            widgetData.getLong("tp_updated_at", 0L) else 0L

        Log.d("WnWidget", "TonightsPickWidget.onUpdate title=$title score=$score uri=$uri ids=${appWidgetIds.size}")

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.tonights_pick_widget)
            val empty = title.isNullOrEmpty()

            // Refresh tile — same intent shape every render. Bridge
            // intercepts wn://refresh, invalidates providers, re-pushes
            // widget data after a short delay.
            val refreshIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("wn://refresh")
            )
            views.setOnClickPendingIntent(R.id.tp_refresh, refreshIntent)

            if (empty) {
                views.setViewVisibility(R.id.tp_empty, View.VISIBLE)
                views.setViewVisibility(R.id.tp_content, View.GONE)
                appWidgetManager.updateAppWidget(id, views)
                continue
            }

            views.setViewVisibility(R.id.tp_empty, View.GONE)
            views.setViewVisibility(R.id.tp_content, View.VISIBLE)

            // Stale-tag suffix — anything older than 36h gets a "(yesterday)"
            // hint and a dimmed poster. updated_at == 0 means the bridge
            // didn't write a timestamp; treat as fresh.
            val stale = updatedAt > 0L &&
                System.currentTimeMillis() - updatedAt > STALE_THRESHOLD_MS
            val displayTitle = if (stale) "$title (yesterday)" else title!!
            views.setTextViewText(R.id.tp_title, displayTitle)

            if (!genres.isNullOrEmpty()) {
                views.setViewVisibility(R.id.tp_genres, View.VISIBLE)
                views.setTextViewText(R.id.tp_genres, genres)
            } else {
                views.setViewVisibility(R.id.tp_genres, View.GONE)
            }

            if (score >= 0) {
                views.setViewVisibility(R.id.tp_score, View.VISIBLE)
                views.setTextViewText(R.id.tp_score, "★ $score%")
            } else {
                views.setViewVisibility(R.id.tp_score, View.GONE)
            }

            // Poster: cached file → setImageViewBitmap immediately; otherwise
            // schedule a background download + re-render.
            if (!posterUrl.isNullOrEmpty()) {
                val cached = posterCacheFile(context, posterUrl)
                if (cached.exists() && cached.length() > 0) {
                    val bitmap = BitmapFactory.decodeFile(cached.absolutePath)
                    if (bitmap != null) {
                        views.setImageViewBitmap(R.id.tp_poster, bitmap)
                        views.setInt(
                            R.id.tp_poster,
                            "setImageAlpha",
                            if (stale) 160 else 255
                        )
                    }
                } else {
                    scope.launch {
                        val ok = downloadPoster(posterUrl, cached)
                        if (ok) {
                            // Re-fire onUpdate by triggering AppWidgetManager
                            // to refresh just this widget id with a fresh
                            // RemoteViews that now sees the cached file.
                            triggerSelfUpdate(context, id)
                        }
                    }
                }
            }

            if (!uri.isNullOrEmpty()) {
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse(uri)
                )
                views.setOnClickPendingIntent(R.id.tp_content, pendingIntent)
            }

            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun posterCacheFile(context: Context, url: String): File {
        val dir = File(context.filesDir, "widget_posters").apply { mkdirs() }
        return File(dir, "${url.hashCode()}.jpg")
    }

    private suspend fun downloadPoster(url: String, target: File): Boolean =
        withContext(Dispatchers.IO) {
            try {
                val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 8_000
                    readTimeout = 12_000
                    requestMethod = "GET"
                }
                conn.inputStream.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                conn.disconnect()
                target.exists() && target.length() > 0
            } catch (t: Throwable) {
                // Cache miss is not fatal — widget renders without a poster.
                runCatching { target.delete() }
                false
            }
        }

    private fun triggerSelfUpdate(context: Context, appWidgetId: Int) {
        val mgr = AppWidgetManager.getInstance(context)
        val views = RemoteViews(context.packageName, R.layout.tonights_pick_widget)
        // Setting the bitmap from disk on the new RemoteViews will pick up
        // the freshly cached file. Calling onUpdate(context, mgr, [id])
        // re-runs the full bind path with the same widgetData payload.
        onUpdate(context, mgr, intArrayOf(appWidgetId), es.antonborri.home_widget.HomeWidgetPlugin.getData(context))
        // updateAppWidget already fired inside onUpdate; nothing more to do.
        // Explicitly suppress unused-variable warnings for `mgr` + `views`.
        @Suppress("UNUSED_VARIABLE") val unusedMgr = mgr
        @Suppress("UNUSED_VARIABLE") val unusedViews = views
    }

    companion object {
        // 36h: longer than a typical "tonight" cycle but short enough to
        // catch yesterday's stale pick when the user hasn't opened the app.
        private const val STALE_THRESHOLD_MS = 36L * 60L * 60L * 1000L

        // Process-scoped supervisor — survives a single AppWidgetProvider
        // teardown but not process death (which is fine; cache lives on
        // disk so the next onUpdate picks it up).
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    }
}
