import 'dart:async';
import 'dart:developer' as developer;

import 'package:home_widget/home_widget.dart';

import '../providers/tonights_pick_provider.dart';
import '../providers/upnext_provider.dart';

/// Bridge between Flutter state and the Android home-screen widgets
/// (Up Next + Tonight's Pick). The native AppWidgetProviders are shipped
/// separately — this layer's only job is to (1) push typed prefs into the
/// home_widget storage layer, (2) trigger AppWidgetProvider updates, and
/// (3) surface widget-tap deep-links back to the app router.
///
/// Storage shape is intentionally flat (typed values, not JSON blobs) —
/// RemoteViews on the Android side pulls strings/ints by key directly.
class HomeWidgetService {
  // Must match the Android AppWidgetProvider class names. iOS has no
  // counterpart yet but the package's API requires both axes be set.
  static const upNextWidgetName = 'UpNextWidgetProvider';
  static const tonightsPickWidgetName = 'TonightsPickWidgetProvider';

  // iOS-only — set so the package doesn't warn. iOS widget support is
  // out-of-scope for the current Android-first phase.
  static const _appGroupId = 'group.com.household.watchnext';

  static bool _appGroupSet = false;

  static Future<void> _ensureAppGroup() async {
    if (_appGroupSet) return;
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
    } catch (_) {
      // Best-effort — Android ignores the call; iOS may not be present.
    }
    _appGroupSet = true;
  }

  /// Push the latest Up Next list to the widget. Capped at
  /// [kUpNextMaxTiles] (matches the in-app row). An empty list still
  /// triggers the widget update so the AppWidgetProvider can render the
  /// "Nothing scheduled this week" empty state.
  static Future<void> pushUpNext(List<UpNextEpisode> episodes) async {
    await _ensureAppGroup();
    final capped = episodes.take(kUpNextMaxTiles).toList();
    await HomeWidget.saveWidgetData<int>('up_next_count', capped.length);

    // Always write all three slots so stale data from a previous push doesn't
    // bleed into the rendered widget when the list shrinks.
    for (var i = 0; i < kUpNextMaxTiles; i++) {
      if (i < capped.length) {
        final e = capped[i];
        await HomeWidget.saveWidgetData<String>(
            'up_next_${i}_title', e.showTitle);
        await HomeWidget.saveWidgetData<String>(
            'up_next_${i}_episode_label', _episodeLabel(e));
        await HomeWidget.saveWidgetData<String>(
            'up_next_${i}_when', _relativeWhen(e.daysUntilAir));
        await HomeWidget.saveWidgetData<String>(
            'up_next_${i}_uri', _episodeUri(e).toString());
      } else {
        await HomeWidget.saveWidgetData<String>('up_next_${i}_title', null);
        await HomeWidget.saveWidgetData<String>(
            'up_next_${i}_episode_label', null);
        await HomeWidget.saveWidgetData<String>('up_next_${i}_when', null);
        await HomeWidget.saveWidgetData<String>('up_next_${i}_uri', null);
      }
    }

    await HomeWidget.updateWidget(
      name: upNextWidgetName,
      androidName: upNextWidgetName,
    );
  }

  /// Push the current Tonight's Pick. null clears all fields so the
  /// AppWidgetProvider falls back to its empty state ("Open WatchNext to
  /// refresh").
  static Future<void> pushTonightsPick(TonightsPick? pick) async {
    await _ensureAppGroup();
    if (pick == null) {
      await HomeWidget.saveWidgetData<String>('tp_title', null);
      await HomeWidget.saveWidgetData<int>('tp_score', null);
      await HomeWidget.saveWidgetData<String>('tp_genres', null);
      await HomeWidget.saveWidgetData<String>('tp_uri', null);
      await HomeWidget.saveWidgetData<String>('tp_poster_url', null);
      await HomeWidget.saveWidgetData<int>('tp_updated_at', null);
    } else {
      await HomeWidget.saveWidgetData<String>('tp_title', pick.title);
      await HomeWidget.saveWidgetData<int>('tp_score', pick.matchScore);
      // The CF doesn't currently write a genre list onto the tonightsPick
      // doc, so this stays null until we widen that contract. The widget's
      // RemoteViews reads it as an optional secondary line.
      await HomeWidget.saveWidgetData<String>('tp_genres', null);
      await HomeWidget.saveWidgetData<String>(
          'tp_uri', _pickUri(pick).toString());
      await HomeWidget.saveWidgetData<String>(
          'tp_poster_url', _posterUrl(pick.posterPath));
      await HomeWidget.saveWidgetData<int>(
          'tp_updated_at', pick.updatedAt?.millisecondsSinceEpoch);
    }
    await HomeWidget.updateWidget(
      name: tonightsPickWidgetName,
      androidName: tonightsPickWidgetName,
    );
  }

  /// Stream of widget-tap deep links (e.g. `wn://title/tv/1399`). Consumers
  /// route via go_router. Initialised lazily so a non-Android caller doesn't
  /// trigger a platform-channel subscription it can't service.
  static Stream<Uri> widgetTapStream() {
    return HomeWidget.widgetClicked
        .where((u) => u != null && u.toString().isNotEmpty)
        .cast<Uri>()
        .map((u) {
      developer.log('warm tap → $u', name: 'wn-widget');
      return u;
    });
  }

  /// Cold-start helper — returns the URI the widget tap launched the app
  /// with, or null when the app was opened normally.
  static Future<Uri?> initialLaunchUri() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      developer.log(
        'initialLaunchUri raw=${uri ?? "null"}',
        name: 'wn-widget',
      );
      if (uri == null || uri.toString().isEmpty) return null;
      return uri;
    } catch (e) {
      developer.log('initialLaunchUri error: $e', name: 'wn-widget');
      return null;
    }
  }
}

// ─── Pure helpers (extracted so they're unit-testable) ──────────────────────

Uri episodeWidgetUri(UpNextEpisode e) => _episodeUri(e);
Uri pickWidgetUri(TonightsPick p) => _pickUri(p);
String relativeWhenLabel(int daysUntilAir) => _relativeWhen(daysUntilAir);
String upNextEpisodeLabel(UpNextEpisode e) => _episodeLabel(e);

Uri _episodeUri(UpNextEpisode e) => Uri.parse('wn://title/tv/${e.tmdbId}');

Uri _pickUri(TonightsPick p) =>
    Uri.parse('wn://title/${p.mediaType}/${p.tmdbId}');

// Duplicated from `home_screen.dart`'s `_relativeAirLabel`. Kept private
// there to avoid screens leaking widgets — copying is cheap and matches the
// labels exactly.
String _relativeWhen(int daysUntilAir) {
  if (daysUntilAir == 0) return 'Out today';
  if (daysUntilAir == 1) return 'Tomorrow';
  if (daysUntilAir == -1) return 'Aired yesterday';
  if (daysUntilAir < 0) return 'Just aired';
  return 'In ${daysUntilAir}d';
}

String _episodeLabel(UpNextEpisode e) {
  // Matches the in-app row format: "S3E4 · Big Reveal" or just "S3E4" when
  // the episode title is missing/empty.
  final code = 'S${e.season}E${e.number}';
  final name = e.episodeName?.trim() ?? '';
  return name.isEmpty ? code : '$code · $name';
}

String? _posterUrl(String posterPath) {
  if (posterPath.isEmpty) return null;
  // w342 is a reasonable middle ground for the widget's poster slot — large
  // enough on tablets, small enough that the native side caches quickly.
  return 'https://image.tmdb.org/t/p/w342$posterPath';
}
