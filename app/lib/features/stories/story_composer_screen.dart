import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/circle_repository.dart';
import '../../data/story_repository.dart';

/// Add to your story: one photo, an optional caption, addressed to circles.
/// It's visible for 24 hours. No filters — that's the point.
class StoryComposerScreen extends ConsumerStatefulWidget {
  const StoryComposerScreen({super.key});

  @override
  ConsumerState<StoryComposerScreen> createState() =>
      _StoryComposerScreenState();
}

class _StoryComposerScreenState extends ConsumerState<StoryComposerScreen> {
  final _caption = TextEditingController();
  final _selected = <String>{};
  Uint8List? _bytes;
  String _mime = 'image/jpeg';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1440,
      imageQuality: 90,
    );
    if (x == null) {
      if (mounted && _bytes == null) Navigator.of(context).pop();
      return;
    }
    final bytes = await x.readAsBytes();
    setState(() {
      _bytes = bytes;
      _mime = x.mimeType ?? 'image/jpeg';
    });
  }

  Future<void> _share(List<Circle> circles) async {
    if (_bytes == null) return;
    if (_selected.isEmpty) {
      setState(() => _error = 'Pick at least one circle.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(storyRepositoryProvider);
      final path = await repo.uploadMedia(_bytes!, _mime);
      await repo.post(
        mediaPath: path,
        caption: _caption.text.trim().isEmpty ? null : _caption.text.trim(),
        circleIds: _selected.toList(),
      );
      ref.invalidate(storyTrayProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final circlesAsync = ref.watch(myCirclesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add to your story'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy || _bytes == null
                  ? null
                  : () => _share(circlesAsync.asData?.value ?? const []),
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Share'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                image: _bytes != null
                    ? DecorationImage(
                        image: MemoryImage(_bytes!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _bytes == null
                  ? Center(
                      child: TextButton.icon(
                        onPressed: _pick,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Choose a photo'),
                      ),
                    )
                  : Align(
                      alignment: Alignment.topRight,
                      child: IconButton.filledTonal(
                        icon: const Icon(Icons.swap_horiz),
                        tooltip: 'Change photo',
                        onPressed: _pick,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _caption,
            maxLength: 280,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Caption (optional)'),
          ),
          const SizedBox(height: 8),
          Text(
            'Who can see this?',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          circlesAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('$e'),
            data: (circles) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in circles.where((c) => !c.isPublic))
                  FilterChip(
                    label: Text(c.name),
                    avatar: const Icon(Icons.lock_outline, size: 16),
                    selected: _selected.contains(c.id),
                    onSelected: (on) => setState(() {
                      on ? _selected.add(c.id) : _selected.remove(c.id);
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Disappears after 24 hours.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
