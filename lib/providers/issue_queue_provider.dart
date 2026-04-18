import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/issue_batch.dart';
import 'auth_provider.dart';
import 'household_provider.dart';

/// Streams the current user's pending issue batch for this household. Emits
/// null when there's no open window — callers render an idle state.
final pendingIssueBatchProvider = StreamProvider<IssueBatch?>((ref) async* {
  final householdId = await ref.watch(householdIdProvider.future);
  final user = ref.watch(authStateProvider).valueOrNull;
  if (householdId == null || user == null) {
    yield null;
    return;
  }

  final stream = FirebaseFirestore.instance
      .collection('households/$householdId/issueBatches')
      .where('uid', isEqualTo: user.uid)
      .where('status', isEqualTo: 'pending')
      .limit(1)
      .snapshots();

  await for (final snap in stream) {
    if (snap.docs.isEmpty) {
      yield null;
    } else {
      yield IssueBatch.fromDoc(snap.docs.first);
    }
  }
});
