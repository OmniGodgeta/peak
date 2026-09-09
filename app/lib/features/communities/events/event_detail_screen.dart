import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/avatar.dart';
import '../../../data/community_repository.dart';
import '../../../data/event_repository.dart';
import 'community_events_screen.dart';
import 'event_edit_screen.dart';

class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({
    super.key,
    required this.eventId,
    required this.community,
  });
  final String eventId;
  final Community community;

  CommunityEvent? _find(WidgetRef ref) {
    for (final past in const [false, true]) {
      final events = ref
          .watch(communityEventsProvider((community.id, past)))
          .asData
          ?.value;
      final match = events?.where((e) => e.id == eventId);
      if (match != null && match.isNotEmpty) return match.first;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = _find(ref);
    final attendees = ref.watch(eventAttendeesProvider((eventId, 'all')));

    void refresh() {
      ref.invalidate(communityEventsProvider((community.id, false)));
      ref.invalidate(communityEventsProvider((community.id, true)));
      ref.invalidate(eventAttendeesProvider((eventId, 'all')));
    }

    final canManage =
        community.canModerate; // creator check happens server-side too

    return Scaffold(
      appBar: AppBar(
        title: const Text('Event'),
        actions: [
          if (event != null && !event.canceled && canManage)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'edit') {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => EventEditScreen(
                        community: community,
                        existing: event,
                      ),
                    ),
                  );
                  if (saved == true) refresh();
                } else if (v == 'cancel') {
                  try {
                    await ref.read(eventRepositoryProvider).cancel(eventId);
                    refresh();
                  } on Exception catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'cancel', child: Text('Cancel event')),
              ],
            ),
        ],
      ),
      body: event == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  event.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                if (event.canceled)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'This event was canceled.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                _IconLine(Icons.schedule, formatEventWhen(event)),
                if (event.location != null && event.location!.isNotEmpty)
                  _IconLine(Icons.place_outlined, event.location!),
                if (event.channelName != null)
                  _IconLine(Icons.tag, event.channelName!),
                if (event.creatorName != null)
                  _IconLine(
                    Icons.person_outline,
                    'Organized by ${event.creatorName}',
                  ),
                if (event.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(event.description),
                ],
                const SizedBox(height: 16),
                if (!event.canceled)
                  _RsvpBar(
                    eventId: eventId,
                    event: event,
                    communityId: community.id,
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(
                        event.googleCalendarUrl,
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.event_available, size: 18),
                      label: const Text('Add to calendar'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: event.toIcs(communityName: community.name),
                          ),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Calendar invite copied'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy .ics'),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Text(
                  'Attendees',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                attendees.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Text('$e'),
                  data: (list) => list.isEmpty
                      ? const Text('No RSVPs yet.')
                      : Column(
                          children: [
                            for (final a in list)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: AvatarCircle(
                                  name: a.name,
                                  path: a.avatarPath,
                                  radius: 16,
                                ),
                                title: Text(a.name),
                                trailing: Text(switch (a.status) {
                                  'going' => 'Going',
                                  'maybe' => 'Maybe',
                                  _ => 'Not going',
                                }),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}

class _RsvpBar extends ConsumerWidget {
  const _RsvpBar({
    required this.eventId,
    required this.event,
    required this.communityId,
  });
  final String eventId;
  final CommunityEvent event;
  final String communityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> set(String status) async {
      try {
        await ref
            .read(eventRepositoryProvider)
            .rsvp(eventId, event.myStatus == status ? 'none' : status);
        ref.invalidate(eventAttendeesProvider((eventId, 'all')));
        for (final p in const [false, true]) {
          ref.invalidate(communityEventsProvider((communityId, p)));
        }
      } on Exception catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    Widget btn(String status, String label, IconData icon) {
      final selected = event.myStatus == status;
      return selected
          ? FilledButton.icon(
              onPressed: () => set(status),
              icon: Icon(icon, size: 18),
              label: Text(label),
            )
          : OutlinedButton.icon(
              onPressed: () => set(status),
              icon: Icon(icon, size: 18),
              label: Text(label),
            );
    }

    return Wrap(
      spacing: 8,
      children: [
        btn('going', 'Going', Icons.check),
        btn('maybe', 'Maybe', Icons.help_outline),
        btn('not_going', "Can't go", Icons.close),
      ],
    );
  }
}

class _IconLine extends StatelessWidget {
  const _IconLine(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
