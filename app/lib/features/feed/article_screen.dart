import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/avatar.dart';
import '../../data/feed_repository.dart';
import '../compose/compose_screen.dart';
import '../profile/user_profile_screen.dart';
import 'post_card.dart';
import 'post_media_view.dart';
import 'thread_screen.dart';

/// A long-form post on its own reading page: title, byline, rendered body,
/// then the same conversation the feed card would open.
class ArticleScreen extends ConsumerWidget {
  const ArticleScreen({super.key, required this.article});
  final FeedPost article;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final replies = ref.watch(threadProvider(article.id));

    return Scaffold(
      appBar: AppBar(title: const Text('Article')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final posted = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => ComposeScreen(replyTo: article)),
          );
          if (posted == true) ref.invalidate(threadProvider(article.id));
        },
        icon: const Icon(Icons.mode_comment_outlined),
        label: const Text('Respond'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => UserProfileScreen(handle: article.authorHandle),
              ),
            ),
            child: Row(
              children: [
                AvatarCircle(
                  name: article.authorName,
                  path: article.authorAvatarPath,
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${article.authorName} · ${article.authorFqHandle}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            article.title ?? 'Untitled',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 20),
            child: Text(
              _dateLine(article.createdAt, article.editedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (article.media.isNotEmpty) ...[
            PostMediaView(media: article.media),
            const SizedBox(height: 20),
          ],
          ArticleBody(text: article.body),
          const Divider(height: 48),
          Text('Responses', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          replies.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('$e'),
            data: (posts) {
              // posts[0] is the article itself; show only the replies.
              final onlyReplies = posts
                  .where((p) => p.id != article.id)
                  .toList();
              if (onlyReplies.isEmpty) {
                return Text(
                  'No responses yet.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
              }
              return Column(
                children: [
                  for (final r in onlyReplies)
                    Padding(
                      padding: EdgeInsets.only(
                        left: (r.depth.clamp(1, 3) - 1) * 16.0,
                      ),
                      child: Column(
                        children: [
                          PostCard(post: r, tappable: r.depth > 1),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static String _dateLine(DateTime created, DateTime? edited) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final d = '${months[created.month - 1]} ${created.day}, ${created.year}';
    return edited == null ? d : '$d · edited';
  }
}

/// A deliberately tiny Markdown-ish renderer — enough for what people actually
/// write in a post box, no dependency. Blank lines separate paragraphs;
/// `# `/`## ` are headings; `- `/`* ` are list items.
class ArticleBody extends StatelessWidget {
  const ArticleBody({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocks = <Widget>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            paragraph.join(' '),
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
          ),
        ),
      );
      paragraph.clear();
    }

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        flushParagraph();
      } else if (line.startsWith('## ')) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(
              line.substring(3),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      } else if (line.startsWith('# ')) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(
              line.substring(2),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(
                  child: Text(
                    line.substring(2),
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        paragraph.add(line.trim());
      }
    }
    flushParagraph();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}
