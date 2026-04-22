import 'package:flutter/material.dart';

/// Shared empty-state surface for screens/sections that legitimately have
/// no data to show. Kept deliberately modest — centered icon, short
/// headline, optional body line, optional single action button.
///
/// Use instead of `SizedBox.shrink()` anywhere the user would benefit
/// from knowing WHY nothing is rendering (empty queue, no search hits,
/// feature not yet applicable, etc).
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Compact variant: smaller icon, tighter padding. Use inside list
  /// sections / tabs rather than a full screen.
  final bool compact;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 32.0 : 48.0;
    final padding = compact ? 16.0 : 24.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: Colors.white38),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
