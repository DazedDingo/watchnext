import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/issue_batch.dart';
import '../../providers/household_provider.dart';
import '../../providers/issue_queue_provider.dart';

class ReportIssueScreen extends ConsumerStatefulWidget {
  const ReportIssueScreen({super.key});

  @override
  ConsumerState<ReportIssueScreen> createState() =>
      _ReportIssueScreenState();
}

class _ReportIssueScreenState extends ConsumerState<ReportIssueScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  bool _cancelling = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Repaint once a second so the countdown stays accurate.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null) {
      _toast('No household — sign in first');
      return;
    }

    setState(() => _submitting = true);
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('submitIssue');
      final result = await callable.call({
        'householdId': householdId,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
      });
      final appended = result.data['appended'] == true;
      final itemCount = (result.data['itemCount'] as num?)?.toInt() ?? 1;

      if (!mounted) return;
      _titleCtrl.clear();
      _descCtrl.clear();
      _toast(appended
          ? 'Added to pending batch ($itemCount issues queued)'
          : 'Queued — Claude will pick it up in ~10 min');
    } on FirebaseFunctionsException catch (e) {
      _toast('Failed: ${e.message ?? e.code}');
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel(IssueBatch batch) async {
    final householdId = await ref.read(householdIdProvider.future);
    if (householdId == null) return;
    setState(() => _cancelling = true);
    try {
      await FirebaseFirestore.instance
          .doc('households/$householdId/issueBatches/${batch.id}')
          .update({'status': 'cancelled'});
      if (mounted) _toast('Pending fix cancelled');
    } catch (e) {
      _toast('Failed to cancel: $e');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(pendingIssueBatchProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Report an issue')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              "Noticed a bug or have an idea? Submit it here — Claude gets "
              'a 10-minute window to collect follow-ups before it files one '
              'bundled GitHub issue.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            pendingAsync.when(
              data: (batch) => batch == null
                  ? const SizedBox.shrink()
                  : _PendingBanner(
                      batch: batch,
                      cancelling: _cancelling,
                      onCancel: () => _cancel(batch),
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
            if (pendingAsync.value != null) const SizedBox(height: 16),
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              maxLength: 200,
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Title required' : null,
              enabled: !_submitting,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What happened? Steps to reproduce?',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 8,
              maxLength: 4000,
              enabled: !_submitting,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(pendingAsync.value == null
                      ? Icons.build
                      : Icons.add_circle_outline),
              label: Text(_submitting
                  ? 'Submitting…'
                  : pendingAsync.value == null
                      ? 'Fix this'
                      : 'Add to pending batch'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingBanner extends StatelessWidget {
  final IssueBatch batch;
  final bool cancelling;
  final VoidCallback onCancel;
  const _PendingBanner({
    required this.batch,
    required this.cancelling,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final remaining = batch.remaining(DateTime.now());
    final mins = remaining.inMinutes;
    final secs = remaining.inSeconds % 60;
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, color: cs.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    remaining == Duration.zero
                        ? 'Dispatching shortly…'
                        : 'Claude picks up in ${mins}m ${secs.toString().padLeft(2, '0')}s',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: cs.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${batch.items.length} issue${batch.items.length == 1 ? '' : 's'} queued. '
              'Add more below to extend the window, or cancel.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSecondaryContainer),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: cancelling ? null : onCancel,
                icon: cancelling
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cancel_outlined),
                label: Text(cancelling ? 'Cancelling…' : 'Cancel pending fix'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
