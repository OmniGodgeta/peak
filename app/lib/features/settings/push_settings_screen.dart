import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../push/push_service.dart';

/// Turn push notifications on or off. Peak uses UnifiedPush: a distributor
/// app the person chooses (ntfy, NextPush, …) keeps the connection, so
/// nothing goes through Google. Pushes are encrypted to this device.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen> {
  final _push = PushService.instance;
  bool? _on;
  String? _distributor;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final on = await _push.isOn;
    final d = await _push.distributor;
    if (mounted) {
      setState(() {
        _on = on;
        _distributor = d;
      });
    }
  }

  Future<void> _handle(PushSetup r) async {
    switch (r) {
      case PushOn():
        setState(() => _note = 'Registering… this takes a few seconds.');
        // The endpoint arrives asynchronously from the distributor.
        await Future<void>.delayed(const Duration(seconds: 3));
        await _refresh();
        if (mounted && _on == true) setState(() => _note = null);
      case PushNoDistributor():
        setState(
          () => _note =
              'Install a UnifiedPush distributor first — ntfy is the easy '
              'one (F-Droid or Play Store). Then come back and turn this on.',
        );
      case PushPickDistributor(:final distributors):
        final pick = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Deliver pushes through'),
            children: [
              for (final d in distributors)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, d),
                  child: Text(d),
                ),
            ],
          ),
        );
        if (pick != null) await _handle(await _push.useDistributor(pick));
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      if (on) {
        await _handle(await _push.enable());
      } else {
        await _push.disable();
        await _refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _note = "Couldn't change that: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Push notifications')),
      body: !PushService.supported
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Push notifications are available in the Android app. '
                'On the web, the bell in the feed shows what you missed.',
              ),
            )
          : ListView(
              children: [
                SwitchListTile(
                  title: const Text('Push notifications'),
                  subtitle: Text(
                    _on == true && _distributor != null
                        ? 'On, via $_distributor'
                        : 'Messages, calls, replies, likes and follows',
                  ),
                  value: _on ?? false,
                  onChanged: _busy || _on == null ? null : _toggle,
                ),
                if (_note != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(_note!),
                  ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('About UnifiedPush distributors'),
                  onTap: () => launchUrl(
                    Uri.parse('https://unifiedpush.org/users/distributors/'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Peak doesn’t use Google or Firebase for this. A '
                    'distributor app you pick holds the connection, and every '
                    'push is encrypted so only this phone can read it. '
                    'Pushes wait until your quiet hours (Wellbeing) end, '
                    'and several at once arrive as one.',
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }
}
