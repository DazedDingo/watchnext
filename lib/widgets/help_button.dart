import 'package:flutter/material.dart';

/// AppBar action that opens a dialog with per-screen instructions.
///
/// Drop into any `AppBar.actions` list so every screen has a consistent
/// `?` affordance explaining what the screen does and how to use it.
///
/// Body strings follow a simple shape: an intro paragraph, a blank line,
/// `•`-prefixed bullets (each `label — body`), another blank line, and an
/// optional outro paragraph. The dialog renders each shape distinctly so
/// the wall of text reads more like documentation than a prose dump.
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
        // Use the dialog's own context — the outer AppBar context's nearest
        // Navigator is the go_router shell, so popping that tore the whole
        // screen down instead of dismissing the dialog.
        builder: (dialogCtx) => _HelpDialog(title: title, body: body),
      ),
    );
  }
}

class _HelpDialog extends StatelessWidget {
  final String title;
  final String body;

  const _HelpDialog({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = _parseSections(body);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(title: title),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                itemCount: sections.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => switch (sections[i]) {
                  _Paragraph(text: final t) => _HelpParagraph(text: t),
                  _Bullet(label: final l, body: final b) =>
                    _HelpBullet(label: l, body: b),
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: theme.colorScheme.onPrimaryContainer,
                    backgroundColor: theme.colorScheme.primaryContainer,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Got it'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline,
              color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: Icon(Icons.close,
                color: theme.colorScheme.onPrimaryContainer),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _HelpParagraph extends StatelessWidget {
  final String text;
  const _HelpParagraph({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        height: 1.4,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
      ),
    );
  }
}

class _HelpBullet extends StatelessWidget {
  final String label;
  final String body;
  const _HelpBullet({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 7, right: 10),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.4,
                color: onSurface.withValues(alpha: 0.88),
              ),
              children: [
                if (label.isNotEmpty)
                  TextSpan(
                    text: label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: onSurface,
                    ),
                  ),
                if (label.isNotEmpty && body.isNotEmpty)
                  const TextSpan(text: '  '),
                if (body.isNotEmpty) TextSpan(text: body),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

sealed class _Section {}

class _Paragraph extends _Section {
  final String text;
  _Paragraph(this.text);
}

class _Bullet extends _Section {
  final String label;
  final String body;
  _Bullet({required this.label, required this.body});
}

/// Parses a help body into a mix of paragraphs and bullets. A bullet line
/// starts with `•`; continuation lines (no bullet prefix) fold into the most
/// recent bullet or paragraph. Blank lines terminate whichever section was
/// being built. Bullet `label — body` split falls back to empty-label + body
/// when no em-dash is present.
List<_Section> _parseSections(String body) {
  final lines = body.split('\n');
  final out = <_Section>[];
  _Bullet? currentBullet;
  final paragraph = StringBuffer();

  void flushBullet() {
    if (currentBullet != null) {
      out.add(currentBullet!);
      currentBullet = null;
    }
  }

  void flushParagraph() {
    final t = paragraph.toString().trim();
    if (t.isNotEmpty) out.add(_Paragraph(t));
    paragraph.clear();
  }

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) {
      flushBullet();
      flushParagraph();
      continue;
    }
    if (line.startsWith('•')) {
      flushBullet();
      flushParagraph();
      final content = line.substring(1).trim();
      final dashIdx = content.indexOf('—');
      if (dashIdx > 0) {
        currentBullet = _Bullet(
          label: content.substring(0, dashIdx).trim(),
          body: content.substring(dashIdx + 1).trim(),
        );
      } else {
        currentBullet = _Bullet(label: '', body: content);
      }
    } else if (currentBullet != null) {
      currentBullet = _Bullet(
        label: currentBullet!.label,
        body: '${currentBullet!.body} $line',
      );
    } else {
      if (paragraph.isNotEmpty) paragraph.write(' ');
      paragraph.write(line);
    }
  }
  flushBullet();
  flushParagraph();
  return out;
}
