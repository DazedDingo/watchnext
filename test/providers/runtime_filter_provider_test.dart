import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/runtime_filter_provider.dart';

void main() {
  group('RuntimeBucket.matches', () {
    test('short covers [0, 90)', () {
      expect(RuntimeBucket.short.matches(1), isTrue);
      expect(RuntimeBucket.short.matches(89), isTrue);
      expect(RuntimeBucket.short.matches(90), isFalse);
    });

    test('medium covers [90, 120]', () {
      expect(RuntimeBucket.medium.matches(89), isFalse);
      expect(RuntimeBucket.medium.matches(90), isTrue);
      expect(RuntimeBucket.medium.matches(100), isTrue);
      expect(RuntimeBucket.medium.matches(120), isTrue);
      expect(RuntimeBucket.medium.matches(121), isFalse);
    });

    test('long_ covers (120, +∞)', () {
      expect(RuntimeBucket.long_.matches(120), isFalse);
      expect(RuntimeBucket.long_.matches(121), isTrue);
      expect(RuntimeBucket.long_.matches(300), isTrue);
    });

    test('buckets are disjoint except at boundaries', () {
      // Every runtime between 1 and 240 should match at most one bucket,
      // and every runtime should match at least one.
      for (var m = 1; m <= 240; m++) {
        final hits =
            RuntimeBucket.values.where((b) => b.matches(m)).toList();
        expect(hits, hasLength(1),
            reason: '$m minutes matched ${hits.length} buckets: $hits');
      }
    });

    test('null runtime matches nothing (unknown length is filtered out)', () {
      // `matches(null)` is strict and the Home filter uses it strictly too —
      // discover rows are stamped with a synthetic runtime by the service
      // (TMDB already confirmed in-bounds), so the pool has candidates to
      // match. Trending/top-rated rows lack runtime and intentionally drop
      // when a bucket is active; "Short" shouldn't surface a random 180-min
      // pick just because the source didn't include runtime.
      for (final b in RuntimeBucket.values) {
        expect(b.matches(null), isFalse);
      }
    });

    test('home-screen strict filter — drops null-runtime when bucket active',
        () {
      // Regression lock for the Home filter rule `runtime.matches(r.runtime)`.
      // Changing the bucket to pass nulls without first confirming the pool
      // has runtime-tagged candidates would resurrect the "filter does nothing"
      // bug the user reported.
      bool passes(RuntimeBucket b, int? rt) => b.matches(rt);

      expect(passes(RuntimeBucket.short, null), isFalse);
      expect(passes(RuntimeBucket.medium, null), isFalse);
      expect(passes(RuntimeBucket.long_, null), isFalse);

      expect(passes(RuntimeBucket.short, 85), isTrue);
      expect(passes(RuntimeBucket.short, 120), isFalse);
      expect(passes(RuntimeBucket.long_, 150), isTrue);
    });

    test('every bucket has a non-empty label', () {
      for (final b in RuntimeBucket.values) {
        expect(b.label, isNotEmpty);
      }
    });

    test('labels are unique (no duplicate pills on the home screen)', () {
      final labels = RuntimeBucket.values.map((b) => b.label).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('minRuntime/maxRuntime drive TMDB with_runtime bounds', () {
      // These bounds are what we send to `/discover?with_runtime.gte/lte`.
      // Regression lock: shifting them requires updating the bucket.matches
      // rule to stay consistent with what TMDB will hand us back.
      expect(RuntimeBucket.short.minRuntime, isNull);
      expect(RuntimeBucket.short.maxRuntime, 89);

      expect(RuntimeBucket.medium.minRuntime, 90);
      expect(RuntimeBucket.medium.maxRuntime, 120);

      expect(RuntimeBucket.long_.minRuntime, 121);
      expect(RuntimeBucket.long_.maxRuntime, isNull);
    });

    test('bounds + matches stay consistent at boundaries', () {
      // Whatever values TMDB returns inside the sent bounds must also pass
      // the client-side `matches` check — otherwise the strict Home filter
      // would drop server-filtered rows.
      for (final b in RuntimeBucket.values) {
        if (b.minRuntime != null) {
          expect(b.matches(b.minRuntime), isTrue,
              reason: '$b.matches(minRuntime) should be true');
        }
        if (b.maxRuntime != null) {
          expect(b.matches(b.maxRuntime), isTrue,
              reason: '$b.matches(maxRuntime) should be true');
        }
      }
    });
  });

  group('ModeRuntimeController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('setting solo does not affect together and vice versa', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeRuntimeController(prefs, ModeRuntimeController.readAll(prefs));
      await c.set(ViewMode.solo, RuntimeBucket.short);
      expect(c.state[ViewMode.solo], RuntimeBucket.short);
      expect(c.state[ViewMode.together], isNull);

      await c.set(ViewMode.together, RuntimeBucket.long_);
      expect(c.state[ViewMode.solo], RuntimeBucket.short);
      expect(c.state[ViewMode.together], RuntimeBucket.long_);
    });

    test('persists to SharedPreferences under two keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeRuntimeController(prefs, ModeRuntimeController.readAll(prefs));
      await c.set(ViewMode.solo, RuntimeBucket.short);
      await c.set(ViewMode.together, RuntimeBucket.medium);

      expect(prefs.getString('wn_runtime_solo'), 'short');
      expect(prefs.getString('wn_runtime_together'), 'medium');
    });

    test('set(null) removes the key', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_runtime_solo': 'short',
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ModeRuntimeController(prefs, ModeRuntimeController.readAll(prefs));
      expect(c.state[ViewMode.solo], RuntimeBucket.short);

      await c.set(ViewMode.solo, null);
      expect(c.state[ViewMode.solo], isNull);
      expect(prefs.containsKey('wn_runtime_solo'), isFalse);
    });

    test('unknown stored value decodes to null (forward-compat)', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_runtime_solo': 'epic',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeRuntimeController.readAll(prefs);
      expect(map[ViewMode.solo], isNull);
    });
  });
}
