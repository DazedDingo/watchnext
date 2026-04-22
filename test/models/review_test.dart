import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/review.dart';

void main() {
  group('Review.fromMap', () {
    test('parses a standard TMDB review', () {
      final r = Review.fromMap({
        'id': '5abc',
        'author': 'mrbrown',
        'content': 'Loved it.',
        'created_at': '2024-06-01T12:00:00.000Z',
        'author_details': {'rating': 8.0, 'username': 'mrbrown'},
      });
      expect(r.id, '5abc');
      expect(r.author, 'mrbrown');
      expect(r.content, 'Loved it.');
      expect(r.rating, 8.0);
      expect(r.createdAt, isNotNull);
      expect(r.createdAt!.year, 2024);
    });

    test('falls back to author_details.username when author empty', () {
      final r = Review.fromMap({
        'id': '1',
        'author': '',
        'content': 'x',
        'author_details': {'username': 'fallbackuser'},
      });
      expect(r.author, 'fallbackuser');
    });

    test('defaults to Anonymous when no author info', () {
      final r = Review.fromMap({'id': '1', 'content': 'x'});
      expect(r.author, 'Anonymous');
    });

    test('null rating when author_details missing', () {
      final r = Review.fromMap({
        'id': '1',
        'author': 'x',
        'content': 'y',
      });
      expect(r.rating, isNull);
    });

    test('null createdAt when date missing or malformed', () {
      expect(
        Review.fromMap({'id': '1', 'content': 'x'}).createdAt,
        isNull,
      );
      expect(
        Review.fromMap({
          'id': '1',
          'content': 'x',
          'created_at': 'not-a-date',
        }).createdAt,
        isNull,
      );
    });
  });
}
