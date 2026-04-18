import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/models/issue_batch.dart';

Future<DocumentSnapshot<Map<String, dynamic>>> _write(
  Map<String, dynamic> data,
) async {
  final fs = FakeFirebaseFirestore();
  final ref = fs.collection('households/h/issueBatches').doc('b1');
  await ref.set(data);
  return ref.get();
}

void main() {
  group('IssueBatch.fromDoc', () {
    test('parses a minimal pending batch', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [
          {
            'title': 'A',
            'description': 'b',
            'submittedAt': Timestamp.fromMillisecondsSinceEpoch(1000),
          },
        ],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(600000),
        'status': 'pending',
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(batch.id, 'b1');
      expect(batch.uid, 'u1');
      expect(batch.items, hasLength(1));
      expect(batch.items.first.title, 'A');
      expect(batch.items.first.description, 'b');
      expect(batch.status, IssueBatchStatus.pending);
      expect(batch.dispatchedIssueNumber, isNull);
    });

    test('parses a dispatched batch with result', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'dispatched',
        'dispatchResult': {'issueNumber': 42, 'url': 'https://x/42'},
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(batch.status, IssueBatchStatus.dispatched);
      expect(batch.dispatchedIssueNumber, 42);
      expect(batch.dispatchedUrl, 'https://x/42');
    });

    test('status defaults to pending when unrecognised', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'who-knows',
      });
      expect(IssueBatch.fromDoc(doc).status, IssueBatchStatus.pending);
    });

    test('ignores non-map items defensively', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [
          {'title': 'ok', 'description': 'd'},
          'junk',
          42,
        ],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'pending',
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(batch.items, hasLength(1));
      expect(batch.items.first.title, 'ok');
    });

    test('remaining() returns zero when dispatchAt is in the past', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(1000),
        'status': 'pending',
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(
        batch.remaining(DateTime.fromMillisecondsSinceEpoch(5000)),
        Duration.zero,
      );
    });

    test('remaining() gives positive duration when dispatchAt is ahead',
        () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(60_000),
        'status': 'pending',
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(
        batch.remaining(DateTime.fromMillisecondsSinceEpoch(30_000)).inSeconds,
        30,
      );
    });

    test('parses cancelled status', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'cancelled',
      });
      expect(IssueBatch.fromDoc(doc).status, IssueBatchStatus.cancelled);
    });

    test('item with no submittedAt yields null DateTime — no crash', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [
          {'title': 'x', 'description': 'y'},
        ],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'pending',
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(batch.items.first.submittedAt, isNull);
    });

    test('missing dispatchResult → null issueNumber + url', () async {
      final doc = await _write({
        'uid': 'u1',
        'items': [],
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'dispatched',
        // No dispatchResult — treat as unknown.
      });
      final batch = IssueBatch.fromDoc(doc);
      expect(batch.status, IssueBatchStatus.dispatched);
      expect(batch.dispatchedIssueNumber, isNull);
      expect(batch.dispatchedUrl, isNull);
    });

    test('items list defaults to empty when field absent', () async {
      final doc = await _write({
        'uid': 'u1',
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'dispatchAt': Timestamp.fromMillisecondsSinceEpoch(0),
        'status': 'pending',
      });
      expect(IssueBatch.fromDoc(doc).items, isEmpty);
    });
  });
}
