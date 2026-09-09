import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/community_repository.dart';
import '../../../data/event_repository.dart';
import 'event_detail_screen.dart';
import 'event_edit_screen.dart';

/// Upcoming (and, on toggle, past) events for one community.
class CommunityEventsScreen extends ConsumerStatefulWidget {
  const CommunityEventsScreen({super.key, required this.community});
  final Community community;

  @override
  ConsumerState<CommunityEventsScreen> createState() =>
      _CommunityEventsScreenState();
}

class _CommunityEventsScreenState extends ConsumerState<CommunityEventsScreen> {
  bool _past = false;

  @override
  Widget build(BuildContext context) {
    final key = (widget.community.id, _past);
    final events = ref.watch(communityEventsProvider(key));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _past = !_past),
            child: Text(_past ? 'Upcoming' : 'Past too'),
          ),
        ],
      ),
      floatingActionButton: widget.community.isMember
          ? FloatingActionButton.extended(
              onPressed: () async {
                final made = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) =>
                        EventEditScreen(community: widget.community),
                  ),
                );
                if (made == true) {
                  ref.invalidate(communityEventsProvider(key));
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('New event'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(communityEventsProvider(key)),
        child: events.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No events.')),
                  ),
                ],
              );
            }
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _EventTile(
                event: list[i],
                community: widget.community,
                onChanged: () => ref.invalidate(communityEventsProvider(key)),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _EventTile extends ConsumerWidget {
  const _EventTile({
    required this.event,
    required this.community,
    required this.onChanged,
  });
  final CommunityEvent event;
  final Community community;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      leading: _DateBadge(date: event.startsAt),
      title: Text(
        event.title,
        style: event.canceled
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        [
          formatEventWhen(event),
          if (event.location != null && event.location!.isNotEmpty)
            event.location!,
          '${event.goingCount} going',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: event.canceled
          ? Text('Canceled', style: TextStyle(color: theme.colorScheme.error))
          : (event.myStatus == 'going'
                ? const Icon(Icons.check_circle, size: 20)
                : null),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                EventDetailScreen(eventId: event.id, community: community),
          ),
        );
        onChanged();
      },
    );
  }
}

class _DateBadge extends StatelessWidget {
  const _DateBadge({required this.date});
  final DateTime date;

  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', //
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _months[date.month - 1],
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: scheme.onSecondaryContainer,
            ),
          ),
          Text(
            '${date.day}',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Sat 12 Sep, 18:00" — a compact local-time rendering.
String formatEventWhen(CommunityEvent e) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final d = e.startsAt;
  String hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final base =
      '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}, ${hm(d)}';
  if (e.endsAt == null) return base;
  return '$base–${hm(e.endsAt!)}';
}
