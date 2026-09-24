import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/notification_repository.dart';
import '../feed/thread_screen.dart';

/// In-app likes, replies, and follows. Opening the list marks them read.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(notificationRepositoryProvider).markAllRead();
      ref.invalidate(noticesProvider);
      ref.invalidate(unreadNoticesProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final notices = ref.watch(noticesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notices')),
      body: notices.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nothing yet. Likes, replies, and new follows show up here.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(noticesProvider),
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final n = list[i];
                return ListTile(
                  leading: Icon(switch (n.kind) {
                    'like' => Icons.favorite_outline,
                    'reply' => Icons.reply,
                    'follow' => Icons.person_add_alt_1,
                    _ => Icons.notifications_none,
                  }),
                  title: Text(n.line),
                  subtitle: Text('@${n.actorHandle}'),
                  onTap: n.postId == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ThreadScreen(rootId: n.postId!),
                          ),
                        ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
