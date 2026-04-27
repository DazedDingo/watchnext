import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/providers/tonights_pick_provider.dart';
import 'package:watchnext/providers/upnext_provider.dart';
import 'package:watchnext/services/home_widget_service.dart';

UpNextEpisode _ep({
  required int tmdbId,
  int season = 1,
  int number = 1,
  String? episodeName,
  int daysUntilAir = 0,
}) {
  final today = DateTime(2026, 4, 26);
  return UpNextEpisode(
    tmdbId: tmdbId,
    showTitle: 'Show $tmdbId',
    season: season,
    number: number,
    episodeName: episodeName,
    airDate: today.add(Duration(days: daysUntilAir)),
    daysUntilAir: daysUntilAir,
  );
}

TonightsPick _pick({
  required String mediaType,
  required int tmdbId,
}) {
  return TonightsPick(
    tmdbId: tmdbId,
    mediaType: mediaType,
    title: 'Title $tmdbId',
    posterPath: '/poster.jpg',
    matchScore: 88,
  );
}

void main() {
  group('episodeWidgetUri', () {
    test('builds wn://title/tv/<tmdbId> for an episode', () {
      expect(
        episodeWidgetUri(_ep(tmdbId: 1399)).toString(),
        'wn://title/tv/1399',
      );
    });

    test('different tmdbId yields different URI', () {
      expect(
        episodeWidgetUri(_ep(tmdbId: 100)).toString(),
        'wn://title/tv/100',
      );
      expect(
        episodeWidgetUri(_ep(tmdbId: 200)).toString(),
        'wn://title/tv/200',
      );
    });

    test('always uses media type "tv" (Up Next is TV-only)', () {
      // Sanity-check the contract — an UpNextEpisode is always a TV episode.
      final uri = episodeWidgetUri(_ep(tmdbId: 42));
      expect(uri.host, 'title');
      expect(uri.pathSegments, ['tv', '42']);
    });
  });

  group('pickWidgetUri', () {
    test('builds wn://title/movie/<tmdbId> for a movie pick', () {
      expect(
        pickWidgetUri(_pick(mediaType: 'movie', tmdbId: 603)).toString(),
        'wn://title/movie/603',
      );
    });

    test('builds wn://title/tv/<tmdbId> for a tv pick', () {
      expect(
        pickWidgetUri(_pick(mediaType: 'tv', tmdbId: 1399)).toString(),
        'wn://title/tv/1399',
      );
    });
  });

  group('relativeWhenLabel', () {
    test('today → "Out today"', () {
      expect(relativeWhenLabel(0), 'Out today');
    });

    test('tomorrow → "Tomorrow"', () {
      expect(relativeWhenLabel(1), 'Tomorrow');
    });

    test('positive days → "In Nd"', () {
      expect(relativeWhenLabel(5), 'In 5d');
      expect(relativeWhenLabel(7), 'In 7d');
    });

    test('yesterday → "Aired yesterday"', () {
      expect(relativeWhenLabel(-1), 'Aired yesterday');
    });

    test('further past → "Just aired"', () {
      // -2 falls into the negative-but-not-yesterday bucket.
      expect(relativeWhenLabel(-3), 'Just aired');
    });
  });

  group('upNextEpisodeLabel', () {
    test('formats SnEn · Episode Name', () {
      final label = upNextEpisodeLabel(_ep(
        tmdbId: 1,
        season: 3,
        number: 4,
        episodeName: 'Big Reveal',
      ));
      expect(label, 'S3E4 · Big Reveal');
    });

    test('falls back to SnEn when episode name is missing', () {
      final label = upNextEpisodeLabel(_ep(
        tmdbId: 1,
        season: 2,
        number: 7,
      ));
      expect(label, 'S2E7');
    });

    test('treats empty/whitespace-only episode name as missing', () {
      final label = upNextEpisodeLabel(_ep(
        tmdbId: 1,
        season: 1,
        number: 1,
        episodeName: '   ',
      ));
      expect(label, 'S1E1');
    });
  });
}
