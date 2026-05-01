import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/app_icon_provider.dart';
import '../../providers/ask_ai_placement_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/trakt_provider.dart';
import '../../providers/up_next_style_provider.dart';
import '../../providers/upnext_provider.dart';
import '../../services/app_icon_service.dart';
import '../../widgets/help_button.dart';
import 'widget_diagnostics_sheet.dart';

const _profileHelp =
    'Account, household invite, preferences, and integrations all live here.\n\n'
    '• Invite partner — share the code so they can join your household.\n'
    '• Default mode — Solo ranks recommendations for you alone; Together ranks for both.\n'
    '• Reveal notifications — optional push when a prediction reveal is ready.\n'
    '• Ask AI placement — show the concierge entry as an app-bar icon (default), a floating action button, or hide it completely.\n'
    '• Up next style — pick how the Home "Up Next" row presents itself: an auto-cycling marquee (default) or a static horizontal strip.\n'
    '• App icon — pick which launcher icon represents WatchNext on your home screen. Classic (the original), Vivid (high-contrast film reel), Minimal (clean play button), or Clapperboard.\n'
    '• Trakt — link to auto-import history and push ratings.\n'
    '• Stremio addon — mints a private URL you paste into Stremio; your shared watchlist then appears as a catalog inside the Stremio app.\n'
    '• Sign out — clears your session on this device. Your data stays in the household.';

