import 'package:flutter/material.dart';

/// AppBar action that opens a dialog with per-screen instructions.
///
/// Drop into any `AppBar.actions` list so every screen has a consistent
/// `?` affordance explaining what the screen does and how to use it.
class HelpButton extends StatelessWidget {
  final String title;
  final String body;

  const HelpButton({super.key, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.help_outline),
      tooltip: 'How this works',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}
