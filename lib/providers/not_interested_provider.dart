import 'dart:developer' as developer;

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
///
/// Errors are caught and converted to an empty list so a missing
/// Firestore-rules deploy on the new `/notInterested/{itemId}` row
/// doesn't surface as a permission-denied banner on Home / title detail
/// (those surfaces only need the FILTER set; an empty filter is the
/// honest fallback when reads fail). The error is still logged via
/// `dart:developer` so the rules-deployment requirement is visible in
/// console. The Library → Hidden tab DOES surface the error explicitly
/// via `AsyncErrorView` — that's the right place to learn "I can't
/// read this collection right now."
final notInterestedProvider =
    StreamProvider<List<NotInterestedItem>>((ref) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) {
    yield const [];
    return;
  }
  // Yield an empty list FIRST so downstream filter providers transition
  // out of `loading` immediately. If the snapshots stream subsequently
  // errors (e.g. Firestore rules for /notInterested haven't been
  // deployed yet — this row is new in v0.9.7), `.handleError` swaps the
  // error event for a log line and drops it, so the empty list stays as
  // the last value and recommendation surfaces keep working.
  //
  // NB: `try { yield* stream; } catch (...)` in `async*` does NOT catch
  // stream-error events — the error still propagates to the consumer's
  // AsyncValue. Use `.handleError` on the stream itself. (The prior
  // try/catch was a bug — see commit 687c5ff for why it didn't work.)
  yield const [];
  yield* FirebaseFirestore.instance
      .collection('households/$householdId/notInterested')
      .orderBy('marked_at', descending: true)
      .snapshots()
      .handleError((Object e, StackTrace st) {
        developer.log(
          'notInterestedProvider stream error (deploy `firestore:rules`?): $e',
          name: 'wn.notInterested',
          error: e,
          stackTrace: st,
        );
        // Returning normally from handleError drops the error event;
        // the consumer never sees it.
      })
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
