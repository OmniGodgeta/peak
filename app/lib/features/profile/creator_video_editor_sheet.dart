import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/creator_repository.dart';

/// A sheet for editing video post metadata like chapters and subtitles.
class CreatorVideoEditorSheet extends ConsumerStatefulWidget {
  const CreatorVideoEditorSheet({
    super.key,
    required this.mediaId,
    required this.posterPath,
    required this.onSave,
  });

  final String mediaId;
  final String posterPath;
  final VoidCallback onSave;

  @override
  ConsumerState<CreatorVideoEditorSheet> createState() => _CreatorVideoEditorSheetState();
}

class _CreatorVideoEditorSheetState extends ConsumerState<CreatorVideoEditorSheet> {
  late List<Map<String, dynamic>> _chapters;
  late List<Map<String, dynamic>> _subtitles;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _chapters = [];
    _subtitles = [];
  }

  Future<void> _handleSave() async {
    setState(() => _isSaving = true);
    try {
      final repo = ref.read(creatorRepositoryProvider);
      await repo.saveChapters(widget.mediaId, _chapters);
      await repo.saveSubtitles(widget.mediaId, _subtitles);
      if (mounted) widget.onSave();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          AppBar(
            title: const Text('Edit Video'),
            actions: [
              if (!_isSaving)
                IconButton(
                  icon: const Icon(Icons.check),
                  onPressed: _handleSave,
                ),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                const ListTile(
                  title: Text('Chapters', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                // Placeholder for chapter list and add button
                _ChapterList(
                  chapters: _chapters,
                  onAdd: () => setState(() => _chapters.add({
                    'label': 'New Chapter',
                    'start_ms': 0,
                    'end_ms': 5000,
                  })),
                  onRemove: (index) => setState(() => _chapters.removeAt(index)),
                ),
                const Divider(),
                const ListTile(
                  title: Text('Subtitles', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                _SubtitleList(
                  subtitles: _subtitles,
                  onAdd: () => setState(() => _subtitles.add({
                    'language': 'en',
                    'text': '',
                    'start_ms': 0,
                    'end_ms': 5000,
                  })),
                  onRemove: (index) => setState(() => _subtitles.removeAt(index)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterList extends StatelessWidget {
  final List<Map<String, dynamic>> chapters;
  final VoidCallback onAdd;
  final Function(int) onRemove;

  const _ChapterList({required this.chapters, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ...chapters.asMap().entries.map((entry) {
          final index = entry.key;
          final chapter = entry.value;
          return ListTile(
            title: Text(chapter['label'] ?? ''),
            subtitle: Text('${chapter['start_ms']} - ${chapter['end_ms']} ms'),
            trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => onRemove(index)),
          );
        }),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add Chapter'),
        ),
      ],
    );
  }
}

class _SubtitleList extends StatelessWidget {
  final List<Map<String, dynamic>> subtitles;
  final VoidCallback onAdd;
  final Function(int) onRemove;

  const _SubtitleList({required this.subtitles, required this.onAdd, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ...subtitles.asMap().entries.map((entry) {
          final index = entry.key;
          final subtitle = entry.value;
          return ListTile(
            title: Text(subtitle['text'] ?? ''),
            subtitle: Text('${subtitle['language']} (${subtitle['start_ms']} - ${subtitle['end_ms']} ms)'),
            trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => onRemove(index)),
          );
        }),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add Subtitle'),
        ),
      ],
    );
  }
}
