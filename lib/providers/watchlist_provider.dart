import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watchlist_item.dart';
import '../services/watchlist_service.dart';
import 'auth_provider.dart';
import 'household_provider.dart';
import 'mode_provider.dart';

final watchlistServiceProvider = Provider<WatchlistService>((_) => WatchlistService());

/// Raw stream of every watchlist doc in the household — shared + every
/// member's solo. Screens usually want [visibleWatchlistProvider] instead,
/// which applies the Solo/Together visibility filter.
final watchlistProvider = StreamProvider<List<WatchlistItem>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/watchlist')
      .orderBy('added_at', descending: true)
      .snapshots()
      .map((s) => s.docs.map(WatchlistItem.fromDoc).toList());
});

/// Visibility rules:
///   - Together mode: only `scope == 'shared'`.
///   - Solo mode: `scope == 'shared'` + my own `scope == 'solo'` items.
///     The partner's solo items are always excluded.
final visibleWatchlistProvider = Provider<List<WatchlistItem>>((ref) {
  final items = ref.watch(watchlistProvider).value ?? const [];
  final mode = ref.watch(viewModeProvider);
  final uid = ref.watch(authStateProvider).value?.uid;
  return items.where((w) {
    if (w.scope == 'shared') return true;
    // scope == 'solo'
    if (mode == ViewMode.together) return false;
    return uid != null && w.ownerUid == uid;
  }).toList();
});
