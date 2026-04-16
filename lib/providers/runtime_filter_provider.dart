import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Length-of-the-thing filter, sitting alongside the mood pills on Home.
///
/// Runtimes are stored in minutes on WatchEntry / WatchlistItem /
/// Recommendation. A null runtime on a rec means TMDB trending didn't
/// include it (trending endpoints omit runtime to keep payloads small).
/// When a bucket is active, we hide null-runtime recs — the user asked
/// for a specific length and we can't honestly say whether a mystery-length
/// item qualifies.
enum RuntimeBucket {
  short, // < 90 min
  medium, // 90–120 min
  long_, // > 120 min
}

extension RuntimeBucketExt on RuntimeBucket {
  String get label {
    switch (this) {
      case RuntimeBucket.short:
        return '< 90 min';
      case RuntimeBucket.medium:
        return '90–120';
      case RuntimeBucket.long_:
        return '> 2h';
    }
  }

  /// Returns true iff [runtimeMinutes] falls inside this bucket.
  /// A null runtime never matches — we'd rather drop it from a length-filtered
  /// list than show something whose length we can't confirm.
  bool matches(int? runtimeMinutes) {
    if (runtimeMinutes == null) return false;
    switch (this) {
      case RuntimeBucket.short:
        return runtimeMinutes < 90;
      case RuntimeBucket.medium:
        return runtimeMinutes >= 90 && runtimeMinutes <= 120;
      case RuntimeBucket.long_:
        return runtimeMinutes > 120;
    }
  }
}

/// Currently selected runtime bucket on Home. null = no runtime filter.
final runtimeFilterProvider = StateProvider<RuntimeBucket?>((ref) => null);
