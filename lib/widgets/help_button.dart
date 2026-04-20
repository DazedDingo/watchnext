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
        builder: (dialogCtx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              // Use the dialog's own context — the outer AppBar context's
              // nearest Navigator is the go_router shell, so popping that
              // tore the whole screen down instead of dismissing the dialog.
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      ),
    );
  }
}
