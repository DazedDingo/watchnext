import 'package:flutter/material.dart';
import '../shared/placeholder_screen.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Discover',
      subtitle: 'Curated collections, trending, Reddit hype, browse.',
      futurePhase: 'Phase 7',
    );
  }
}
