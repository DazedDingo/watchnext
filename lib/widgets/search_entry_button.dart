import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Full-width "tap to search" pill rendered on Home where the old `_SearchField`
/// TextField used to live. It is **not** an editable input — the local Home
/// search filter was a substring filter over the already-filtered rec list,
/// which couldn't surface titles that didn't survive the filter stack or
/// weren't in the rec pool to begin with. Tapping this pill pushes /discover,
/// where the search field autofocuses and queries `searchMulti` against the
/// full TMDB catalog.
///
/// Visually distinct from a TextField (centred icon + arrow_forward chevron)
/// so users don't tap-and-type expecting characters to appear in place.
class SearchEntryButton extends StatelessWidget {
  const SearchEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/discover'),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Search movies & TV',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ),
                Icon(Icons.arrow_forward,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
