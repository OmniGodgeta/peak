import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/creator_repository.dart';
import '../../data/media_service.dart';

/// Formats [d] as m:ss (or h:mm:ss).
String formatCueTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Parses "ss", "m:ss" or "h:mm:ss". Null when it isn't a time.
Duration? parseCueTime(String raw) {
  final parts = raw.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0;
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return Duration(seconds: total);
}

class _ChapterRow {
  _ChapterRow(String label, Duration start)
    : label = TextEditingController(text: label),
      start = TextEditingController(text: formatCueTime(start));
  final TextEditingController label;
  final TextEditingController start;

  void dispose() {
    label.dispose();
    start.dispose();
  }
}

class _CaptionRow {
  _CaptionRow(String text, Duration start, Duration end)
    : text = TextEditingController(text: text),
      start = TextEditingController(text: formatCueTime(start)),
      end = TextEditingController(text: formatCueTime(end));
  final TextEditingController text;
  final TextEditingController start;
  final TextEditingController end;

  void dispose() {
    text.dispose();
    start.dispose();
    end.dispose();
  }
}

/// Edit a video you posted: its thumbnail, chapters and captions.
class CreatorVideoEditorSheet extends ConsumerStatefulWidget {
  const CreatorVideoEditorSheet({
    super.key,
    required this.mediaId,
    required this.storagePath,
    required this.posterPath,
    required this.onSave,
    this.durationMs,
  });

  final String mediaId;
  final String storagePath;
  final String? posterPath;
  final int? durationMs;
  final VoidCallback onSave;

  @override
  ConsumerState<CreatorVideoEditorSheet> createState() =>
      _CreatorVideoEditorSheetState();
}

