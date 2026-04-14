import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Wraps Firebase Messaging setup for Phase 10.
///
/// Responsibilities:
/// 1. Request notification permission on first call.
/// 2. Write the FCM token to /households/{hh}/members/{uid} so the
///    `onRatingCreated` Cloud Function can send reveals to the right device.
/// 3. Refresh the token whenever FCM rotates it.
/// 4. Route tap events (foreground and cold-start) to /reveal/:mediaType/:tmdbId.
///
/// Call [init] once after the user is authenticated and the household is known.
class NotificationService {
  static final _messaging = FirebaseMessaging.instance;

  /// One-shot setup. Safe to call multiple times — duplicate calls are no-ops
  /// because [requestPermission] only prompts once and token writes are idempotent.
  static Future<void> init({
    required String householdId,
    required String uid,
    required BuildContext context,
  }) async {
    // 1. Request permission (Android 13+ / iOS). On older Android this is a no-op.
    await _messaging.requestPermission(
      alert: true,
      badge: false,
      sound: true,
    );

    // 2. Write current token.
    final token = await _messaging.getToken();
    if (token != null) {
      await _saveToken(householdId: householdId, uid: uid, token: token);
    }

    // 3. Refresh handler.
    _messaging.onTokenRefresh.listen((newToken) {
      _saveToken(householdId: householdId, uid: uid, token: newToken);
    });

    // 4a. Foreground message: show a snack + navigate on tap.
    FirebaseMessaging.onMessage.listen((msg) {
      if (!context.mounted) return;
      final data = msg.data;
      if (data['type'] == 'reveal_ready') {
        _showRevealSnack(context, data);
      }
    });

    // 4b. Background/terminated tap: app opened via notification.
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      if (!context.mounted) return;
      _routeReveal(context, msg.data);
    });

    // 4c. App launched from terminated state by notification tap.
    final initial = await _messaging.getInitialMessage();
    if (initial != null && context.mounted) {
      // Defer until after the first frame so the router is ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) _routeReveal(context, initial.data);
      });
    }
  }

  static Future<void> _saveToken({
    required String householdId,
    required String uid,
    required String token,
  }) async {
    await FirebaseFirestore.instance
        .doc('households/$householdId/members/$uid')
        .set({'fcm_token': token}, SetOptions(merge: true));
  }

  static void _routeReveal(
      BuildContext context, Map<String, dynamic> data) {
    final mediaType = data['media_type'] as String?;
    final tmdbId = data['tmdb_id'] as String?;
    if (mediaType != null && tmdbId != null) {
      context.push('/reveal/$mediaType/$tmdbId');
    }
  }

  static void _showRevealSnack(
      BuildContext context, Map<String, dynamic> data) {
    final title = data['title'] as String? ?? 'a title';
    final mediaType = data['media_type'] as String?;
    final tmdbId = data['tmdb_id'] as String?;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reveal time! See how well you predicted $title'),
        action: (mediaType != null && tmdbId != null)
            ? SnackBarAction(
                label: 'View',
                onPressed: () =>
                    context.push('/reveal/$mediaType/$tmdbId'),
              )
            : null,
        duration: const Duration(seconds: 6),
      ),
    );
  }
}
