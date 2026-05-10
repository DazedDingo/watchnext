import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/not_interested_item.dart';
import '../services/not_interested_service.dart';
import 'auth_provider.dart';
import 'household_provider.dart';
import 'mode_provider.dart';

final notInterestedServiceProvider =
    Provider<NotInterestedService>((_) => NotInterestedService());

/// Raw stream of every NI doc in the household — shared + every member's
/// solo. Screens that need just the keys to filter against use
/// [notInterestedKeysProvider] instead.
final notInterestedProvider =
    StreamProvider<List<NotInterestedItem>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/notInterested')
      .orderBy('marked_at', descending: true)
      .snapshots()
      .map((s) => s.docs.map(NotInterestedItem.fromDoc).toList());
});

/// Items the *current user* would see in the Library "Hidden" tab —
/// shared dismissals + my own solo dismissals. The partner's solo
/// dismissals never appear here.
final visibleNotInterestedProvider =
    Provider<List<NotInterestedItem>>((ref) {
  final items = ref.watch(notInterestedProvider).value ?? const [];
  final uid = ref.watch(authStateProvider).value?.uid;
  return items.where((n) {
    if (n.scope == 'shared') return true;
    return uid != null && n.ownerUid == uid;
  }).toList();
});

/// Pure helper exposed for tests. Given the full set of NI items, the
/// current view mode, and the current user's uid, returns the set of
/// `{mediaType}:{tmdbId}` keys that should be filtered OUT of recommendation
/// surfaces.
///
/// Mode contract:
///   - Solo: shared ∪ my-solo
///   - Together: shared only (your partner's solo dismissals don't
///     pollute the joint recs surface — they marked it "not for me",
///     not "not for us")
Set<String> computeNotInterestedKeys(
  Iterable<NotInterestedItem> items,
  ViewMode mode,
  String? uid,
) {
  final keys = <String>{};
  for (final n in items) {
    if (n.scope == 'shared') {
      keys.add(n.titleKey);
    } else if (mode == ViewMode.solo && uid != null && n.ownerUid == uid) {
      keys.add(n.titleKey);
    }
  }
  return keys;
}

final notInterestedKeysProvider = Provider<Set<String>>((ref) {
  final items = ref.watch(notInterestedProvider).value ?? const [];
  final mode = ref.watch(viewModeProvider);
  final uid = ref.watch(authStateProvider).value?.uid;
  return computeNotInterestedKeys(items, mode, uid);
});

/// Whether the current title is hidden for the current user under the
/// current mode. Used by the title-detail overflow menu to render
/// "Not interested" vs. "Interested again".
final isNotInterestedProvider = Provider.family<bool, ({String mediaType, int tmdbId})>(
  (ref, ref0) {
    final keys = ref.watch(notInterestedKeysProvider);
    return keys.contains('${ref0.mediaType}:${ref0.tmdbId}');
  },
);
