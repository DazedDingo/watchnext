import 'package:flutter_test/flutter_test.dart';
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
      for (final b in RuntimeBucket.values) {
        expect(b.matches(null), isFalse);
      }
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
}
