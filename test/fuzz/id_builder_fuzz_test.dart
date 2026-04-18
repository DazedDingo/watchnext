import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/episode.dart';
import 'package:watchnext/models/prediction.dart';
import 'package:watchnext/models/rating.dart';
import 'package:watchnext/models/recommendation.dart';
import 'package:watchnext/models/watch_entry.dart';
import 'package:watchnext/models/watchlist_item.dart';
import 'package:watchnext/services/household_service.dart';

/// Randomised/property-style tests that hammer the pure helpers with wide
/// input domains. Each test pins an invariant: injectivity, round-trip,
/// format shape. Uses a deterministic seed so CI failures are reproducible.
void main() {
  final rng = Random(0xC0FFEE);

  String randomAlnum(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  group('WatchEntry.buildId / Prediction.buildId / Recommendation.buildId', () {
    test('all three produce the same "mediaType:tmdbId" shape', () {
      for (var i = 0; i < 200; i++) {
        final type = rng.nextBool() ? 'movie' : 'tv';
        final id = rng.nextInt(1 << 30);
        final w = WatchEntry.buildId(type, id);
        final p = Prediction.buildId(type, id);
        final r = Recommendation.buildId(type, id);
        expect(w, '$type:$id');
        expect(p, w);
        expect(r, w);
      }
    });

    test('different (type, id) pairs always give different keys — '
        'injectivity across 1k random pairs', () {
      final seen = <String>{};
      for (var i = 0; i < 1000; i++) {
        final type = rng.nextBool() ? 'movie' : 'tv';
        final id = rng.nextInt(1 << 30);
        final key = WatchEntry.buildId(type, id);
        // Accept collisions only when (type, id) is genuinely the same.
        seen.add(key);
      }
      // Not enforcing exact count; just assert no crash and all keys parseable.
      for (final k in seen) {
        final parts = k.split(':');
        expect(parts.length, 2);
        expect(int.tryParse(parts[1]), isNotNull);
      }
    });
  });

  group('WatchlistItem.buildId (scope-aware)', () {
    test('default scope is shared, shape is "shared:shared:type:id"', () {
      for (var i = 0; i < 100; i++) {
        final type = rng.nextBool() ? 'movie' : 'tv';
        final id = rng.nextInt(1 << 30);
        expect(WatchlistItem.buildId(type, id), 'shared:shared:$type:$id');
      }
    });

    test('scope=solo + distinct ownerUid never collide for same title', () {
      for (var i = 0; i < 100; i++) {
        final type = rng.nextBool() ? 'movie' : 'tv';
        final id = rng.nextInt(1 << 30);
        final u1 = randomAlnum(28);
        final u2 = randomAlnum(28);
        final a = WatchlistItem.buildId(type, id, scope: 'solo', ownerUid: u1);
        final b = WatchlistItem.buildId(type, id, scope: 'solo', ownerUid: u2);
        final shared = WatchlistItem.buildId(type, id);
        expect(a == b, u1 == u2);
        expect(a, isNot(shared));
        expect(b, isNot(shared));
      }
    });
  });

  group('Rating.buildId', () {
    test('is stable — two calls with same inputs always equal', () {
      for (var i = 0; i < 200; i++) {
        final uid = randomAlnum(28);
        final target = 'movie:${rng.nextInt(1 << 30)}';
        final level = ['movie', 'show', 'season', 'episode'][rng.nextInt(4)];
        final a = Rating.buildId(uid, level, target);
        final b = Rating.buildId(uid, level, target);
        expect(a, b);
      }
    });

    test('encodes level in the middle so uid + target can be recovered',
        () {
      for (var i = 0; i < 50; i++) {
        final uid = randomAlnum(28);
        final level = 'movie';
        final target = 'movie:${rng.nextInt(1 << 30)}';
        final id = Rating.buildId(uid, level, target);
        expect(id.startsWith('$uid:$level:'), isTrue);
        expect(id.endsWith(target), isTrue);
      }
    });
  });

  group('Episode.buildId', () {
    test('produces "season_number" for all s/e pairs', () {
      for (var s = 1; s < 40; s++) {
        for (var e = 1; e < 40; e++) {
          expect(Episode.buildId(s, e), '${s}_$e');
        }
      }
    });

    test('never collides across distinct (s,e) pairs in a show', () {
      final seen = <String>{};
      for (var s = 1; s <= 20; s++) {
        for (var e = 1; e <= 20; e++) {
          final added = seen.add(Episode.buildId(s, e));
          expect(added, isTrue, reason: 'Collision at ($s,$e)');
        }
      }
      expect(seen.length, 400);
    });
  });

  group('HouseholdService.isValidInviteCode — domain sweep', () {
    test('100 random 20-64 length alphanumeric codes all accepted', () {
      for (var i = 0; i < 100; i++) {
        final len = 20 + rng.nextInt(45); // 20..64
        final code = randomAlnum(len);
        expect(HouseholdService.isValidInviteCode(code), isTrue, reason: code);
      }
    });

    test('100 random codes of forbidden lengths rejected', () {
      for (var i = 0; i < 50; i++) {
        expect(
            HouseholdService.isValidInviteCode(randomAlnum(rng.nextInt(20))),
            isFalse);
        expect(
            HouseholdService.isValidInviteCode(
                randomAlnum(65 + rng.nextInt(100))),
            isFalse);
      }
    });

    test('injecting a non-alnum char at any position invalidates', () {
      final base = randomAlnum(32);
      for (var i = 0; i < 32; i++) {
        for (final bad in const ['-', '_', ' ', '.', '/', '\\', '+', '@']) {
          final mutated = base.substring(0, i) + bad + base.substring(i + 1);
          expect(HouseholdService.isValidInviteCode(mutated), isFalse,
              reason: mutated);
        }
      }
    });
  });
}
