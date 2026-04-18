import 'package:cloud_firestore/cloud_firestore.dart';

enum IssueBatchStatus { pending, dispatched, cancelled }

IssueBatchStatus _parseStatus(String? raw) => switch (raw) {
      'dispatched' => IssueBatchStatus.dispatched,
      'cancelled' => IssueBatchStatus.cancelled,
      _ => IssueBatchStatus.pending,
    };

class IssueBatchItem {
  final String title;
  final String description;
  final DateTime? submittedAt;

  IssueBatchItem({
    required this.title,
    required this.description,
    this.submittedAt,
  });

  factory IssueBatchItem.fromMap(Map<String, dynamic> m) => IssueBatchItem(
        title: (m['title'] as String?) ?? '',
        description: (m['description'] as String?) ?? '',
        submittedAt: (m['submittedAt'] as Timestamp?)?.toDate(),
      );
}

class IssueBatch {
  final String id;
  final String uid;
  final List<IssueBatchItem> items;
  final DateTime createdAt;
  final DateTime dispatchAt;
  final IssueBatchStatus status;
  final int? dispatchedIssueNumber;
  final String? dispatchedUrl;

  IssueBatch({
    required this.id,
    required this.uid,
    required this.items,
    required this.createdAt,
    required this.dispatchAt,
    required this.status,
    this.dispatchedIssueNumber,
    this.dispatchedUrl,
  });

  Duration remaining(DateTime now) {
    final diff = dispatchAt.difference(now);
    return diff.isNegative ? Duration.zero : diff;
  }

  factory IssueBatch.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final rawItems = (d['items'] as List?) ?? const [];
    final result = d['dispatchResult'] as Map<String, dynamic>?;
    return IssueBatch(
      id: doc.id,
      uid: (d['uid'] as String?) ?? '',
      items: [
        for (final it in rawItems)
          if (it is Map<String, dynamic>) IssueBatchItem.fromMap(it),
      ],
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dispatchAt: (d['dispatchAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      status: _parseStatus(d['status'] as String?),
      dispatchedIssueNumber: (result?['issueNumber'] as num?)?.toInt(),
      dispatchedUrl: result?['url'] as String?,
    );
  }
}
