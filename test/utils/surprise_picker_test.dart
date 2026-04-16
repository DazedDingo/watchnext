import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/utils/surprise_picker.dart';

Recommendation _r(String id) => Recommendation(
      id: id,
      mediaType: 'movie',
      tmdbId: int.parse(id.split(':').last),
      title: id,
      matchScore: 80,
    );

void main() {
  group('pickSurprise', () {
    test('returns null for an empty pool', () {
      expect(pickSurprise(const [], random: Random(0)), isNull);
    });

    test('returns the sole item when pool has length 1', () {
      final pool = [_r('movie:1')];
      expect(pickSurprise(pool, random: Random(0))!.id, 'movie:1');
    });

    test('never picks from below topN when pool is larger', () {
      final pool = List.generate(30, (i) => _r('movie:${i + 1}'));
      // Drive the RNG hard to make sure we never exceed topN=10.
      for (var seed = 0; seed < 200; seed++) {
        final picked = pickSurprise(pool, topN: 10, random: Random(seed))!;
        final index = pool.indexWhere((r) => r.id == picked.id);
        expect(index, lessThan(10),
            reason: 'seed=$seed yielded index $index, outside top 10');
      }
    });

    test('honours a smaller topN when pool is shorter than topN', () {
      final pool = List.generate(3, (i) => _r('movie:${i + 1}'));
      final seen = <String>{};
      for (var seed = 0; seed < 50; seed++) {
        seen.add(pickSurprise(pool, topN: 10, random: Random(seed))!.id);
      }
      // Over 50 seeds at least two of three should appear (not a strict
      // guarantee, but Random(0..49) against a 3-sized set should hit that
      // bar trivially).
      expect(seen.length, greaterThanOrEqualTo(2));
    });

    test('given the same seed, returns the same item (determinism)', () {
      final pool = List.generate(10, (i) => _r('movie:${i + 1}'));
      final a = pickSurprise(pool, random: Random(42))!.id;
      final b = pickSurprise(pool, random: Random(42))!.id;
      expect(a, b);
    });

    test('topN=1 collapses to picking the highest-ranked rec', () {
      final pool = List.generate(5, (i) => _r('movie:${i + 1}'));
      for (var seed = 0; seed < 20; seed++) {
        expect(
          pickSurprise(pool, topN: 1, random: Random(seed))!.id,
          'movie:1',
        );
      }
    });
  });
}
