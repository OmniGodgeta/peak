import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/labeler_repository.dart';

/// Create or edit a labeler: its name, blurb, visibility, and its label set.
class LabelerEditScreen extends ConsumerStatefulWidget {
  const LabelerEditScreen({super.key, this.existing});

  /// null → create a new labeler.
  final LabelerDef? existing;

  @override
  ConsumerState<LabelerEditScreen> createState() => _LabelerEditScreenState();
}

class _LabelerEditScreenState extends ConsumerState<LabelerEditScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _desc = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late bool _public = widget.existing?.isPublic ?? true;
  final List<LabelDef> _labels = [];
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      _loading = true;
      ref.read(labelerRepositoryProvider).labels(widget.existing!.id).then((
        ls,
      ) {
        if (!mounted) return;
        setState(() {
          _labels
            ..clear()
            ..addAll(ls);
          _loading = false;
        });
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  String _slug(String name) {
    final s = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.length <= 39 ? s : s.substring(0, 39);
  }

  Future<void> _addLabel() async {
    final c = TextEditingController();
    var sev = LabelSeverity.info;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('New label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Label name'),
              ),
              const SizedBox(height: 8),
              SegmentedButton<LabelSeverity>(
                segments: const [
                  ButtonSegment(value: LabelSeverity.info, label: Text('Info')),
                  ButtonSegment(value: LabelSeverity.warn, label: Text('Warn')),
                  ButtonSegment(value: LabelSeverity.hide, label: Text('Hide')),
                ],
                selected: {sev},
                onSelectionChanged: (s) => setSt(() => sev = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (name == null || name.isEmpty) return;
    final key = _slug(name);
    if (key.isEmpty || _labels.any((l) => l.key == key)) return;
    setState(() => _labels.add(LabelDef(key: key, name: name, severity: sev)));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final repo = ref.read(labelerRepositoryProvider);
    try {
      final id =
          widget.existing?.id ??
          await repo.create(
            name: name,
            description: _desc.text.trim(),
            isPublic: _public,
          );
      await repo.setLabels(id, _labels);
      ref.read(labelerRevisionProvider.notifier).bump();
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(creating ? 'New labeler' : 'Edit labeler'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _name,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Newsroom fact-check',
                  ),
                ),
                TextField(
                  controller: _desc,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'What this labeler is for',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _public,
                  onChanged: creating
                      ? (v) => setState(() => _public = v)
                      : null,
                  title: const Text('Anyone can find and subscribe'),
                  subtitle: Text(
                    creating
                        ? 'A private labeler only affects your own feed.'
                        : 'Visibility is fixed after creation.',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Labels',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _addLabel,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                    ),
                  ],
                ),
                if (_labels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Add the labels this labeler can put on posts. '
                      '“Hide” blurs a post until the reader taps it; '
                      '“Warn” shows a bold chip; “Info” a quiet one.',
                    ),
                  ),
                for (final l in _labels)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_sevIcon(l.severity)),
                    title: Text(l.name),
                    subtitle: Text('${l.key} · ${l.severity.name}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _labels.remove(l)),
                    ),
                  ),
              ],
            ),
    );
  }
}

IconData _sevIcon(LabelSeverity s) => switch (s) {
  LabelSeverity.hide => Icons.visibility_off_outlined,
  LabelSeverity.warn => Icons.warning_amber_outlined,
  LabelSeverity.info => Icons.info_outline,
};
