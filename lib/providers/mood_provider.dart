import 'package:flutter_riverpod/flutter_riverpod.dart';

enum WatchMood { dateNight, chill, intense, laugh, mindBending, feelGood, custom }

extension WatchMoodExt on WatchMood {
  String get label {
    switch (this) {
      case WatchMood.dateNight:
        return 'Date Night';
      case WatchMood.chill:
        return 'Chill';
      case WatchMood.intense:
        return 'Intense';
      case WatchMood.laugh:
        return 'Laugh';
      case WatchMood.mindBending:
        return 'Mind-Bending';
      case WatchMood.feelGood:
        return 'Feel-Good';
      case WatchMood.custom:
        return 'Custom';
    }
  }

  /// TMDB genre strings that map to this mood (matched against Recommendation.genres).
  List<String> get genres {
    switch (this) {
      case WatchMood.dateNight:
        return ['Romance', 'Drama'];
      case WatchMood.chill:
        return ['Comedy', 'Animation', 'Family'];
      case WatchMood.intense:
        return ['Thriller', 'Crime', 'Action'];
      case WatchMood.laugh:
        return ['Comedy'];
      case WatchMood.mindBending:
        return ['Science Fiction', 'Mystery', 'Fantasy'];
      case WatchMood.feelGood:
        return ['Comedy', 'Family', 'Animation', 'Romance'];
      case WatchMood.custom:
        return [];
    }
  }
}

/// Currently selected mood on the Home screen. null = no filter.
final moodProvider = StateProvider<WatchMood?>((ref) => null);