/// Reads the current app version once and caches it. Kept as a Provider so
/// every screen that wants the version string gets the same cached read.
final _appVersionProvider = FutureProvider<String>((_) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
});

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;
    final inviteCodeAsync = ref.watch(householdInviteCodeProvider);
    final traktAsync = ref.watch(traktLinkStatusProvider);
    final mode = ref.watch(viewModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: const [HelpButton(title: 'Profile', body: _profileHelp)],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundImage: user?.photoURL != null
                  ? NetworkImage(user!.photoURL!)
                  : null,
              child: user?.photoURL == null
                  ? const Icon(Icons.person)
                  : null,
            ),
            title: Text(user?.displayName ?? 'Member'),
            subtitle: Text(user?.email ?? ''),
          ),
          const Divider(),

          // ── Household ──────────────────────────────────────────────────
          const _SectionHeader('Household'),
          inviteCodeAsync.when(
            data: (code) => code == null
                ? const ListTile(title: Text('No household yet'))
                : ListTile(
                    leading: const Icon(Icons.group_add),
                    title: const Text('Invite partner'),
                    subtitle: Text(code,
                        style: const TextStyle(fontFamily: 'monospace')),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Invite code copied')),
                        );
                      },
                    ),
                  ),
            loading: () => const ListTile(title: Text('Loading…')),
            error: (e, _) => ListTile(
              leading:
                  const Icon(Icons.error_outline, color: Colors.redAccent),
              title: const Text('Couldn\'t load invite code'),
              subtitle: Text('$e',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white38)),
            ),
          ),
          const Divider(),

          // ── Preferences ────────────────────────────────────────────────
          const _SectionHeader('Preferences'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.people_outline),
            title: const Text('Default mode'),
            trailing: SegmentedButton<ViewMode>(
              selected: {mode},
              segments: const [
                ButtonSegment(value: ViewMode.solo, label: Text('Solo')),
                ButtonSegment(
                    value: ViewMode.together, label: Text('Together')),
              ],
              onSelectionChanged: (s) =>
                  ref.read(viewModeProvider.notifier).set(s.first),
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact),
            ),
          ),
          const _NotificationToggle(),
          const _AccentPicker(),
          const _AskAiPlacementTile(),
          const _UpNextStyleTile(),
          const _AppIconTile(),
          const Divider(),

          // ── Stats ──────────────────────────────────────────────────────
          const _SectionHeader('Insights'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.bar_chart_outlined),
            title: const Text('Stats'),
            subtitle: const Text('Watch habits, badges, predictions'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/profile/stats'),
          ),
          const _UpNextHealthTile(),
          const Divider(),

          // ── Trakt ──────────────────────────────────────────────────────
          const _SectionHeader('Trakt'),
          traktAsync.when(
            data: (s) => ListTile(
              dense: true,
              leading: Icon(s.linked ? Icons.link : Icons.link_off),
              title:
                  Text(s.linked ? 'Trakt linked' : 'Link Trakt account'),
              subtitle: s.linked && s.lastSync != null
                  ? Text('Synced ${DateFormat.MMMd().add_jm().format(s.lastSync!.toLocal())}')
                  : const Text('Import history, sync ratings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile/trakt'),
            ),
            loading: () => const ListTile(title: Text('Loading…')),
            error: (e, _) => ListTile(
              leading:
                  const Icon(Icons.error_outline, color: Colors.redAccent),
              title: const Text('Couldn\'t read Trakt status'),
              subtitle: Text('$e',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.white38)),
            ),
          ),
          const Divider(),

          // ── Stremio ───────────────────────────────────────────────────
          const _SectionHeader('Stremio'),
          const _StremioSection(),
          const Divider(),

          // ── Diagnostics ───────────────────────────────────────────────
          const _SectionHeader('Diagnostics'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Widget bridge log'),
            subtitle: const Text('Recent widget-tap activity for debugging'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => WidgetDiagnosticsSheet.show(context),
          ),
          const Divider(),

          // ── Help ──────────────────────────────────────────────────────
          const _SectionHeader('Feedback'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Report an issue'),
            subtitle: const Text('Bug or idea → filed on GitHub'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/profile/report-issue'),
          ),
          const Divider(),

          // ── Sign out ───────────────────────────────────────────────────
          ListTile(
            dense: true,
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await ref.read(authServiceProvider).signOut();
              if (context.mounted) context.go('/login');
            },
          ),
          const Divider(),
          const _AboutFooter(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About footer — app version + signature
// ---------------------------------------------------------------------------

class _AboutFooter extends ConsumerWidget {
  const _AboutFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(_appVersionProvider).value ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'WatchNext${version.isEmpty ? '' : ' v$version'}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 2),
          const Text(
            'by DazedDingo',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notification toggle
// ---------------------------------------------------------------------------

class _NotificationToggle extends StatefulWidget {
  const _NotificationToggle();

  @override
  State<_NotificationToggle> createState() => _NotificationToggleState();
}

class _NotificationToggleState extends State<_NotificationToggle> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings =
        await FirebaseMessaging.instance.getNotificationSettings();
    if (mounted) {
      setState(() {
        _enabled = settings.authorizationStatus ==
            AuthorizationStatus.authorized;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return SwitchListTile(
      dense: true,
      secondary: const Icon(Icons.notifications_outlined),
      title: const Text('Reveal notifications'),
      subtitle: const Text('When a reveal is ready'),
      value: _enabled,
      onChanged: (_) {
        if (_enabled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Disable notifications in Settings > Apps > WatchNext.'),
            ),
          );
        } else {
          FirebaseMessaging.instance
              .requestPermission(alert: true, sound: true)
              .then((s) {
            if (mounted) {
              setState(() => _enabled =
                  s.authorizationStatus == AuthorizationStatus.authorized);
            }
          });
        }
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Stremio addon section
// ---------------------------------------------------------------------------

class _StremioSection extends StatefulWidget {
  const _StremioSection();

  @override
  State<_StremioSection> createState() => _StremioSectionState();
}

class _StremioSectionState extends State<_StremioSection> {
  String? _installUrl;
  bool _busy = false;
  String? _error;

  FirebaseFunctions get _fns =>
      FirebaseFunctions.instanceFor(region: 'europe-west2');

  Future<void> _provision() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final res = await _fns.httpsCallable('provisionStremioToken').call();
      final data = Map<String, dynamic>.from(res.data as Map);
      setState(() => _installUrl = data['installUrl'] as String?);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = '[${e.code}] ${e.message ?? "provision failed"}');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _fns.httpsCallable('revokeStremioToken').call();
      setState(() => _installUrl = null);
    } on FirebaseFunctionsException catch (e) {
      setState(() => _error = '[${e.code}] ${e.message ?? "revoke failed"}');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openInStremio() async {
    final url = _installUrl;
    if (url == null) return;
    // Stremio recognises stremio:// URLs pointing at an addon manifest and
    // prompts to install. Swap the scheme on the public URL.
    final deep = Uri.parse(url.replaceFirst('https://', 'stremio://'));
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (await canLaunchUrl(deep)) {
        await launchUrl(deep, mode: LaunchMode.externalApplication);
      } else {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Stremio app not found. Copy the URL and paste it into Stremio → Addons.',
            ),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Open in Stremio failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_installUrl == null) {
      return Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Stremio addon'),
            subtitle: const Text('Watchlist as a Stremio catalog'),
            trailing: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonal(
                    onPressed: _provision,
                    child: const Text('Generate URL'),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
        ],
      );
    }
    final url = _installUrl!;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('Install URL'),
          subtitle: SelectableText(
            url,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            maxLines: 3,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy URL',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Install URL copied')),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Install in Stremio'),
                  onPressed: _busy ? null : _openInStremio,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? null : _revoke,
                child: const Text('Revoke'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(letterSpacing: 1.2),
        ),
      );
}

// ---------------------------------------------------------------------------
// Up Next health line — verifies the conditional Home row is working even
// when it's silent. Lives under Insights so the user has a once-glance way
// to confirm "tracking N shows, next ep in M days" without opening Home.
// ---------------------------------------------------------------------------

class _UpNextHealthTile extends ConsumerWidget {
  const _UpNextHealthTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(upNextSummaryProvider);
    return async.when(
      loading: () => const ListTile(
        dense: true,
        leading: Icon(Icons.schedule_outlined),
        title: Text('Up next'),
        subtitle: Text('Loading…'),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (s) {
        final tracking = s.trackedShowCount;
        final next = s.next;
        final String subtitle;
        if (tracking == 0) {
          subtitle = 'No shows in progress';
        } else if (next == null) {
          subtitle = tracking == 1
              ? 'Tracking 1 show — nothing scheduled this week'
              : 'Tracking $tracking shows — nothing scheduled this week';
        } else {
          final epLabel =
              'S${next.season.toString().padLeft(2, '0')}E${next.number.toString().padLeft(2, '0')}';
          final relative = _profileRelative(next.daysUntilAir);
          subtitle = tracking == 1
              ? 'Tracking 1 show; next: ${next.showTitle} $epLabel $relative'
              : 'Tracking $tracking shows; next: ${next.showTitle} $epLabel $relative';
        }
        return ListTile(
          dense: true,
          leading: const Icon(Icons.schedule_outlined),
          title: const Text('Up next'),
          subtitle: Text(subtitle),
        );
      },
    );
  }
}

String _profileRelative(int daysUntilAir) {
  if (daysUntilAir == 0) return 'today';
  if (daysUntilAir == 1) return 'tomorrow';
  if (daysUntilAir < 0) return 'just aired';
  return 'in ${daysUntilAir}d';
}

// ---------------------------------------------------------------------------
// Ask AI placement — controls where the concierge entry point renders on Home
// ---------------------------------------------------------------------------

class _AskAiPlacementTile extends ConsumerWidget {
  const _AskAiPlacementTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(askAiPlacementProvider);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.auto_awesome_outlined),
      title: const Text('Ask AI placement'),
      subtitle: Text(current.label),
      trailing: PopupMenuButton<AskAiPlacement>(
        initialValue: current,
        onSelected: (v) =>
            ref.read(askAiPlacementProvider.notifier).set(v),
        itemBuilder: (_) => [
          for (final p in AskAiPlacement.values)
            PopupMenuItem(value: p, child: Text(p.label)),
        ],
        icon: const Icon(Icons.arrow_drop_down),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Up next style — controls how the Home "Up Next" row presents itself
// ---------------------------------------------------------------------------

class _UpNextStyleTile extends ConsumerWidget {
  const _UpNextStyleTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(upNextStyleProvider);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.swipe_outlined),
      title: const Text('Up next style'),
      subtitle: Text(current.label),
      trailing: PopupMenuButton<UpNextStyle>(
        initialValue: current,
        onSelected: (v) =>
            ref.read(upNextStyleProvider.notifier).set(v),
        itemBuilder: (_) => [
          for (final s in UpNextStyle.values)
            PopupMenuItem(value: s, child: Text(s.label)),
        ],
        icon: const Icon(Icons.arrow_drop_down),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// App icon picker — switches the Android launcher icon via activity-alias.
// The native swap may take a moment to reflect on the home screen; some
// launchers cache and require a manual refresh, hence the snackbar warning.
// ---------------------------------------------------------------------------

class _AppIconTile extends ConsumerWidget {
  const _AppIconTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appIconControllerProvider);
    return ListTile(
      dense: true,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.asset(
          current.assetPath,
          width: 28,
          height: 28,
          fit: BoxFit.cover,
        ),
      ),
      title: const Text('App icon'),
      subtitle: Text(current.label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _AppIconPickerSheet.show(context),
    );
  }
}

class _AppIconPickerSheet extends ConsumerWidget {
  const _AppIconPickerSheet();

  static Future<void> show(BuildContext context) => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => const _AppIconPickerSheet(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appIconControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose your app icon',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Android may take a moment to refresh your home screen — '
              'a few launchers need a manual icon refresh after the swap.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            for (final option in AppIconOption.values)
              _IconOptionRow(
                option: option,
                selected: option == current,
                onTap: () async {
                  if (option == current) {
                    Navigator.of(context).pop();
                    return;
                  }
                  await ref
                      .read(appIconControllerProvider.notifier)
                      .set(option);
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                      'Switched to ${option.label}. '
                      "If your home screen doesn't refresh, "
                      'remove and re-add the icon manually.',
                    ),
                    duration: const Duration(seconds: 4),
                  ));
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _IconOptionRow extends StatelessWidget {
  final AppIconOption option;
  final bool selected;
  final VoidCallback onTap;
  const _IconOptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    option.assetPath,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(option.label,
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        option.description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: scheme.primary, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Accent picker — recolors the Material 3 ColorScheme seed app-wide
// ---------------------------------------------------------------------------

class _AccentPicker extends ConsumerWidget {
  const _AccentPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(accentProvider);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Accent color'),
      subtitle: Text(current.label),
      trailing: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: current.seed,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1),
        ),
      ),
      onTap: () => _AccentPickerSheet.show(context, ref),
    );
  }
}

class _AccentPickerSheet extends ConsumerWidget {
  const _AccentPickerSheet();

  static Future<void> show(BuildContext context, WidgetRef ref) =>
      showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (_) => const _AccentPickerSheet(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(accentProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Accent color',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Changes the primary swatch across the app.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final a in AppAccent.values)
                  _AccentOption(
                    accent: a,
                    selected: a == current,
                    onTap: () {
                      ref.read(accentProvider.notifier).set(a);
                      Navigator.of(context).pop();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AccentOption extends StatelessWidget {
  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  const _AccentOption({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: accent.label,
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.white24,
                    width: selected ? 3 : 1,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check, color: Colors.black, size: 20)
                    : null,
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 64,
                child: Text(
                  accent.label,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
