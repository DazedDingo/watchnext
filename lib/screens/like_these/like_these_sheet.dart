import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/concierge_turn.dart';
import '../../providers/concierge_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/include_watched_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/tmdb_provider.dart';
import '../../providers/watch_entries_provider.dart';
import '../../services/tmdb_service.dart';

/// "More like these" — the user picks a small list of seed titles and the
/// concierge returns suggestions that match the *group* as a whole. Reuses
/// the existing `concierge` CF (no new endpoint needed); we just build a
/// specific prompt and treat the response identically to a chat turn.
class LikeTheseSheet extends ConsumerStatefulWidget {
  const LikeTheseSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const LikeTheseSheet(),
      );

  @override
  ConsumerState<LikeTheseSheet> createState() => _LikeTheseSheetState();
}

class _Seed {
  final String mediaType;
  final int tmdbId;
  final String title;
  final int? year;
  final String? posterPath;

  const _Seed({
    required this.mediaType,
    required this.tmdbId,
    required this.title,
    this.year,
    this.posterPath,
  });

  String get promptLabel => year != null ? '$title ($year)' : title;
  String get key => '$mediaType:$tmdbId';
}

class _LikeTheseSheetState extends ConsumerState<LikeTheseSheet> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Debounces typing → TMDB search so we don't fire on every keystroke.
  Timer? _searchDebounce;
  String _query = '';

  // Latest search results. Loaded async; empty when _query is empty.
  List<Map<String, dynamic>> _searchResults = const [];
  bool _searching = false;

  // User-picked seeds (up to 8 to keep the prompt tight).
  final List<_Seed> _seeds = [];
  static const _maxSeeds = 8;

  // Submission state.
  bool _submitting = false;
  String? _resultText;
  List<TitleSuggestion> _resultTitles = const [];
  String? _error;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String v) {
    _searchDebounce?.cancel();
    setState(() => _query = v);
    if (v.trim().isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _query.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final res = await ref.read(tmdbServiceProvider).searchMulti(q);
      final rows = (res['results'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          // TMDB returns movies, TV, and people. We only want titles.
          .where((r) =>
              r['media_type'] == 'movie' || r['media_type'] == 'tv')
          .take(20)
          .toList();
      if (mounted) setState(() => _searchResults = rows);
    } catch (_) {
      if (mounted) setState(() => _searchResults = const []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _addSeed(Map<String, dynamic> row) {
    if (_seeds.length >= _maxSeeds) return;
    final id = (row['id'] as num?)?.toInt();
    final rawType = row['media_type'] as String?;
    if (id == null || (rawType != 'movie' && rawType != 'tv')) return;
    // Re-bind with a `!` — the guard above already ruled out null, but
    // Dart's flow analysis doesn't narrow `String?` through equality.
    final String mediaType = rawType!;
    final key = '$mediaType:$id';
    if (_seeds.any((s) => s.key == key)) return;
    final date = (row['release_date'] ?? row['first_air_date']) as String?;
    final year = (date != null && date.length >= 4)
        ? int.tryParse(date.substring(0, 4))
        : null;
    setState(() {
      _seeds.add(_Seed(
        mediaType: mediaType,
        tmdbId: id,
        title: (row['title'] ?? row['name']) as String? ?? 'Untitled',
        year: year,
        posterPath: row['poster_path'] as String?,
      ));
    });
  }

  void _removeSeed(_Seed s) {
    setState(() => _seeds.removeWhere((x) => x.key == s.key));
  }

  Future<void> _submit() async {
    if (_seeds.length < 2 || _submitting) return;
    final householdId = ref.read(householdIdProvider).value;
    if (householdId == null) return;
    final mode = ref.read(viewModeProvider);

    setState(() {
      _submitting = true;
      _error = null;
    });

    final list = _seeds.map((s) => s.promptLabel).join(', ');
    // Intentionally explicit: "like the group as a whole" avoids a
    // weighted-average feel where Claude just leans on the most recent seed.
    final prompt =
        'Suggest 6 titles (movies or TV shows) that capture what someone who '
        "loves this group as a whole — not each title individually — would "
        'enjoy next. Seeds: $list. '
        "Don't include the seeds themselves or things they've already watched.";

    try {
      final result = await ref.read(conciergeServiceProvider).chat(
            householdId: householdId,
            message: prompt,
            // Fresh session — this is a one-shot, not a chat follow-up.
            sessionId: 'like-these-${DateTime.now().millisecondsSinceEpoch}',
            mode: mode == ViewMode.solo ? 'solo' : 'together',
            history: const [],
          );
      if (!mounted) return;
      final includeWatched = ref.read(includeWatchedProvider);
      final watchedKeys = ref.read(watchedKeysProvider);
      final titles = includeWatched
          ? result.titles
          : result.titles
              .where((t) =>
                  !watchedKeys.contains('${t.mediaType}:${t.tmdbId}'))
              .toList();
      setState(() {
        _resultText = result.text;
        _resultTitles = titles;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      final reason = switch (e) {
        FirebaseFunctionsException(:final code, :final message) =>
          '[$code] ${message ?? "AI call failed."}',
        _ => e.toString(),
      };
      setState(() {
        _error = reason;
        _submitting = false;
      });
    }
  }

  void _reset() {
    setState(() {
      _resultText = null;
      _resultTitles = const [];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _SheetHeader(
              onClose: () => Navigator.of(context).pop(),
              onReset: _resultText != null || _error != null ? _reset : null,
            ),
            if (_resultText != null || _error != null)
              Expanded(child: _buildResults(scrollController))
            else
              Expanded(child: _buildPicker(scrollController)),
            if (_resultText == null && _error == null)
              Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 12 + bottom),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_awesome),
                    label: Text(_submitting
                        ? 'Finding titles…'
                        : 'Find titles like these (${_seeds.length})'),
                    onPressed:
                        _seeds.length >= 2 && !_submitting ? _submit : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPicker(ScrollController sheetScroll) {
    return ListView(
      controller: sheetScroll,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        const SizedBox(height: 4),
        Text(
          'Pick 2–$_maxSeeds titles. We\'ll suggest things a fan of '
          'this group would enjoy — not the seeds themselves.',
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _searchCtrl,
          onChanged: _onQueryChanged,
          decoration: InputDecoration(
            hintText: 'Search movies and TV…',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      _onQueryChanged('');
                    },
                  ),
            filled: true,
            fillColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        if (_seeds.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Picked',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in _seeds)
                InputChip(
                  label: Text(s.promptLabel),
                  onDeleted: () => _removeSeed(s),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        if (_searching)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (_query.isEmpty)
          const _PickerEmptyState()
        else if (_searchResults.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matches.',
                style: TextStyle(color: Colors.white54)),
          )
        else
          for (final row in _searchResults)
            _SearchResultRow(
              row: row,
              alreadyPicked: _seeds.any((s) =>
                  s.key == '${row['media_type']}:${row['id']}'),
              onTap: () => _addSeed(row),
            ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildResults(ScrollController sheetScroll) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            // SelectableText so the user can long-press to copy the full error
            // text for bug reports.
            SelectableText('Sorry — $_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _reset, child: const Text('Try again')),
          ],
        ),
      );
    }

    return ListView(
      controller: sheetScroll,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if ((_resultText ?? '').isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SelectableText(
              _resultText!,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          const Divider(height: 16),
        ],
        for (final t in _resultTitles)
          _ResultTile(
            suggestion: t,
            onTap: () {
              Navigator.of(context).pop();
              context.push('/title/${t.mediaType}/${t.tmdbId}');
            },
          ),
        if (_resultTitles.isEmpty && (_resultText ?? '').isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'No title cards came back — try adding more seeds or rewording.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ─── Sheet header ────────────────────────────────────────────────────────────

class _SheetHeader extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback? onReset;
  const _SheetHeader({required this.onClose, this.onReset});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Icon(Icons.group_work_outlined, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'More like these',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
          ),
          if (onReset != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'New search',
              onPressed: onReset,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ─────────────────────────────────────────────────────────────

class _PickerEmptyState extends StatelessWidget {
  const _PickerEmptyState();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.manage_search_outlined, size: 40, color: Colors.white24),
          SizedBox(height: 8),
          Text('Search to add titles.',
              style: TextStyle(color: Colors.white54)),
          SizedBox(height: 2),
          Text('e.g. "Arrival" + "Ex Machina" → cerebral sci-fi',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}

// ─── Search result row ───────────────────────────────────────────────────────

class _SearchResultRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool alreadyPicked;
  final VoidCallback onTap;

  const _SearchResultRow({
    required this.row,
    required this.alreadyPicked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final poster =
        TmdbService.imageUrl(row['poster_path'] as String?, size: 'w185');
    final title = (row['title'] ?? row['name']) as String? ?? 'Untitled';
    final date = (row['release_date'] ?? row['first_air_date']) as String?;
    final year = (date != null && date.length >= 4)
        ? date.substring(0, 4)
        : null;
    final mediaType = row['media_type'] as String? ?? 'movie';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: poster != null
            ? Image.network(poster,
                width: 40,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                      width: 40,
                      height: 60,
                      color: Colors.white10,
                      child: const Icon(Icons.movie_outlined,
                          color: Colors.white30, size: 20),
                    ))
            : Container(
                width: 40,
                height: 60,
                color: Colors.white10,
                child: const Icon(Icons.movie_outlined,
                    color: Colors.white30, size: 20)),
      ),
      title: Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        [
          ?year,
          mediaType == 'tv' ? 'TV' : 'Movie',
        ].join(' · '),
        style: const TextStyle(fontSize: 12, color: Colors.white54),
      ),
      trailing: alreadyPicked
          ? const Icon(Icons.check_circle, color: Colors.greenAccent)
          : const Icon(Icons.add_circle_outline),
      onTap: alreadyPicked ? null : onTap,
    );
  }
}

// ─── Result tile ─────────────────────────────────────────────────────────────

class _ResultTile extends StatefulWidget {
  final TitleSuggestion suggestion;
  final VoidCallback onTap;

  const _ResultTile({required this.suggestion, required this.onTap});

  @override
  State<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends State<_ResultTile> {
  final _tmdb = TmdbService();
  String? _posterUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPoster();
  }

  @override
  void dispose() {
    _tmdb.dispose();
    super.dispose();
  }

  Future<void> _loadPoster() async {
    try {
      final data = widget.suggestion.mediaType == 'tv'
          ? await _tmdb.tvDetails(widget.suggestion.tmdbId)
          : await _tmdb.movieDetails(widget.suggestion.tmdbId);
      if (!mounted) return;
      setState(() {
        _posterUrl = TmdbService.imageUrl(data['poster_path'] as String?,
            size: 'w185');
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: _loading
            ? Container(
                width: 40,
                height: 60,
                color: Colors.white10,
                child: const Center(
                    child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5))))
            : _posterUrl != null
                ? Image.network(_posterUrl!,
                    width: 40,
                    height: 60,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                          width: 40,
                          height: 60,
                          color: Colors.white10,
                          child: const Icon(Icons.movie_outlined,
                              color: Colors.white30, size: 18),
                        ))
                : Container(
                    width: 40,
                    height: 60,
                    color: Colors.white10,
                    child: const Icon(Icons.movie_outlined,
                        color: Colors.white30, size: 18)),
      ),
      title: Text(
        widget.suggestion.year != null
            ? '${widget.suggestion.title} (${widget.suggestion.year})'
            : widget.suggestion.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        widget.suggestion.reason,
        style: const TextStyle(fontSize: 12, color: Colors.white54),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: widget.onTap,
    );
  }
}
