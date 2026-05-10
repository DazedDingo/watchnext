import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/not_interested_item.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/providers/not_interested_provider.dart';

NotInterestedItem _shared(String mt, int id) => NotInterestedItem(
      id: 'shared:shared:$mt:$id',
      mediaType: mt,
      tmdbId: id,
      title: 't',
      scope: 'shared',
      markedByUid: 'u1',
      markedAt: DateTime(2026, 5, 1),
    );

NotInterestedItem _solo(String mt, int id, String owner) => NotInterestedItem(
      id: 'solo:$owner:$mt:$id',
      mediaType: mt,
      tmdbId: id,
      title: 't',
      scope: 'solo',
      ownerUid: owner,
      markedByUid: owner,
      markedAt: DateTime(2026, 5, 1),
    );

void main() {
  group('computeNotInterestedKeys', () {
    test('Together mode includes shared, excludes ANY solo', () {
      final keys = computeNotInterestedKeys(
        [_shared('movie', 1), _solo('movie', 2, 'u1'), _solo('tv', 3, 'u2')],
        ViewMode.together,
        'u1',
      );
      expect(keys, {'movie:1'});
    });

    test('Solo mode includes shared + my own solo, excludes partner solo', () {
      final keys = computeNotInterestedKeys(
        [
          _shared('movie', 1),
          _solo('movie', 2, 'u1'), // mine
          _solo('tv', 3, 'u2'),    // partner's
        ],
        ViewMode.solo,
        'u1',
      );
      expect(keys, {'movie:1', 'movie:2'});
    });

    test('Solo with no uid is the same as Together', () {
      final keys = computeNotInterestedKeys(
        [_shared('movie', 1), _solo('movie', 2, 'u1')],
        ViewMode.solo,
        null,
      );
      expect(keys, {'movie:1'});
    });

    test('empty input returns an empty set', () {
      expect(
        computeNotInterestedKeys(const [], ViewMode.together, 'u1'),
        isEmpty,
      );
    });

    test('shared + my-solo on the same title dedupes by titleKey', () {
      final keys = computeNotInterestedKeys(
        [_shared('movie', 5), _solo('movie', 5, 'u1')],
        ViewMode.solo,
        'u1',
      );
      expect(keys, {'movie:5'});
    });
  });
}
