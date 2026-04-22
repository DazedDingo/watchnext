import 'package:flutter/material.dart';

/// Full-screen error surface for when a Firestore stream or callable blows
/// up and there's no useful partial UI to fall back to. Kept deliberately
/// chatty — we'd rather show a readable error than a white screen.
class AsyncErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;

  /// Compact variant — smaller icon + shorter message. Use inside
  /// constrained sections (horizontal rows, 160px strips, etc). The
  /// full-size version is for whole-screen fallbacks.
  final bool compact;

  /// Optional short headline, e.g. 'Search failed'. When null, we show
  /// the generic 'Something went wrong'.
  final String? title;

  const AsyncErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.compact = false,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 24.0 : 48.0;
    final padding = compact ? 12.0 : 24.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: iconSize, color: Colors.white38),
            SizedBox(height: compact ? 6 : 12),
            Text(
              title ?? 'Something went wrong',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: compact ? 13 : 15),
              textAlign: TextAlign.center,
            ),
            if (!compact) ...[
              const SizedBox(height: 6),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            if (onRetry != null) ...[
              SizedBox(height: compact ? 8 : 16),
              FilledButton.tonal(
                onPressed: onRetry,
                style: compact
                    ? FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(0, 28),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      )
                    : null,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
