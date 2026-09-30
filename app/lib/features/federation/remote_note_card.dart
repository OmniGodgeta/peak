import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/federation_repository.dart';

/// A note from another server. Plain text only; a content warning hides the
/// body until tapped; "Open" goes to the original on its own server.
class RemoteNoteCard extends StatefulWidget {
  const RemoteNoteCard({super.key, required this.note});
  final RemoteNote note;

  @override
  State<RemoteNoteCard> createState() => _RemoteNoteCardState();
}

class _RemoteNoteCardState extends State<RemoteNoteCard> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.note;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cw = n.contentWarning;
    final hidden = cw != null && cw.isNotEmpty && !_revealed;
    final name = (n.actorName?.trim().isNotEmpty ?? false)
        ? n.actorName!
        : n.actorHandle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundImage: n.actorIcon != null
                    ? NetworkImage(n.actorIcon!)
                    : null,
                child: n.actorIcon == null
                    ? const Icon(Icons.public, size: 18)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: text.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '@${n.actorHandle}',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Tooltip(
                message: 'From another server',
                child: Icon(
                  Icons.public,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hidden)
            OutlinedButton(
              onPressed: () => setState(() => _revealed = true),
              child: Text('Content warning: $cw — show'),
            )
          else
            SelectableText(n.body),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                _ago(n.publishedAt),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (n.url != null)
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(n.url!),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Open original'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}
