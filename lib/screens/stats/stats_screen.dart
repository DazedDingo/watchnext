import 'package:flutter/material.dart';
import '../shared/placeholder_screen.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Stats',
      subtitle: 'Watching habits, couple compatibility, Predict & Rate leaderboard.',
      futurePhase: 'Phase 9',
    );
  }
}
