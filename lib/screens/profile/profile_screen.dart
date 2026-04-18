import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/mode_provider.dart';
import '../../providers/trakt_provider.dart';
import '../../widgets/help_button.dart';

const _profileHelp =
    'Account, household invite, preferences, and integrations all live here.\n\n'
    '• Invite partner — share the code so they can join your household.\n'
    '• Default mode — Solo ranks recommendations for you alone; Together ranks for both.\n'
    '• Reveal notifications — optional push when a prediction reveal is ready.\n'
    '• Trakt — link to auto-import history and push ratings.\n'
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
            error: (e, _) => ListTile(title: Text('Error: $e')),
          ),
          const Divider(),

          // ── Preferences ────────────────────────────────────────────────
          const _SectionHeader('Preferences'),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Default mode'),
            subtitle: Text(mode == ViewMode.solo
                ? 'Solo — just my picks'
                : 'Together — both members'),
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
          const Divider(),

          // ── Trakt ──────────────────────────────────────────────────────
          const _SectionHeader('Trakt'),
          traktAsync.when(
            data: (s) => ListTile(
              leading: Icon(s.linked ? Icons.link : Icons.link_off),
              title:
                  Text(s.linked ? 'Trakt linked' : 'Link Trakt account'),
              subtitle: s.linked && s.lastSync != null
                  ? Text('Last sync: ${DateFormat.MMMd().add_jm().format(s.lastSync!.toLocal())}')
                  : const Text('Import history and sync ratings'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile/trakt'),
            ),
            loading: () => const ListTile(title: Text('Loading…')),
            error: (e, _) => ListTile(title: Text('Trakt error: $e')),
          ),
          const Divider(),

          // ── Help ──────────────────────────────────────────────────────
          const _SectionHeader('Feedback'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Report an issue'),
            subtitle: const Text("Submit a bug or idea — Claude files it on GitHub"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/profile/report-issue'),
          ),
          const Divider(),

          // ── Sign out ───────────────────────────────────────────────────
          ListTile(
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
      secondary: const Icon(Icons.notifications_outlined),
      title: const Text('Reveal notifications'),
      subtitle:
          const Text('Get notified when your prediction reveal is ready'),
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
