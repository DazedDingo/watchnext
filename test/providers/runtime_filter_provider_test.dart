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
      // `matches(null)` stays strict — the bucket itself reports "no,
      // unknown doesn't pass". The Home filter is now the layer that
      // chooses whether to keep unknowns (it does, to avoid blanking the
      // list when discover/trending candidates lack runtime metadata).
      // See home_screen.dart `runtimeFiltered`.
      for (final b in RuntimeBucket.values) {
        expect(b.matches(null), isFalse);
      }
    });

    test('home-screen null-passthrough — matches(rt) || rt == null', () {
      // Guards the client-side rule the Home filter uses now that null
      // runtime recs (trending/top_rated/discover) pass through any active
      // bucket. Regression lock: changing this rule without updating
      // home_screen.dart will blank the rec list again.
      bool passes(RuntimeBucket b, int? rt) => rt == null || b.matches(rt);

      expect(passes(RuntimeBucket.short, null), isTrue);
      expect(passes(RuntimeBucket.medium, null), isTrue);
      expect(passes(RuntimeBucket.long_, null), isTrue);

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
