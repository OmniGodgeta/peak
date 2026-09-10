import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_service.dart';

/// Watches for an available update and, the first time one appears while the app
/// is open, pops a dialog over whatever screen you're on. Re-checks every 30
/// minutes and whenever the app is resumed, so a release published mid-session
/// still gets noticed. The persistent [UpdateBanner] stays as the quiet
/// reminder after the dialog is dismissed. Mount once, high in the tree.
class UpdateWatcher extends ConsumerStatefulWidget {
  const UpdateWatcher({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends ConsumerState<UpdateWatcher>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => ref.invalidate(updateCheckProvider),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(updateCheckProvider);
    }
  }

  Future<void> _prompt(AppRelease release) async {
    _prompted = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.arrow_circle_up),
        title: Text('Peak ${release.versionName} is available'),
        content: Text(
          release.notes?.trim().isNotEmpty == true
              ? release.notes!.trim()
              : 'A newer version is ready to install.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (go == true && mounted) showUpdateSheet(context, release);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(updateCheckProvider, (_, next) {
      final check = next.asData?.value;
      if (!_prompted &&
          check != null &&
          check.status == UpdateStatus.available &&
          check.release != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_prompted) _prompt(check.release!);
        });
      }
    });
    return widget.child;
  }
}

/// A dismissible "update available" bar. Mounted inside [HomeShell] (so it sits
/// under the app's Navigator — tooltips and the update sheet need that). The
/// *blocking* case is handled by a router redirect to [UpdateRequiredScreen].
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final check = ref.watch(updateCheckProvider).asData?.value;
    final release = check?.release;
    if (_dismissed ||
        check == null ||
        release == null ||
        check.status != UpdateStatus.available) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          children: [
            Icon(
              Icons.arrow_circle_up,
              size: 20,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Peak ${release.versionName} is available',
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => showUpdateSheet(context, release),
              child: const Text('Update'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              color: scheme.onPrimaryContainer,
              onPressed: () => setState(() => _dismissed = true),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen block for a build below `minSupportedVersionCode`. Reached by a
/// router redirect; there's no way past it but to update.
class UpdateRequiredScreen extends ConsumerWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final release = ref.watch(updateCheckProvider).asData?.value.release;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Time to update',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    release == null
                        ? 'This version of Peak is no longer supported.'
                        : 'This version of Peak is no longer supported. Update '
                              'to ${release.versionName} to keep going.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (release?.notes != null && release!.notes!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      release.notes!,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Update now'),
                    onPressed: release == null
                        ? null
                        : () => showUpdateSheet(context, release),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that runs the download → verify → install flow.
Future<void> showUpdateSheet(BuildContext context, AppRelease release) {
  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => _UpdateSheet(release: release),
  );
}

class _UpdateSheet extends ConsumerStatefulWidget {
  const _UpdateSheet({required this.release});
  final AppRelease release;

  @override
  ConsumerState<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<_UpdateSheet> {
  DownloadProgress? _progress;
  String? _error;
  bool _running = false;
  bool _done = false;

  Future<void> _start() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final stream = ref
          .read(updateServiceProvider)
          .downloadAndInstall(widget.release);
      await for (final p in stream) {
        if (mounted) setState(() => _progress = p);
      }
      if (mounted) setState(() => _done = true);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.release;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Update to ${r.versionName}',
              style: theme.textTheme.titleMedium,
            ),
            if (r.notes != null && r.notes!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(r.notes!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            else if (_done)
              Row(
                children: [
                  Icon(Icons.check_circle, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Opening the installer — follow the prompts.'),
                  ),
                ],
              )
            else if (_running) ...[
              LinearProgressIndicator(value: _progress?.fraction),
              const SizedBox(height: 8),
              Text(
                _progress == null || _progress!.total <= 0
                    ? 'Downloading…'
                    : '${_mb(_progress!.received)} / '
                          '${_mb(_progress!.total)} MB',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!_running)
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(_done ? 'Close' : 'Not now'),
                  ),
                const SizedBox(width: 8),
                if (!_done)
                  FilledButton(
                    onPressed: _running ? null : _start,
                    child: Text(
                      _error != null ? 'Retry' : 'Download & install',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
