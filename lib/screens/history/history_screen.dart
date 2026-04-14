import 'package:flutter/material.dart';
import '../shared/placeholder_screen.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'History',
      subtitle: 'Watched • In Progress • Unrated Queue',
      futurePhase: 'Phase 3',
    );
  }
}
