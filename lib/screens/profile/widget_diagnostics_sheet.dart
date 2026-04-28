import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/home_widget_service.dart';

/// Modal sheet that surfaces the in-memory widget-bridge log buffer so the
/// user can copy + share recent breadcrumbs when a widget tap misroutes.
/// Buffer is in-memory only (HomeWidgetService); each entry is a
/// `(timestamp, message)` tuple with no user-identifying data.
class WidgetDiagnosticsSheet extends StatelessWidget {
  const WidgetDiagnosticsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const WidgetDiagnosticsSheet(),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = HomeWidgetService.recentLogs();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Widget bridge log',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Most recent widget-tap + refresh activity. Newest first.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: entries.isEmpty
                    ? const _EmptyPlaceholder()
                    : _LogList(entries: entries),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy all'),
                  onPressed: entries.isEmpty
                      ? null
                      : () => _copyAll(context, entries),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyAll(
    BuildContext context,
    List<({DateTime at, String message})> entries,
  ) async {
    final buffer = StringBuffer();
    for (final e in entries) {
      buffer.writeln('[${_formatTimestamp(e.at, withMillis: true)}] ${e.message}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied — share with Claude')),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No widget activity recorded yet. Tap a widget tile and reopen this sheet.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
        ),
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  final List<({DateTime at, String message})> entries;
  const _LogList({required this.entries});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final e = entries[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            '${_formatTimestamp(e.at)} · ${e.message}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        );
      },
    );
  }
}

String _formatTimestamp(DateTime t, {bool withMillis = false}) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  final base = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  return withMillis ? '$base.${three(t.millisecond)}' : base;
}
