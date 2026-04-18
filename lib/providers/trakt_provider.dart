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
      historyScope: TraktHistoryScope.decode(
          data['trakt_history_scope'] as String?),
    );
  });
});

class TraktLinkStatus {
  final bool linked;
  final String? traktUserId;
  final DateTime? lastSync;
  final TraktHistoryScope historyScope;
  const TraktLinkStatus({
    required this.linked,
    this.traktUserId,
    this.lastSync,
    this.historyScope = TraktHistoryScope.mixed,
  });
}

/// Tells the sync service how to stamp `context` on imported Trakt ratings.
/// Users set this at link time (or later) because Trakt has no per-row
/// "was this solo or together?" flag — we ask once and apply it to the whole
/// history. Default is [mixed] (import without stamping) so we never silently
/// mis-attribute — the scorer can treat null-context ratings as pure history.
enum TraktHistoryScope {
  /// All Trakt activity was with the partner → stamp context='together'.
  shared,

  /// All Trakt activity was solo → stamp context='solo'.
  personal,

  /// Can't say; leave context null on imports.
  mixed;

  String get label {
    switch (this) {
      case TraktHistoryScope.shared:
        return 'With partner';
      case TraktHistoryScope.personal:
        return 'Solo';
      case TraktHistoryScope.mixed:
        return 'Mixed';
    }
  }

  /// Context string to write onto imported ratings, or null when unknown.
  String? get ratingContext {
    switch (this) {
      case TraktHistoryScope.shared:
        return 'together';
      case TraktHistoryScope.personal:
        return 'solo';
      case TraktHistoryScope.mixed:
        return null;
    }
  }

  static TraktHistoryScope decode(String? raw) {
    for (final v in TraktHistoryScope.values) {
      if (v.name == raw) return v;
    }
    return TraktHistoryScope.mixed;
  }
}
