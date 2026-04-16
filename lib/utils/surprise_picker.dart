import 'dart:math';

import '../models/recommendation.dart';

/// Picks one of the top [topN] recs at random so the user can offload the
/// choice entirely. Isolated as a pure function so the test suite can pin the
/// RNG and assert correctness without stubbing out Dart's `Random`.
///
/// Returns null when [pool] is empty — callers should disable the button in
/// that case rather than rendering a "picked nothing" error.
Recommendation? pickSurprise(
  List<Recommendation> pool, {
  int topN = 10,
  Random? random,
}) {
  if (pool.isEmpty) return null;
  final cap = pool.length < topN ? pool.length : topN;
  final rng = random ?? Random();
  return pool[rng.nextInt(cap)];
}
