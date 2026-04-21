import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/watchnext_logo.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(authStateProvider, (_, next) {
      next.whenData((user) {
        if (user != null && context.mounted) {
          _redirectAfterAuth(context, user.uid);
        }
      });
    });

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Bright crimson stage glow fading to deep theater black.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.35),
                radius: 1.3,
                colors: [
                  Color(0xFFB02030), // bright crimson stage glow
                  Color(0xFF6A0F18), // mid burgundy
                  Color(0xFF200508), // deep theater black-red
                  Color(0xFF050506), // far-edge black
                ],
                stops: [0.0, 0.35, 0.75, 1.0],
              ),
            ),
          ),
          // Vertical curtain-fold streaks on the sides.
          const IgnorePointer(
            child: _CurtainFolds(),
          ),
          // Film-strip frames at top and bottom to frame the "screen".
          // Padded in from the edge so the reel reads as a distinct border
          // rather than blending into the status/nav bar chrome.
          const Positioned(
              top: 24, left: 0, right: 0, child: _FilmStrip()),
          const Positioned(
              bottom: 24, left: 0, right: 0, child: _FilmStrip()),
          // Light scrim — keeps text legible without crushing the gradient.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.10),
                  Colors.black.withValues(alpha: 0.40),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: WatchNextLogo(
                          fontSize: 44, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Decide what to watch. Together.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white.withValues(alpha: 0.78),
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 56),
                    FilledButton.icon(
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in with Google'),
                      onPressed: () async {
                        try {
                          final cred = await ref.read(authServiceProvider).signInWithGoogle();
                          if (context.mounted && cred.user != null) {
                            await _redirectAfterAuth(context, cred.user!.uid);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            _showErrorDialog(context, e.toString());
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign-in failed'),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _redirectAfterAuth(BuildContext context, String uid) async {
    final userDoc = await FirebaseFirestore.instance.doc('users/$uid').get();
    final householdId = userDoc.data()?['householdId'] as String?;
    if (!context.mounted) return;
    if (householdId != null && householdId.isNotEmpty) {
      context.go('/home');
    } else {
      context.go('/setup');
    }
  }
}

class _CurtainFolds extends StatelessWidget {
  const _CurtainFolds();

  @override
  Widget build(BuildContext context) {
    // Left and right curtain gradients — dark burgundy folds fading inward.
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color(0xFF6A1018).withValues(alpha: 0.95),
                  const Color(0xFF3A0810).withValues(alpha: 0.55),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        const Expanded(flex: 3, child: SizedBox.shrink()),
        Expanded(
          flex: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                colors: [
                  const Color(0xFF6A1018).withValues(alpha: 0.95),
                  const Color(0xFF3A0810).withValues(alpha: 0.55),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FilmStrip extends StatelessWidget {
  const _FilmStrip();

  @override
  Widget build(BuildContext context) {
    // Chunky film-reel border with a proper sprocket row. Taller + higher
    // contrast so it reads as a real film strip, not decorative trim.
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border.symmetric(
          horizontal: BorderSide(color: Color(0xFF2A2A2A), width: 1.5),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          const holeWidth = 22.0;
          const gap = 14.0;
          final count = (c.maxWidth / (holeWidth + gap)).floor().clamp(1, 999);
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(count, (_) {
              return Container(
                width: holeWidth,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0A),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: const Color(0xFF1F1F1F),
                    width: 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