class _CreatorVideoEditorSheetState
    extends ConsumerState<CreatorVideoEditorSheet> {
  final _chapters = <_ChapterRow>[];
  final _captions = <_CaptionRow>[];
  final _language = TextEditingController(text: 'en');
  String? _poster;
  bool _posterChanged = false;
  double _frameSeconds = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  Duration? get _duration => widget.durationMs == null
      ? null
      : Duration(milliseconds: widget.durationMs!);

  @override
  void initState() {
    super.initState();
    _poster = widget.posterPath;
    _load();
  }

  @override
  void dispose() {
    for (final c in _chapters) {
      c.dispose();
    }
    for (final c in _captions) {
      c.dispose();
    }
    _language.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(creatorRepositoryProvider);
    try {
      final chapters = await repo.loadChapters(widget.mediaId);
      final captions = await repo.loadSubtitles(widget.mediaId);
      if (!mounted) return;
      setState(() {
        for (final c in chapters) {
          _chapters.add(
            _ChapterRow(
              c['label'] as String? ?? '',
              Duration(milliseconds: (c['start_ms'] as num).toInt()),
            ),
          );
        }
        for (final c in captions) {
          _captions.add(
            _CaptionRow(
              c['text'] as String? ?? '',
              Duration(milliseconds: (c['start_ms'] as num).toInt()),
              Duration(milliseconds: (c['end_ms'] as num).toInt()),
            ),
          );
        }
        if (captions.isNotEmpty) {
          _language.text = captions.first['language'] as String? ?? 'en';
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't load this video's chapters: $e";
        });
      }
    }
  }

  Future<void> _uploadThumbnail() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
    );
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final type = (file.mimeType ?? '').isNotEmpty
          ? file.mimeType!
          : (file.name.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg');
      final path = await ref
          .read(mediaServiceProvider)
          .uploadPoster(bytes, type);
      if (mounted) {
        setState(() {
          _poster = path;
          _posterChanged = true;
        });
      }
    } catch (e) {
      _snack('Thumbnail upload failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useFrame() async {
    setState(() => _busy = true);
    try {
      final path = await ref
          .read(mediaServiceProvider)
          .posterFromFrame(
            widget.storagePath,
            Duration(milliseconds: (_frameSeconds * 1000).round()),
          );
      if (mounted) {
        setState(() {
          _poster = path;
          _posterChanged = true;
        });
      }
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Chapters as rows for post_chapters, or throws a readable message.
  List<Map<String, dynamic>> _chapterRows() {
    final parsed = <(String, Duration)>[];
    for (final c in _chapters) {
      final label = c.label.text.trim();
      final start = parseCueTime(c.start.text);
      if (label.isEmpty) throw 'Every chapter needs a title.';
      if (start == null) throw 'Chapter "$label" has an unreadable start time.';
      parsed.add((label, start));
    }
    parsed.sort((a, b) => a.$2.compareTo(b.$2));
    final dur = _duration;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < parsed.length; i++) {
      final start = parsed[i].$2;
      if (dur != null && start >= dur) {
        throw 'Chapter "${parsed[i].$1}" starts after the video ends.';
      }
      if (i > 0 && start == parsed[i - 1].$2) {
        throw 'Two chapters start at ${formatCueTime(start)}.';
      }
      final end = i + 1 < parsed.length
          ? parsed[i + 1].$2
          : (dur != null && dur > start
                ? dur
                : start + const Duration(hours: 12));
      out.add({
        'label': parsed[i].$1,
        'start_ms': start.inMilliseconds,
        'end_ms': end.inMilliseconds,
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _captionRows() {
    final lang = _language.text.trim().isEmpty ? 'en' : _language.text.trim();
    final out = <Map<String, dynamic>>[];
    for (final c in _captions) {
      final text = c.text.text.trim();
      final start = parseCueTime(c.start.text);
      final end = parseCueTime(c.end.text);
      if (text.isEmpty) continue;
      if (start == null || end == null) {
        throw 'Caption "$text" has an unreadable time.';
      }
      if (end <= start) throw 'Caption "$text" ends before it starts.';
      out.add({
        'language': lang,
        'text': text,
        'start_ms': start.inMilliseconds,
        'end_ms': end.inMilliseconds,
      });
    }
    out.sort((a, b) => (a['start_ms'] as int).compareTo(b['start_ms'] as int));
    return out;
  }

  Future<void> _save() async {
    final List<Map<String, dynamic>> chapters;
    final List<Map<String, dynamic>> captions;
    try {
      chapters = _chapterRows();
      captions = _captionRows();
    } on String catch (msg) {
      setState(() => _error = msg);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(creatorRepositoryProvider);
      await repo.saveChapters(widget.mediaId, chapters);
      await repo.saveSubtitles(widget.mediaId, captions);
      if (_posterChanged && _poster != null) {
        await repo.updatePosterPath(widget.mediaId, _poster!);
      }
      widget.onSave();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Duration _nextStart() {
    Duration latest = Duration.zero;
    for (final c in _chapters) {
      final t = parseCueTime(c.start.text);
      if (t != null && t > latest) latest = t;
    }
    return _chapters.isEmpty
        ? Duration.zero
        : latest + const Duration(seconds: 30);
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.watch(mediaServiceProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final dur = _duration;
    final canGrab =
        media.canGrabFrame(widget.storagePath) &&
        dur != null &&
        dur.inMilliseconds > 0;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.9,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit video'),
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton(
                onPressed: _loading ? null : _save,
                child: const Text('Save'),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  Text('Thumbnail', style: text.titleMedium),
                  const SizedBox(height: 8),
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.black87,
                        child: _poster == null
                            ? const Center(
                                child: Icon(
                                  Icons.image_not_supported_outlined,
                                  color: Colors.white54,
                                ),
                              )
                            : Image.network(
                                media.resolveUrl(_poster!),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (canGrab) ...[
                    Row(
                      children: [
                        Text(
                          formatCueTime(
                            Duration(
                              milliseconds: (_frameSeconds * 1000).round(),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: _frameSeconds,
                            max: dur.inMilliseconds / 1000,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _frameSeconds = v),
                          ),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _useFrame,
                          child: const Text('Use frame'),
                        ),
                      ],
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.upload_outlined),
                      label: const Text('Upload an image'),
                      onPressed: _busy ? null : _uploadThumbnail,
                    ),
                  ),
                  const Divider(height: 32),
                  Text('Chapters', style: text.titleMedium),
                  Text(
                    'Each chapter runs until the next one starts.',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _chapters.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 76,
                            child: TextField(
                              controller: _chapters[i].start,
                              decoration: const InputDecoration(
                                labelText: 'Start',
                                hintText: 'm:ss',
                                isDense: true,
                              ),
                              keyboardType: TextInputType.datetime,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _chapters[i].label,
                              decoration: const InputDecoration(
                                labelText: 'Title',
                                isDense: true,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove chapter',
                            onPressed: () =>
                                setState(() => _chapters.removeAt(i).dispose()),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(
                        () => _chapters.add(_ChapterRow('', _nextStart())),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Add chapter'),
                    ),
                  ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Captions', style: text.titleMedium),
                      ),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _language,
                          decoration: const InputDecoration(
                            labelText: 'Language',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < _captions.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              SizedBox(
                                width: 76,
                                child: TextField(
                                  controller: _captions[i].start,
                                  decoration: const InputDecoration(
                                    labelText: 'From',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 76,
                                child: TextField(
                                  controller: _captions[i].end,
                                  decoration: const InputDecoration(
                                    labelText: 'To',
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Remove caption',
                                onPressed: () => setState(
                                  () => _captions.removeAt(i).dispose(),
                                ),
                              ),
                            ],
                          ),
                          TextField(
                            controller: _captions[i].text,
                            decoration: const InputDecoration(
                              labelText: 'Text',
                              isDense: true,
                            ),
                            maxLines: 2,
                            minLines: 1,
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        final last = _captions.isEmpty
                            ? Duration.zero
                            : (parseCueTime(_captions.last.end.text) ??
                                  Duration.zero);
                        _captions.add(
                          _CaptionRow(
                            '',
                            last,
                            last + const Duration(seconds: 3),
                          ),
                        );
                      }),
                      icon: const Icon(Icons.add),
                      label: const Text('Add caption'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
