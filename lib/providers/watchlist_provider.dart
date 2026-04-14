import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watchlist_item.dart';
import '../services/watchlist_service.dart';
import 'household_provider.dart';

final watchlistServiceProvider = Provider<WatchlistService>((_) => WatchlistService());

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
