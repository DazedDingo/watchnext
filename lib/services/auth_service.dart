import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleSignInFailure implements Exception {
  final String stage;
  final String code;
  final String? message;
  final String? details;
  GoogleSignInFailure(this.stage, this.code, this.message, this.details);

  @override
  String toString() {
    final parts = [
      '[$stage] code=$code',
      if (message != null && message!.isNotEmpty) 'msg=$message',
      if (details != null && details!.isNotEmpty) 'details=$details',
    ];
    return parts.join(' ');
  }
}

class AuthService {
  final FirebaseAuth _auth;
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  final _googleSignIn = GoogleSignIn();

  Future<UserCredential> signInWithGoogle() async {
    GoogleSignInAccount? googleUser;
    try {
      googleUser = await _googleSignIn.signIn();
    } on PlatformException catch (e) {
      throw GoogleSignInFailure('google.signIn', e.code, e.message, '${e.details}');
    }
    if (googleUser == null) throw Exception('Sign-in cancelled');

    GoogleSignInAuthentication googleAuth;
    try {
      googleAuth = await googleUser.authentication;
    } on PlatformException catch (e) {
      throw GoogleSignInFailure('google.authentication', e.code, e.message, '${e.details}');
    }

    if (googleAuth.idToken == null) {
      throw GoogleSignInFailure(
        'google.authentication',
        'no_id_token',
        'Google returned no idToken — check SHA-1 in Firebase and that Google provider is enabled.',
        null,
      );
    }

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    try {
      return await _auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw GoogleSignInFailure('firebase.signInWithCredential', e.code, e.message, null);
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}
