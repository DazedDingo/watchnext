import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/household_provider.dart';
import '../../services/household_service.dart';
import '../../widgets/help_button.dart';

const _setupHelp =
    'A household is how you share a watchlist, ratings, and recommendations with one other person.\n\n'
    '• Create — if you\'re the first one in. You\'ll get an invite code to share with your partner.\n'
    '• Join — if your partner already set one up. Paste the invite code here.\n\n'
    'You can only belong to one household at a time.';

class SetupScreen extends ConsumerStatefulWidget {
  final String? inviteCode;
  const SetupScreen({super.key, this.inviteCode});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late final TextEditingController _codeController;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.inviteCode ?? '');
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _loading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      await ref.read(householdServiceProvider).createHousehold(user);
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _join() async {
    final code = _codeController.text.trim();
    if (!HouseholdService.isValidInviteCode(code)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite code must be 20–64 alphanumeric characters.')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final id = await ref.read(householdServiceProvider).joinByInviteCode(user, code);
      if (!mounted) return;
      if (id == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite code not found.')),
        );
      } else {
        context.go('/home');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up household'),
        actions: const [HelpButton(title: 'Set up household', body: _setupHelp)],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "It's you and one other person.\nYou can invite them once your household exists.",
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _create,
                    child: const Text('Create new household'),
                  ),
                  const Divider(height: 48),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(
                      labelText: 'Invite code from your partner',
                      border: OutlineInputBorder(),
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _join,
                    child: const Text('Join existing household'),
                  ),
                ],
              ),
            ),
    );
  }
}
