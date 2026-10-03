import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../crypto/device_repository.dart';
import '../../crypto/e2ee_service.dart';
import '../../crypto/safety_number.dart';
import '../../data/messaging_repository.dart';

/// An encrypted chat's safety number and device list (E2EE 2.5-6).
///
/// Everyone in the chat sees the same number while they all have the same
/// devices and keys. Comparing it (in person, or on a call) proves nobody is
/// sitting in the middle; the device list shows exactly which phones and
/// tablets can read the chat, so an unknown one stands out.
class SafetyNumberScreen extends ConsumerStatefulWidget {
  const SafetyNumberScreen({super.key, required this.conversationId});
  final String conversationId;

  @override
  ConsumerState<SafetyNumberScreen> createState() => _SafetyNumberState();
}

class _SafetyNumberState extends ConsumerState<SafetyNumberScreen> {
  late final Future<_Data?> _data = _load();

  Future<_Data?> _load() async {
    final info = await ref
        .read(e2eeServiceProvider)
        .safetyInfo(widget.conversationId);
    if (info == null) return null;
    final repo = ref.read(messagingRepositoryProvider);
    final members = await repo.members(widget.conversationId);
    final labels = await repo.deviceLabels([
      for (final d in info.devices) d.deviceId,
    ]);
    return _Data(
      info,
      {for (final m in members) m.id: m.name},
      labels,
      ref.read(deviceRepositoryProvider).thisDeviceId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Encryption')),
      body: FutureBuilder<_Data?>(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data;
          if (snap.hasError || d == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                "This device isn't part of this encrypted chat yet. Open "
                'the chat once it has a message, then try again.',
              ),
            );
          }
          final byPerson = <String, List<SafetyDevice>>{};
          for (final dev in d.info.devices) {
            byPerson.putIfAbsent(dev.accountId, () => []).add(dev);
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline),
                  const SizedBox(width: 8),
                  Text(
                    'End-to-end encrypted',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Only the devices below can read this chat; Peak cannot. '
                'Compare this number with the others in the chat, in person '
                'or on a call. If it is the same on every phone, nobody is '
                'intercepting your messages. It changes whenever a device '
                'joins or leaves.',
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 18,
                    runSpacing: 12,
                    children: [
                      for (final g in d.info.number)
                        Text(
                          g,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontFamily: 'monospace',
                            letterSpacing: 2,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (d.info.notListedByServer.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${d.info.notListedByServer.length} device(s) in this '
                      "chat aren't among their owner's current devices (one "
                      'may have been revoked and not removed yet). Check the '
                      "list below; if you don't recognise a device, don't "
                      'send anything sensitive.',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
              if (d.info.notYetInGroup.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '${d.info.notYetInGroup.length} new device(s) will join '
                  'with the next message.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              Text('Devices in this chat', style: theme.textTheme.titleSmall),
              for (final e in byPerson.entries) ...[
                const SizedBox(height: 10),
                Text(
                  d.names[e.key] ?? 'Someone no longer in the chat',
                  style: theme.textTheme.bodyLarge,
                ),
                for (final dev in e.value)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 8),
                    leading: Icon(
                      d.info.notListedByServer.contains(dev.deviceId)
                          ? Icons.warning_amber_outlined
                          : Icons.smartphone_outlined,
                    ),
                    title: Text(
                      [
                        d.labels[dev.deviceId]?.isNotEmpty == true
                            ? d.labels[dev.deviceId]!
                            : 'Unnamed device',
                        if (dev.deviceId == d.thisDevice) '(this device)',
                      ].join(' '),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Data {
  _Data(this.info, this.names, this.labels, this.thisDevice);
  final SafetyInfo info;
  final Map<String, String> names;
  final Map<String, String> labels;
  final String? thisDevice;
}
