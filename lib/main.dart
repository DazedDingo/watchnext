import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'providers/onboarding_provider.dart';
import 'providers/theme_provider.dart';

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
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [
      accentProvider.overrideWith((_) => AccentController(prefs)),
      onboardingDoneProvider
          .overrideWith((_) => OnboardingController(prefs)),
    ],
    child: const WatchNextApp(),
  ));
}
