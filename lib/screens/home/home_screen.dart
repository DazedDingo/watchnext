import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../shared/placeholder_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const PlaceholderScreen(
      title: 'Home',
      subtitle: "Tonight's Pick + mood recommendations live here.",
      futurePhase: 'Phase 7',
    );
  }
}
