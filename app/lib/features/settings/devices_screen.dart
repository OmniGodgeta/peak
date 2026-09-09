import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/device_repository.dart';
import '../../data/supabase_providers.dart';

/// Settings → Devices: every app install signed in to this account, with a
/// long-lived signature key. The owner can rename or revoke any of them;
/// revoking the current device signs it out.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(myDevicesProvider);
    final thisId = ref.read(deviceRepositoryProvider).thisDeviceId;

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: devices.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          final active = list.where((d) => !d.isRevoked).toList();
          final revoked = list.where((d) => d.isRevoked).toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myDevicesProvider),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Text(
                    'Each device holds its own encryption key. If you lose one '
                    'or don’t recognise it, revoke it — that signs it out and '
                    'stops it joining new encrypted chats.',
                  ),
                ),
                for (final d in active)
                  _DeviceTile(device: d, isThisDevice: d.id == thisId),
                if (revoked.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Revoked'),
                  ),
                  for (final d in revoked)
                    _DeviceTile(device: d, isThisDevice: d.id == thisId),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeviceTile extends ConsumerWidget {
  const _DeviceTile({required this.device, required this.isThisDevice});
  final PeakDevice device;
  final bool isThisDevice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListTile(
      leading: Icon(
        device.isRevoked ? Icons.block : Icons.devices,
        color: device.isRevoked ? scheme.onSurfaceVariant : scheme.primary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              device.label ?? 'Unnamed device',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isThisDevice) ...[
            const SizedBox(width: 8),
            Chip(
              label: const Text('This device'),
              visualDensity: VisualDensity.compact,
              side: BorderSide.none,
              backgroundColor: scheme.primaryContainer,
            ),
          ],
        ],
      ),
      subtitle: Text(
        device.isRevoked
            ? 'Revoked ${_ago(device.revokedAt!)}'
            : 'Last active ${_ago(device.lastSeenAt)} · added ${_ago(device.createdAt)}',
      ),
      trailing: device.isRevoked
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') {
                  _rename(context, ref);
                } else if (v == 'revoke') {
                  _revoke(context, ref);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(
                  value: 'revoke',
                  child: Text(
                    isThisDevice ? 'Sign out this device' : 'Revoke',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: device.label ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'e.g. Work laptop'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(deviceRepositoryProvider).rename(device.id, name);
    ref.invalidate(myDevicesProvider);
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isThisDevice ? 'Sign out this device?' : 'Revoke device?'),
        content: Text(
          isThisDevice
              ? 'You’ll be signed out here and need to sign in again.'
              : 'This device is signed out and can’t join new encrypted '
                    'chats. Existing chats drop it at their next key change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isThisDevice ? 'Sign out' : 'Revoke'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(deviceRepositoryProvider).revoke(device.id);
    if (isThisDevice) {
      await ref.read(supabaseProvider).auth.signOut();
    } else {
      ref.invalidate(myDevicesProvider);
    }
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}
