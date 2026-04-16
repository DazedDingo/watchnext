import 'package:flutter/material.dart';

/// Full-screen error surface for when a Firestore stream or callable blows
/// up and there's no useful partial UI to fall back to. Kept deliberately
/// chatty — we'd rather show a readable error than a white screen.
class AsyncErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;

  const AsyncErrorView({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white38),
            const SizedBox(height: 12),
            const Text('Something went wrong',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
