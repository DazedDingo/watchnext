import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/utils/animation_cap.dart';

Recommendation rec(
  String id, {
  List<String> genres = const [],
}) =>
    Recommendation(
      id: id,
      mediaType: 'movie',
      tmdbId: int.parse(id.split(':').last),
      title: id,
      matchScore: 70,
      genres: genres,
    );

void main() {
  group('capAnimation', () {
    test('pass-through when user explicitly selected Animation', () {
      final recs = List.generate(
        6,
        (i) => rec('movie:$i', genres: const ['Animation']),
      );
      final out = capAnimation(recs, userSelectedAnimation: true);
      expect(out.length, 6, reason: 'user opted in — no cap');
    });

    test('keeps at most `cap` animation rows, all non-animation rows', () {
      final recs = [
        rec('movie:1', genres: const ['Animation']),
        rec('movie:2', genres: const ['Drama']),
        rec('movie:3', genres: const ['Animation', 'Comedy']),
        rec('movie:4', genres: const ['Thriller']),
        rec('movie:5', genres: const ['Animation']),
        rec('movie:6', genres: const ['Animation', 'Action']),
        rec('movie:7', genres: const ['Drama']),
      ];
      final out = capAnimation(recs, userSelectedAnimation: false, cap: 2);
      final ids = out.map((r) => r.id).toList();
      expect(ids, ['movie:1', 'movie:2', 'movie:3', 'movie:4', 'movie:7'],
          reason: 'first 2 animation rows kept, later ones dropped, '
              'all non-animation rows kept in order');
    });

    test('preserves order (it is a pass-through, not a re-rank)', () {
      final recs = [
        rec('movie:100', genres: const ['Drama']),
        rec('movie:101', genres: const ['Animation']),
        rec('movie:102', genres: const ['Crime']),
      ];
      final out = capAnimation(recs, userSelectedAnimation: false);
      expect(out.map((r) => r.id), ['movie:100', 'movie:101', 'movie:102']);
    });

    test('cap of 0 drops every animation row', () {
      final recs = [
        rec('movie:1', genres: const ['Animation']),
        rec('movie:2', genres: const ['Drama']),
        rec('movie:3', genres: const ['Animation']),
      ];
      final out = capAnimation(recs, userSelectedAnimation: false, cap: 0);
      expect(out.map((r) => r.id), ['movie:2']);
    });

    test('empty input returns empty list', () {
      expect(capAnimation(const [], userSelectedAnimation: false), isEmpty);
    });

    test('unclassified rec (genres empty) is never counted against the cap',
        () {
      final recs = [
        rec('movie:1', genres: const ['Animation']),
        rec('movie:2'), // no genres — not animation, shouldn't count
        rec('movie:3', genres: const ['Animation']),
        rec('movie:4', genres: const ['Animation']),
      ];
      final out = capAnimation(recs, userSelectedAnimation: false, cap: 2);
      expect(out.map((r) => r.id), ['movie:1', 'movie:2', 'movie:3'],
          reason: 'movie:4 is the 3rd animation row and drops');
    });
  });
}
