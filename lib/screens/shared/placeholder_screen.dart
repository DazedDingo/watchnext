import 'package:flutter/material.dart';

class PlaceholderScreen extends StatelessWidget {
  final String title;
  final String subtitle;
  final String futurePhase;
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.futurePhase,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.construction, size: 48, color: Colors.white.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text(subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 8),
              Text(
                'Built in $futurePhase.',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
