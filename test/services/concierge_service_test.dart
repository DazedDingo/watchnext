import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/concierge_service.dart';

/// Covers the Firestore-only surface of ConciergeService. The CF-backed
/// `chat` method is exercised via the functions/test suite (helpers) and
/// rules emulator — here we just verify the history stream contract.
void main() {
  group('ConciergeService.historyStream', () {
    late FakeFirebaseFirestore db;
    late ConciergeService svc;
    const hh = 'hh1';

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = ConciergeService(db: db);
    });

    test('emits empty list when no history exists', () async {
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(events.first, isEmpty);
    });

    test('filters by session_id', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'in-session',
        'response_text': 'r',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      await col.add({
        'uid': 'u1',
        'session_id': 's2',
        'message': 'other-session',
        'response_text': 'r',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 2)),
      });
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(events.last, hasLength(1));
      expect(events.last.first.message, 'in-session');
    });

    test('orders oldest-first by created_at', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'second',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 5)),
      });
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'first',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      final events = [];
      final sub = svc.historyStream(hh, 's1').listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      final last = events.last as List;
      expect(last.map((t) => t.message), ['first', 'second']);
    });

    test('new message mid-stream propagates', () async {
      final col = db.collection('households/$hh/conciergeHistory');
      final events = <List>[];
      final sub = svc
          .historyStream(hh, 's1')
          .listen((e) => events.add(e as List));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await col.add({
        'uid': 'u1',
        'session_id': 's1',
        'message': 'live',
        'response_text': '',
        'titles': [],
        'created_at': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(events.last.length, 1);
      expect(events.last.first.message, 'live');
    });
  });
}
