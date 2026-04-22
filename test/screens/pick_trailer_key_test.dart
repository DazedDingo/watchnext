import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/screens/title_detail/title_detail_screen.dart';

void main() {
  group('pickTrailerKey', () {
    test('returns null for null or empty lists', () {
      expect(pickTrailerKey(null), isNull);
      expect(pickTrailerKey(const []), isNull);
    });

    test('filters out non-YouTube sites', () {
      final videos = [
        {'site': 'Vimeo', 'key': 'nope', 'type': 'Trailer', 'official': true},
        {'site': 'Unknown', 'key': 'nope2', 'type': 'Trailer'},
      ];
      expect(pickTrailerKey(videos), isNull);
    });

    test('ignores YouTube entries with missing/empty keys', () {
      final videos = [
        {'site': 'YouTube', 'key': '', 'type': 'Trailer'},
        {'site': 'YouTube', 'type': 'Trailer'},
      ];
      expect(pickTrailerKey(videos), isNull);
    });

    test('prefers official YouTube Trailer over unofficial', () {
      final videos = [
        {'site': 'YouTube', 'key': 'unofficial', 'type': 'Trailer', 'official': false},
        {'site': 'YouTube', 'key': 'official', 'type': 'Trailer', 'official': true},
        {'site': 'YouTube', 'key': 'teaser', 'type': 'Teaser', 'official': true},
      ];
      expect(pickTrailerKey(videos), 'official');
    });

    test('falls back to any Trailer when no official one exists', () {
      final videos = [
        {'site': 'YouTube', 'key': 'teaser', 'type': 'Teaser', 'official': true},
        {'site': 'YouTube', 'key': 'any-trailer', 'type': 'Trailer'},
      ];
      expect(pickTrailerKey(videos), 'any-trailer');
    });

    test('falls back to Teaser when no Trailer exists', () {
      final videos = [
        {'site': 'YouTube', 'key': 'clip-key', 'type': 'Clip'},
        {'site': 'YouTube', 'key': 'teaser-key', 'type': 'Teaser'},
      ];
      expect(pickTrailerKey(videos), 'teaser-key');
    });

    test('returns first YouTube video as last resort', () {
      final videos = [
        {'site': 'YouTube', 'key': 'first-clip', 'type': 'Clip'},
        {'site': 'YouTube', 'key': 'featurette', 'type': 'Featurette'},
      ];
      expect(pickTrailerKey(videos), 'first-clip');
    });

    test('site comparison is case-insensitive', () {
      final videos = [
        {'site': 'youtube', 'key': 'lowercase-key', 'type': 'Trailer', 'official': true},
      ];
      expect(pickTrailerKey(videos), 'lowercase-key');
    });
  });
}
