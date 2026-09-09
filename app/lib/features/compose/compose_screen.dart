import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/circle_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/post_repository.dart';

/// New post or reply. Text + up to 4 photos/GIFs + a content warning. For a new
/// post the circle picker is mandatory; a reply inherits the parent's audience.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.replyTo,
    this.communityId,
    this.communityName,
    this.channelId,
    this.channelName,
  });

  /// When set, this composer posts a reply to that post.
  final FeedPost? replyTo;

  /// When set, this composer posts into a community (no circle picker).
  final String? communityId;
  final String? communityName;

  /// The channel within that community to post into (defaults to "general"
  /// server-side when null).
  final String? channelId;
  final String? channelName;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _body = TextEditingController();
  final _cw = TextEditingController();
  final _title = TextEditingController();
  final _selected = <String>{};
  final _media = <PendingMedia>[];
  bool _showCw = false;
  bool _article = false;
  bool _busy = false;
  String? _error;

  bool get _isReply => widget.replyTo != null;
  bool get _isCommunity => widget.communityId != null && !_isReply;
  static const _maxMedia = 4;

  @override
  void dispose() {
    _body.dispose();
    _cw.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    try {
      final picked = await ImagePicker().pickMultiImage(limit: _maxMedia);
      for (final x in picked) {
        if (_media.length >= _maxMedia) break;
        final bytes = await x.readAsBytes();
        _media.add(PendingMedia(bytes: bytes, mimeType: _mime(x)));
      }
      if (mounted) setState(() {});
    } on Exception catch (e) {
      setState(() => _error = 'Could not add image: $e');
    }
  }

  String _mime(XFile x) {
    final m = x.mimeType;
    if (m != null && m.startsWith('image/')) return m;
    final name = x.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _submit(List<Circle> circles) async {
    if (_body.text.trim().isEmpty && _media.isEmpty) {
      setState(() => _error = 'Say something, or add a photo.');
      return;
    }
    if (_article && _title.text.trim().isEmpty) {
      setState(() => _error = 'An article needs a title.');
      return;
    }
    if (!_isReply && !_isCommunity && _selected.isEmpty) {
      setState(() => _error = 'Pick at least one circle to post to.');
      return;
    }
    for (final m in _media) {
      if (!m.isGif && m.altText.trim().isEmpty) {
        // Deliberate friction, not a hard block — but nudge once.
        final proceed = await _confirmMissingAltText();
        if (!proceed) return;
        break;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(postRepositoryProvider);
      final cw = _showCw && _cw.text.trim().isNotEmpty ? _cw.text.trim() : null;
      if (_isReply) {
        await repo.createReply(
          parentId: widget.replyTo!.id,
          body: _body.text.trim(),
          media: _media,
          contentWarning: cw,
        );
      } else if (_isCommunity) {
        await repo.createPost(
          body: _body.text.trim(),
          visibility: PostVisibility.public,
          circleIds: const [],
          media: _media,
          contentWarning: cw,
          longForm: _article,
          title: _article ? _title.text.trim() : null,
          communityId: widget.communityId,
          channelId: widget.channelId,
        );
      } else {
        final publicIds = circles
            .where((c) => c.isPublic)
            .map((c) => c.id)
            .toSet();
        final onlyPublic =
            _selected.length == 1 && publicIds.contains(_selected.first);
        await repo.createPost(
          body: _body.text.trim(),
          visibility: onlyPublic
              ? PostVisibility.public
              : PostVisibility.circles,
          circleIds: _selected.toList(),
          media: _media,
          contentWarning: cw,
          longForm: _article,
          title: _article ? _title.text.trim() : null,
        );
      }
      ref.invalidate(feedProvider);
      ref.read(feedRevisionProvider.notifier).bump();
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmMissingAltText() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add alt text?'),
        content: const Text(
          'Describing your images makes them readable to people using screen '
          'readers. You can post without it, but it helps.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Post anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Let me add it'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final circlesAsync = ref.watch(myCirclesProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isReply ? 'Reply' : 'New post'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _submit(circlesAsync.asData?.value ?? const []),
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isReply ? 'Reply' : 'Post'),
            ),
          ),
        ],
      ),
      body: circlesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (circles) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_isReply) _ReplyingTo(post: widget.replyTo!),
            if (_isCommunity)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.groups_outlined, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      widget.channelName != null
                          ? 'Posting to ${widget.communityName ?? "this community"} · #${widget.channelName}'
                          : 'Posting to ${widget.communityName ?? "this community"}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            if (_showCw) ...[
              TextField(
                controller: _cw,
                decoration: const InputDecoration(
                  labelText: 'Content warning',
                  hintText: 'Shown before the post; reader taps to reveal',
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_article) ...[
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                style: Theme.of(context).textTheme.titleLarge,
                maxLength: 200,
                decoration: const InputDecoration(
                  hintText: 'Title',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 4),
            ],
            TextField(
              controller: _body,
              autofocus: true,
              minLines: _article ? 10 : 3,
              maxLines: _article ? 40 : 10,
              maxLength: _article ? 100000 : 5000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: _isReply
                    ? 'Write a reply'
                    : _article
                    ? 'Write your article. Blank lines start new paragraphs; '
                          '“# ” and “## ” make headings; “- ” makes a list.'
                    : "What's happening?",
              ),
            ),
            if (_media.isNotEmpty) ...[
              const SizedBox(height: 4),
              _MediaStrip(
                media: _media,
                onRemove: (i) => setState(() => _media.removeAt(i)),
                onEditAlt: _editAltText,
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _media.length >= _maxMedia ? null : _pickImages,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: Text(
                    _media.isEmpty
                        ? 'Photo / GIF'
                        : '${_media.length}/$_maxMedia',
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _showCw = !_showCw),
                  icon: const Icon(Icons.warning_amber_outlined, size: 18),
                  label: Text(_showCw ? 'Remove warning' : 'Content warning'),
                ),
                if (!_isReply)
                  TextButton.icon(
                    onPressed: () => setState(() => _article = !_article),
                    icon: Icon(
                      _article ? Icons.notes : Icons.article_outlined,
                      size: 18,
                    ),
                    label: Text(_article ? 'Simple post' : 'Article'),
                  ),
              ],
            ),
            if (!_isReply && !_isCommunity) ...[
              const Divider(height: 24),
              Text(
                'Who can see this?',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in circles)
                    FilterChip(
                      label: Text(c.name),
                      avatar: Icon(
                        c.isPublic ? Icons.public : Icons.lock_outline,
                        size: 16,
                      ),
                      selected: _selected.contains(c.id),
                      onSelected: (on) => setState(() {
                        on ? _selected.add(c.id) : _selected.remove(c.id);
                      }),
                    ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editAltText(int index) async {
    final controller = TextEditingController(text: _media[index].altText);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Describe this image'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 1000,
          decoration: const InputDecoration(
            hintText: 'What is in the image, for people who can’t see it',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) setState(() => _media[index].altText = result);
  }
}

class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({required this.post});
  final FeedPost post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Replying to ${post.authorName}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if (post.body.isNotEmpty)
            Text(
              post.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _MediaStrip extends StatelessWidget {
  const _MediaStrip({
    required this.media,
    required this.onRemove,
    required this.onEditAlt,
  });

  final List<PendingMedia> media;
  final void Function(int) onRemove;
  final void Function(int) onEditAlt;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: media.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final m = media[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  m.bytes,
                  width: 104,
                  height: 104,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: _Chip(icon: Icons.close, onTap: () => onRemove(i)),
              ),
              Positioned(
                bottom: 2,
                left: 2,
                child: GestureDetector(
                  onTap: () => onEditAlt(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      m.altText.trim().isEmpty ? 'ALT' : 'ALT ✓',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 14, color: Colors.white),
      ),
    );
  }
}
