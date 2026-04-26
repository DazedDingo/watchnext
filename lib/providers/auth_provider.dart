import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auth_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges;
});

/// Pure-Dart wrapper around the current user's uid so providers that just
/// need "who is signed in" can avoid a direct dependency on the
/// `firebase_auth` types. Easier to override in tests — `Provider<String?>`
/// vs. having to fake out a `User` instance.
final currentUidProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).value?.uid;
});
