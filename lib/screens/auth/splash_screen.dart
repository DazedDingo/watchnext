import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/watchnext_logo.dart';

/// Cinema-curtain splash shown once on app open.
///
/// Plays a short "curtains rising" animation — two burgundy velvet panels
/// slide outward from the center to reveal the WatchNext logo, then the
/// screen fades through to `/login` (which the router redirects onward
/// to `/home` or `/setup` depending on auth state).
///
/// Tap anywhere to skip.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curtain;
  late final Animation<double> _logo;
  late final Animation<double> _fade;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    // Curtains open during the first 65% of the animation.
    _curtain = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.10, 0.75, curve: Curves.easeInOutCubic),
    );
    // Logo fades in just after curtains start parting.
    _logo = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.25, 0.60, curve: Curves.easeOut),
    );
    // Final fade to black before navigation so the handoff is clean.
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
    );

    _controller.forward().whenComplete(_goNext);
  }

  void _goNext() {
    if (_navigated || !mounted) return;
    _navigated = true;
    context.go('/login');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050506),
      body: GestureDetector(
        onTap: _goNext,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Stack(
              fit: StackFit.expand,
              children: [
                // Stage — the "screen" behind the curtains. Soft crimson
                // spotlight fading to theater black, same palette as login
                // so the transition is visually continuous.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0, -0.1),
                      radius: 1.1,
                      colors: [
                        Color(0xFF7A1520),
                        Color(0xFF3A0810),
                        Color(0xFF050506),
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
                // Logo — revealed as the curtains part.
                Center(
                  child: Opacity(
                    opacity: _logo.value,
                    child: Transform.scale(
                      scale: 0.92 + 0.08 * _logo.value,
                      child: const _LogoLockup(),
                    ),
                  ),
                ),
                // Left curtain — slides off to the left.
                // Offset is passed positive; the `isLeft` branch inside
                // _CurtainPanel negates it so the panel slides in the right
                // direction. Passing `-_curtain.value` here double-negated and
                // pushed the left panel RIGHT (stuck on-screen) instead of off.
                _CurtainPanel(
                  alignment: Alignment.centerLeft,
                  offset: _curtain.value,
                ),
                // Right curtain — slides off to the right.
                _CurtainPanel(
                  alignment: Alignment.centerRight,
                  offset: _curtain.value,
                ),
                // Final fade-to-black before navigation.
                IgnorePointer(
                  child: Opacity(
                    opacity: _fade.value * 0.6,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LogoLockup extends StatelessWidget {
  const _LogoLockup();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        WatchNextLogo(fontSize: 52, fontWeight: FontWeight.w800),
        SizedBox(height: 8),
        Text(
          'by DazedDingo',
          style: TextStyle(
            fontSize: 13,
            letterSpacing: 1.2,
            fontStyle: FontStyle.italic,
            color: Colors.white70,
            shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
          ),
        ),
      ],
    );
  }
}

/// One half of the theater curtain. [offset] ranges 0..1 where 1 means the
/// panel has slid fully offscreen in its [alignment] direction.
class _CurtainPanel extends StatelessWidget {
  final Alignment alignment;
  final double offset;

  const _CurtainPanel({required this.alignment, required this.offset});

  @override
  Widget build(BuildContext context) {
    final isLeft = alignment == Alignment.centerLeft;
    return FractionallySizedBox(
      widthFactor: 0.5,
      alignment: alignment,
      child: Transform.translate(
        offset: Offset(
          isLeft ? -offset * MediaQuery.of(context).size.width * 0.5 : offset * MediaQuery.of(context).size.width * 0.5,
          0,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Base velvet
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF4A0810),
                    Color(0xFF6A1018),
                    Color(0xFF3A0610),
                  ],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
            // Vertical folds — alternating light/dark stripes.
            IgnorePointer(
              child: CustomPaint(
                painter: _CurtainFoldsPainter(isLeft: isLeft),
              ),
            ),
            // Soft inner edge shadow so the reveal reads clearly.
            Align(
              alignment:
                  isLeft ? Alignment.centerRight : Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: 0.15,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: isLeft
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      end: isLeft
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurtainFoldsPainter extends CustomPainter {
  final bool isLeft;
  _CurtainFoldsPainter({required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    const foldCount = 7;
    final foldWidth = size.width / foldCount;
    for (int i = 0; i < foldCount; i++) {
      // Dark crease
      final creaseRect = Rect.fromLTWH(
        i * foldWidth,
        0,
        foldWidth * 0.25,
        size.height,
      );
      canvas.drawRect(
        creaseRect,
        Paint()..color = Colors.black.withValues(alpha: 0.25),
      );
      // Highlight on opposite side
      final hlRect = Rect.fromLTWH(
        i * foldWidth + foldWidth * 0.55,
        0,
        foldWidth * 0.12,
        size.height,
      );
      canvas.drawRect(
        hlRect,
        Paint()..color = Colors.white.withValues(alpha: 0.06),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CurtainFoldsPainter oldDelegate) =>
      oldDelegate.isLeft != isLeft;
}
