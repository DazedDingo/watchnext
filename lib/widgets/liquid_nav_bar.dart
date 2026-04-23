import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One destination on the [LiquidNavBar].
class LiquidNavDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const LiquidNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// Premium-feeling replacement for Material 3's `NavigationBar`. Keeps the
/// same 56px icon-only footprint but swaps the flat M3 pill indicator for an
/// accent-gradient "liquid" blob that slides between tabs with a soft glow.
/// The icon swaps outlined → filled and scales slightly when selected.
class LiquidNavBar extends StatelessWidget {
  final int selectedIndex;
  final List<LiquidNavDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  /// Overall bar height excluding the device's bottom safe-area padding.
  /// Matches the retired NavigationBar's 56px to avoid shifting page layout.
  static const double height = 56.0;

  /// Blob indicator dimensions.
  static const double _indicatorWidth = 64.0;
  static const double _indicatorHeight = 34.0;

  const LiquidNavBar({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Material(
      color: Colors.transparent,
      child: Container(
        height: height + bottomPad,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              cs.surfaceContainerLow,
              cs.surface,
            ],
          ),
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.35),
              width: 0.5,
            ),
          ),
        ),
        padding: EdgeInsets.only(bottom: bottomPad),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / destinations.length;
            final indicatorLeft =
                selectedIndex * tabWidth + (tabWidth - _indicatorWidth) / 2;
            final indicatorTop = (height - _indicatorHeight) / 2;

            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  left: indicatorLeft,
                  top: indicatorTop,
                  width: _indicatorWidth,
                  height: _indicatorHeight,
                  child: _LiquidBlob(color: cs.primary),
                ),
                Row(
                  children: List.generate(destinations.length, (i) {
                    final selected = i == selectedIndex;
                    final d = destinations[i];
                    return Expanded(
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onDestinationSelected(i);
                        },
                        splashColor: cs.primary.withValues(alpha: 0.12),
                        highlightColor: cs.primary.withValues(alpha: 0.06),
                        child: SizedBox(
                          height: height,
                          child: Center(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(
                                scale: Tween<double>(begin: 0.85, end: 1.0)
                                    .animate(anim),
                                child: FadeTransition(
                                  opacity: anim,
                                  child: child,
                                ),
                              ),
                              child: Semantics(
                                key: ValueKey('${d.label}-$selected'),
                                label: d.label,
                                selected: selected,
                                button: true,
                                child: Icon(
                                  selected ? d.selectedIcon : d.icon,
                                  size: 24,
                                  color: selected
                                      ? cs.onPrimary
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Gradient pill with a two-layer soft glow. Kept as its own widget so the
/// indicator repaints independently of the tap targets.
class _LiquidBlob extends StatelessWidget {
  final Color color;
  const _LiquidBlob({required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.95),
            color.withValues(alpha: 0.72),
          ],
        ),
        borderRadius: BorderRadius.circular(LiquidNavBar._indicatorHeight / 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.45),
            blurRadius: 14,
            offset: const Offset(0, 3),
          ),
          BoxShadow(
            color: color.withValues(alpha: 0.22),
            blurRadius: 28,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}
