import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/trakt_service.dart';
import '../services/trakt_sync_service.dart';
import 'auth_provider.dart';
import 'household_provider.dart';
import 'tmdb_provider.dart';

final traktServiceProvider = Provider<TraktService>((ref) {
  final service = TraktService();
  ref.onDispose(service.dispose);
  return service;
});

final traktSyncServiceProvider = Provider<TraktSyncService>((ref) {
  return TraktSyncService(
    trakt: ref.watch(traktServiceProvider),
    tmdb: ref.watch(tmdbServiceProvider),
  );
});

/// Streams the Trakt link status for the current user (from member doc).
final traktLinkStatusProvider = StreamProvider<TraktLinkStatus>((ref) async* {
  final user = ref.watch(authStateProvider).value;
  final householdId = ref.watch(householdIdProvider).value;
  if (user == null || householdId == null) {
    yield const TraktLinkStatus(linked: false);
    return;
  }
  final doc = FirebaseFirestore.instance.doc('households/$householdId/members/${user.uid}');
  yield* doc.snapshots().map((snap) {
    final data = snap.data() ?? const {};
    final token = data['trakt_access_token'] as String?;
    return TraktLinkStatus(
      linked: token != null && token.isNotEmpty,
      traktUserId: data['trakt_user_id'] as String?,
      lastSync: (data['last_trakt_sync'] as Timestamp?)?.toDate(),
    );
  });
});

class TraktLinkStatus {
  final bool linked;
  final String? traktUserId;
  final DateTime? lastSync;
  const TraktLinkStatus({required this.linked, this.traktUserId, this.lastSync});
}
