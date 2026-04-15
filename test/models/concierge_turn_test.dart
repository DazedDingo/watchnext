import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/concierge_turn.dart';

void main() {
  group('TitleSuggestion', () {
    test('fromMap parses CF response shape', () {
      final t = TitleSuggestion.fromMap(<String, dynamic>{
        'tmdb_id': 42,
        'media_type': 'movie',
        'title': 'The Matrix',
        'year': 1999,
        'reason': 'cyberpunk',
      });
      expect(t.tmdbId, 42);
      expect(t.mediaType, 'movie');
      expect(t.title, 'The Matrix');
      expect(t.year, 1999);
      expect(t.reason, 'cyberpunk');
    });

    test('fromMap defaults mediaType to movie when missing', () {
      final t = TitleSuggestion.fromMap(<String, dynamic>{
        'tmdb_id': 1,
        'title': 'X',
        'reason': 'r',
      });
      expect(t.mediaType, 'movie');
      expect(t.year, isNull);
    });

    test('toMap roundtrip preserves fields', () {
      const t = TitleSuggestion(
        tmdbId: 1,
        mediaType: 'tv',
        title: 'X',
        year: 2020,
        reason: 'r',
      );
      final roundtrip = TitleSuggestion.fromMap(t.toMap());
      expect(roundtrip.tmdbId, 1);
      expect(roundtrip.mediaType, 'tv');
      expect(roundtrip.title, 'X');
      expect(roundtrip.year, 2020);
      expect(roundtrip.reason, 'r');
    });
  });

  group('ConciergeTurn.fromDoc', () {
    test('parses stored turn with nested titles array', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('t/1').set({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'hi',
        'response_text': 'hey',
        'titles': [
          {
            'tmdb_id': 42,
            'media_type': 'movie',
            'title': 'M',
            'year': 2020,
            'reason': 'r',
          },
        ],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final turn = ConciergeTurn.fromDoc(await db.doc('t/1').get());
      expect(turn.uid, 'u1');
      expect(turn.sessionId, 's1');
      expect(turn.message, 'hi');
      expect(turn.responseText, 'hey');
      expect(turn.titles, hasLength(1));
      expect(turn.titles.first.title, 'M');
      expect(turn.createdAt.isAtSameMomentAs(DateTime.utc(2025, 1, 1)), isTrue);
    });

    test('fromDoc defaults empty titles array gracefully', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('t/1').set({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'hi',
        'response_text': 'hey',
      });
      final turn = ConciergeTurn.fromDoc(await db.doc('t/1').get());
      expect(turn.titles, isEmpty);
    });
  });
}
