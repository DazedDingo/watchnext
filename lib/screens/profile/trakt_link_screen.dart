import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../providers/household_provider.dart';
import '../../providers/trakt_provider.dart';
import '../../services/trakt_service.dart';

class TraktLinkScreen extends ConsumerStatefulWidget {
  const TraktLinkScreen({super.key});

  @override
  ConsumerState<TraktLinkScreen> createState() => _TraktLinkScreenState();
}

class _TraktLinkScreenState extends ConsumerState<TraktLinkScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _link() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!TraktService.isConfigured) {
        throw StateError('Trakt client keys not set. Add TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET to env.json.');
      }
      final trakt = ref.read(traktServiceProvider);
      final sync = ref.read(traktSyncServiceProvider);
      final user = FirebaseAuth.instance.currentUser!;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) throw StateError('Join a household first.');

      final code = await trakt.openBrowserAuth();
      await trakt.exchangeCode(code: code, householdId: householdId, uid: user.uid);
      // Fire-and-forget full sync — progresses in background. UI will show
      // activity via traktLinkStatusProvider.lastSync updating.
      unawaited(sync.runSync(householdId: householdId, uid: user.uid));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlink() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink Trakt?'),
        content: const Text('Your watch history stays in WatchNext, but future ratings won\'t sync back to Trakt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) return;
      await ref.read(traktServiceProvider).unlink(householdId: householdId, uid: user.uid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resync() async {
    setState(() => _busy = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) return;
      await ref.read(traktSyncServiceProvider).runSync(householdId: householdId, uid: user.uid);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(traktLinkStatusProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trakt'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => context.pop()),
      ),
      body: status.when(
        data: (s) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.linked ? 'Linked' : 'Not linked', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (s.linked && s.traktUserId != null) Text('Trakt user: ${s.traktUserId}'),
                  if (s.linked && s.lastSync != null)
                    Text('Last sync: ${DateFormat.yMMMd().add_jm().format(s.lastSync!.toLocal())}'),
                  if (!s.linked)
                    const Text('Link your Trakt account to import watch history and keep ratings in sync.'),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (!s.linked)
              FilledButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Link Trakt'),
                onPressed: _busy ? null : _link,
              )
            else ...[
              FilledButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
                onPressed: _busy ? null : _resync,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.link_off),
                label: const Text('Unlink Trakt'),
                onPressed: _busy ? null : _unlink,
              ),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
