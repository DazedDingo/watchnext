import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'providers/ask_ai_placement_provider.dart';
import 'providers/onboarding_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/up_next_style_provider.dart';
import 'services/home_widget_service.dart';

/// Background FCM handler. Runs in its own isolate when a data message
/// arrives while the app is killed/backgrounded. MUST be a top-level
/// (or static) function — registering an instance method as a background
/// handler is silently dropped by the platform.
///
/// Only handles `type=refresh_widget` from the `refreshUpNextWidget`
/// Cloud Function. Other payloads (reveal_ready, next_episode_today)
/// arrive with a `notification` block and are shown by the OS without
/// needing our hook — the foreground tap handler in
/// `notification_service.dart` is what routes those to a screen.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // The background isolate has its own Firebase instance and needs init.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final data = message.data;
  if (data['type'] == 'refresh_widget') {
    try {
      await HomeWidgetService.pushUpNextFromFcmPayload(data);
    } catch (_) {
      // Best-effort — a bg refresh failing must never crash the isolate.
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Replace the default gray rectangle shown on build failures in release
  // mode — we'd rather see the actual error than a blank screen.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFF1A1A1A),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
                const SizedBox(height: 12),
                const Text('Something went wrong rendering this screen',
                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  details.exceptionAsString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Register the background FCM handler BEFORE the app starts listening
  // for messages — Firebase Messaging caches the registration once per
  // process and skipping this means data-only refresh pushes silently
  // no-op when the app isn't already running.
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [
      accentProvider.overrideWith((_) => AccentController(prefs)),
      askAiPlacementProvider
          .overrideWith((_) => AskAiPlacementController(prefs)),
      upNextStyleProvider
          .overrideWith((_) => UpNextStyleController(prefs)),
      onboardingDoneProvider
          .overrideWith((_) => OnboardingController(prefs)),
    ],
    child: const WatchNextApp(),
  ));
}
