import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/concierge_turn.dart';
import '../../providers/concierge_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/mood_provider.dart';
import '../../services/tmdb_service.dart';

/// Represents one message in the local chat — either user or assistant.
class _ChatMessage {
  final bool isUser;
  final String text;
  final List<TitleSuggestion> titles;

  const _ChatMessage({
    required this.isUser,
    required this.text,
    this.titles = const [],
  });
}

/// Full-screen bottom sheet concierge chat.
///
/// Opens as a DraggableScrollableSheet so the user can half-open it
/// (quick question) or pull it fully up for a longer session.
class ConciergeSheet extends ConsumerStatefulWidget {
  const ConciergeSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const ConciergeSheet(),
      );

  @override
  ConsumerState<ConciergeSheet> createState() => _ConciergeSheetState();
}

class _ConciergeSheetState extends ConsumerState<ConciergeSheet> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  // Unique session ID for this sheet open.
  final String _sessionId =
      DateTime.now().millisecondsSinceEpoch.toString();

  final List<_ChatMessage> _messages = [];
  // Parallel history list for the CF (user/assistant pairs).
  final List<({String user, String assistant})> _history = [];

  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final householdId = ref.read(householdIdProvider).value;
    if (householdId == null) return;

    final mode = ref.read(viewModeProvider);
    final mood = ref.read(moodProvider);

    _controller.clear();
    setState(() {
      _messages.add(_ChatMessage(isUser: true, text: text));
      _sending = true;
    });
    _scrollToBottom();

    try {
      final result = await ref.read(conciergeServiceProvider).chat(
            householdId: householdId,
            message: text,
            sessionId: _sessionId,
            mode: mode == ViewMode.solo ? 'solo' : 'together',
            moodLabel: mood?.label,
            history: _history,
          );

      _history.add((user: text, assistant: result.text));

      setState(() {
        _messages.add(_ChatMessage(
          isUser: false,
          text: result.text,
          titles: result.titles,
        ));
        _sending = false;
      });
      _scrollToBottom();
    } catch (e) {
      // Surface the actual reason — "Something went wrong" alone gives us no
      // signal when the CF is broken (bad model id, missing secret, auth).
      // Firebase wraps CF HttpsError as FirebaseFunctionsException with a
      // structured code + message; everything else falls through to toString.
      final reason = switch (e) {
        FirebaseFunctionsException(:final code, :final message) =>
          '[$code] ${message ?? "AI call failed."}',
        _ => e.toString(),
      };
      setState(() {
        _messages.add(_ChatMessage(
          isUser: false,
          text: 'Sorry — $reason\nTry again?',
        ));
        _sending = false;
      });
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle + header.
            _SheetHeader(onClose: () => Navigator.of(context).pop()),

            // Chat messages.
            Expanded(
              child: _messages.isEmpty
                  ? _EmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) {
                        final msg = _messages[i];
                        return msg.isUser
                            ? _UserBubble(text: msg.text)
                            : _AssistantBubble(
                                text: msg.text,
                                titles: msg.titles,
                                onTitleTap: (t) {
                                  Navigator.of(context).pop();
                                  context.push(
                                      '/title/${t.mediaType}/${t.tmdbId}');
                                },
                              );
                      },
                    ),
            ),

            if (_sending)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Thinking…',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),

            // Input bar.
            Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 12 + bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Ask for a recommendation…',
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      minLines: 1,
                      maxLines: 3,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                    tooltip: 'Send',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sheet header
// ---------------------------------------------------------------------------

class _SheetHeader extends StatelessWidget {
  final VoidCallback onClose;
  const _SheetHeader({required this.onClose});

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
          const Icon(Icons.auto_awesome, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Ask AI',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
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

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 48, color: Colors.white24),
          const SizedBox(height: 12),
          Text(
            'Ask me anything about what to watch.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '"Something short and funny"\n"A thriller we haven\'t seen"',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat bubbles
// ---------------------------------------------------------------------------

class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 8, left: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontSize: 14)),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  final String text;
  final List<TitleSuggestion> titles;
  final void Function(TitleSuggestion) onTitleTap;

  const _AssistantBubble({
    required this.text,
    required this.titles,
    required this.onTitleTap,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 8, right: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: SelectableText(text, style: const TextStyle(fontSize: 14)),
            ),
            if (titles.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 180,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: titles.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: 10),
                  itemBuilder: (_, i) => _TitleCard(
                    suggestion: titles[i],
                    onTap: () => onTitleTap(titles[i]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Title card
// ---------------------------------------------------------------------------

class _TitleCard extends StatelessWidget {
  final TitleSuggestion suggestion;
  final VoidCallback onTap;

  const _TitleCard({required this.suggestion, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _PosterImage(
                    mediaType: suggestion.mediaType,
                    tmdbId: suggestion.tmdbId,
                    posterPath: suggestion.posterPath),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              suggestion.year != null
                  ? '${suggestion.title} (${suggestion.year})'
                  : suggestion.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600),
            ),
            Text(
              suggestion.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a poster. If [posterPath] was resolved during the concierge's
/// verification pass we render directly; otherwise we fall back to fetching
/// details for [tmdbId].
class _PosterImage extends StatefulWidget {
  final String mediaType;
  final int tmdbId;
  final String? posterPath;

  const _PosterImage({
    required this.mediaType,
    required this.tmdbId,
    this.posterPath,
  });

  @override
  State<_PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends State<_PosterImage> {
  TmdbService? _tmdb;
  String? _posterUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.posterPath != null) {
      _posterUrl = TmdbService.imageUrl(widget.posterPath, size: 'w342');
      _loading = false;
    } else {
      _tmdb = TmdbService();
      _loadPoster();
    }
  }

  @override
  void dispose() {
    _tmdb?.dispose();
    super.dispose();
  }

  Future<void> _loadPoster() async {
    try {
      final data = widget.mediaType == 'tv'
          ? await _tmdb!.tvDetails(widget.tmdbId)
          : await _tmdb!.movieDetails(widget.tmdbId);
      final path = data['poster_path'] as String?;
      if (mounted && path != null) {
        setState(() {
          _posterUrl = TmdbService.imageUrl(path, size: 'w342');
          _loading = false;
        });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: Colors.white10,
        child: const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 1.5))),
      );
    }
    if (_posterUrl == null) {
      return Container(
        color: Colors.white10,
        child: const Icon(Icons.movie_outlined,
            color: Colors.white30, size: 32),
      );
    }
    return Image.network(
      _posterUrl!,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: Colors.white10,
        child: const Icon(Icons.broken_image_outlined,
            color: Colors.white30, size: 32),
      ),
    );
  }
}
