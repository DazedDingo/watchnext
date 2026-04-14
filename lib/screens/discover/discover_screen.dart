import 'package:flutter/material.dart';

import '../../widgets/mode_toggle.dart';

/// Phase 7 will populate Discover with collections, trending, Reddit hype,
/// and browse-by-genre. Until then this is a placeholder with the mode
/// toggle exposed so the Solo/Together plumbing can be validated early.
class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: Center(child: ModeToggle()))],
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.explore_outlined, size: 56, color: Colors.white54),
            SizedBox(height: 12),
            Text(
              'Collections, trending, Reddit hype, and browse land in Phase 7.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ]),
        ),
      ),
    );
  }
}
