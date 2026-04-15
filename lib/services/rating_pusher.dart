/// Narrow dependency surface that RatingService uses to push to Trakt.
/// Extracted from TraktService so RatingService can be unit-tested with a
/// stub — the full TraktService pulls in Firebase Functions / Firestore /
/// flutter_web_auth_2 which aren't available in a plain Dart test.
///
/// TraktService `implements RatingPusher` — same method shapes, no runtime
/// change for production code.
abstract class RatingPusher {
  Future<String> getLiveAccessToken({
    required String householdId,
    required String uid,
  });

  Future<void> pushRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
    required int stars,
  });
}
