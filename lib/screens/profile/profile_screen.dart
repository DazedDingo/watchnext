import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../providers/auth_provider.dart';
import '../../providers/household_provider.dart';
import '../../providers/trakt_provider.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;
    final inviteCodeAsync = ref.watch(householdInviteCodeProvider);
    final traktAsync = ref.watch(traktLinkStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundImage: user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
              child: user?.photoURL == null ? const Icon(Icons.person) : null,
            ),
            title: Text(user?.displayName ?? 'Member'),
            subtitle: Text(user?.email ?? ''),
          ),
          const Divider(),
          const _SectionHeader('Household'),
          inviteCodeAsync.when(
            data: (code) => code == null
                ? const ListTile(title: Text('No household yet'))
                : ListTile(
                    leading: const Icon(Icons.group_add),
                    title: const Text('Invite partner'),
                    subtitle: Text(code, style: const TextStyle(fontFamily: 'monospace')),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite code copied')),
                        );
                      },
                    ),
                  ),
            loading: () => const ListTile(title: Text('Loading…')),
            error: (e, _) => ListTile(title: Text('Error: $e')),
          ),
          const Divider(),
          const _SectionHeader('Trakt'),
          traktAsync.when(
            data: (s) => ListTile(
              leading: Icon(s.linked ? Icons.link : Icons.link_off),
              title: Text(s.linked ? 'Trakt linked' : 'Link Trakt account'),
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
          const _SectionHeader('Coming soon'),
          const ListTile(leading: Icon(Icons.tune), title: Text('Solo / Together default'), subtitle: Text('Phase 4')),
          const ListTile(leading: Icon(Icons.notifications_outlined), title: Text('Notification preferences'), subtitle: Text('Phase 10')),
          const ListTile(leading: Icon(Icons.emoji_events_outlined), title: Text('Badges & streaks'), subtitle: Text('Phase 9')),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await ref.read(authServiceProvider).signOut();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.2),
        ),
      );
}
