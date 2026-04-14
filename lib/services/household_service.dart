import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Two-person household model (spec). Invite-code based onboarding.
/// Schema rooted at /households/{householdId} with /members/{userId} sub-docs.
class HouseholdService {
  final FirebaseFirestore _db;
  HouseholdService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  static final _tokenPattern = RegExp(r'^[a-zA-Z0-9]{20,64}$');
  static bool isValidInviteCode(String code) => _tokenPattern.hasMatch(code);

  String _randomToken(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Future<String> createHousehold(User user) async {
    final inviteCode = _randomToken(32);
    final ref = await _db.collection('households').add({
      'createdBy': user.uid,
      'created_at': FieldValue.serverTimestamp(),
      'invite_code': inviteCode,
    });

    // Write member first so isMember() is true when subsequent rules evaluate.
    await _db.doc('households/${ref.id}/members/${user.uid}').set({
      'display_name': user.displayName ?? 'Member',
      'email': user.email,
      'avatar_url': user.photoURL,
      'joined_at': FieldValue.serverTimestamp(),
      // Trakt fields populated in Phase 2:
      'trakt_access_token': null,
      'trakt_refresh_token': null,
      'trakt_user_id': null,
      'last_trakt_sync': null,
      'default_mode': 'together', // 'solo' | 'together'
    });

    // Fast permission-safe lookup for user → household.
    await _db.doc('users/${user.uid}').set(
      {'householdId': ref.id},
      SetOptions(merge: true),
    );

    // Public lookup: invite code → householdId.
    await _db.doc('invites/$inviteCode').set({'householdId': ref.id});

    return ref.id;
  }

  /// Returns householdId on success, null if invite not found, or throws
  /// 'Household full' if already has 2 members.
  Future<String?> joinByInviteCode(User user, String code) async {
    final inviteDoc = await _db.doc('invites/$code').get();
    if (!inviteDoc.exists) return null;

    final householdId = inviteDoc.data()!['householdId'] as String;

    // Enforce two-person cap.
    final members = await _db.collection('households/$householdId/members').get();
    if (members.size >= 2 && !members.docs.any((d) => d.id == user.uid)) {
      throw Exception('Household full — two-person cap reached.');
    }

    await _db.doc('households/$householdId/members/${user.uid}').set({
      'display_name': user.displayName ?? 'Member',
      'email': user.email,
      'avatar_url': user.photoURL,
      'joined_at': FieldValue.serverTimestamp(),
      'trakt_access_token': null,
      'trakt_refresh_token': null,
      'trakt_user_id': null,
      'last_trakt_sync': null,
      'default_mode': 'together',
    });
    await _db.doc('users/${user.uid}').set(
      {'householdId': householdId},
      SetOptions(merge: true),
    );
    return householdId;
  }

  Future<String?> getHouseholdIdForUser(String uid) async {
    final doc = await _db.doc('users/$uid').get();
    return doc.data()?['householdId'] as String?;
  }
}
