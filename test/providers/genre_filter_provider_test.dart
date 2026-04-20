import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchnext/providers/genre_filter_provider.dart';
import 'package:watchnext/providers/mode_provider.dart';
import 'package:watchnext/utils/tmdb_genres.dart';

void main() {
  group('ModeGenreController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(const {});
    });

    test('starts with empty sets for both modes', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      expect(c.state[ViewMode.solo], isEmpty);
      expect(c.state[ViewMode.together], isEmpty);
    });

    test('toggle adds then removes the same genre', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.toggle(ViewMode.solo, 'War');
      expect(c.state[ViewMode.solo], {'War'});
      await c.toggle(ViewMode.solo, 'War');
      expect(c.state[ViewMode.solo], isEmpty);
    });

    test('toggle accumulates multiple distinct genres', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.toggle(ViewMode.solo, 'War');
      await c.toggle(ViewMode.solo, 'Drama');
      expect(c.state[ViewMode.solo], {'War', 'Drama'});
    });

    test('set replaces the whole set for a mode', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.set(ViewMode.solo, {'War', 'Drama'});
      await c.set(ViewMode.solo, {'Comedy'});
      expect(c.state[ViewMode.solo], {'Comedy'});
    });

    test('clear empties the mode and removes the key', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.set(ViewMode.solo, {'War'});
      expect(prefs.containsKey('wn_genres_solo'), isTrue);
      await c.clear(ViewMode.solo);
      expect(c.state[ViewMode.solo], isEmpty);
      expect(prefs.containsKey('wn_genres_solo'), isFalse);
    });

    test('setting solo does not affect together and vice versa', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.set(ViewMode.solo, {'War'});
      expect(c.state[ViewMode.together], isEmpty);
      await c.set(ViewMode.together, {'Comedy'});
      expect(c.state[ViewMode.solo], {'War'});
      expect(c.state[ViewMode.together], {'Comedy'});
    });

    test('persists as sorted JSON list under per-mode keys', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.set(ViewMode.solo, {'War', 'Drama', 'Animation'});
      final raw = prefs.getString('wn_genres_solo');
      expect(raw, isNotNull);
      final decoded = json.decode(raw!) as List;
      expect(decoded, ['Animation', 'Drama', 'War']);
      expect(prefs.containsKey('wn_genres_together'), isFalse);
    });

    test('empty set removes the key rather than writing "[]"', () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      await c.set(ViewMode.solo, {'War'});
      await c.set(ViewMode.solo, const <String>{});
      expect(prefs.containsKey('wn_genres_solo'), isFalse);
    });

    test('readAll hydrates both modes independently from stored JSON',
        () async {
      SharedPreferences.setMockInitialValues({
        'wn_genres_solo': json.encode(['War', 'Drama']),
        'wn_genres_together': json.encode(['Comedy']),
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeGenreController.readAll(prefs);
      expect(map[ViewMode.solo], {'War', 'Drama'});
      expect(map[ViewMode.together], {'Comedy'});
    });

    test('malformed JSON in prefs decodes to empty set (forward-compat)',
        () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_genres_solo': 'this-is-not-json',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeGenreController.readAll(prefs);
      expect(map[ViewMode.solo], isEmpty);
    });

    test('JSON non-list decodes to empty set (defensive)', () async {
      SharedPreferences.setMockInitialValues(const {
        'wn_genres_solo': '{"not":"a list"}',
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeGenreController.readAll(prefs);
      expect(map[ViewMode.solo], isEmpty);
    });

    test('non-string entries in stored list are dropped', () async {
      SharedPreferences.setMockInitialValues({
        'wn_genres_solo': json.encode(['War', 42, null, 'Drama']),
      });
      final prefs = await SharedPreferences.getInstance();
      final map = ModeGenreController.readAll(prefs);
      expect(map[ViewMode.solo], {'War', 'Drama'});
    });

    test('state emits a new map reference on mutation (immutable update)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final c = ModeGenreController(
        prefs,
        ModeGenreController.readAll(prefs),
      );
      final before = c.state;
      await c.set(ViewMode.solo, {'War'});
      expect(identical(before, c.state), isFalse,
          reason: 'StateNotifier must write a new Map so Riverpod rebuilds');
    });
  });

  group('allGenresProvider contents (invariants on tmdb_genres)', () {
    test('union of movie + tv genre names is sorted + deduped', () {
      final union = <String>{
        ...tmdbMovieGenres.values,
        ...tmdbTvGenres.values,
      }.toList()
        ..sort();
      // Sanity: common genres appear, duplicates removed, TV-specific names
      // like "Action & Adventure" survive alongside movie-only names.
      expect(union, contains('War'));
      expect(union, contains('Documentary'));
      expect(union, contains('Action & Adventure'));
      // Sorted invariant: every entry ≤ next entry.
      for (var i = 0; i + 1 < union.length; i++) {
        expect(union[i].compareTo(union[i + 1]) <= 0, isTrue,
            reason: '${union[i]} should sort before ${union[i + 1]}');
      }
    });
  });
}
