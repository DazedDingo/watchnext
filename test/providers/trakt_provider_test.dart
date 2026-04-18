import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/providers/trakt_provider.dart';

void main() {
  group('TraktHistoryScope', () {
    test('every value has a non-empty label', () {
      for (final s in TraktHistoryScope.values) {
        expect(s.label, isNotEmpty);
      }
    });

    test('labels are unique', () {
      final labels = TraktHistoryScope.values.map((s) => s.label).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('ratingContext maps shared→together, personal→solo, mixed→null', () {
      expect(TraktHistoryScope.shared.ratingContext, 'together');
      expect(TraktHistoryScope.personal.ratingContext, 'solo');
      expect(TraktHistoryScope.mixed.ratingContext, isNull);
    });

    test('decode roundtrips the enum name', () {
      expect(TraktHistoryScope.decode('shared'), TraktHistoryScope.shared);
      expect(TraktHistoryScope.decode('personal'), TraktHistoryScope.personal);
      expect(TraktHistoryScope.decode('mixed'), TraktHistoryScope.mixed);
    });

    test('decode defaults to mixed for null / unknown values', () {
      expect(TraktHistoryScope.decode(null), TraktHistoryScope.mixed);
      expect(TraktHistoryScope.decode(''), TraktHistoryScope.mixed);
      expect(TraktHistoryScope.decode('bogus'), TraktHistoryScope.mixed);
      // Case-sensitive: 'Shared' is not 'shared'.
      expect(TraktHistoryScope.decode('Shared'), TraktHistoryScope.mixed);
    });
  });
}
