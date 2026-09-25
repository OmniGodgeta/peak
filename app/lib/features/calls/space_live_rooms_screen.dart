import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/call_repository.dart';
import 'live_room_screen.dart';

/// Browse and start live audio rooms inside one Space.
class SpaceLiveRoomsScreen extends ConsumerStatefulWidget {
  final String spaceId;
  final String spaceName;

  const SpaceLiveRoomsScreen({
    super.key,
    required this.spaceId,
    required this.spaceName,
  });

  @override
  ConsumerState<SpaceLiveRoomsScreen> createState() =>
      _SpaceLiveRoomsScreenState();
}

class _SpaceLiveRoomsScreenState extends ConsumerState<SpaceLiveRoomsScreen> {
  late Future<List<SpaceLiveRoom>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(callRepositoryProvider).activeRoomsForSpace(widget.spaceId);
  }

  void _refresh() {
    setState(() {
      _future = ref.read(callRepositoryProvider).activeRoomsForSpace(widget.spaceId);
    });
  }

  Future<void> _startRoom() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start a live room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Room name (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (title == null) return;
    if (!mounted) return;

    final roomId = await ref.read(callRepositoryProvider).createSpaceRoom(
          spaceId: widget.spaceId,
          title: title.isEmpty ? null : title,
        );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveRoomScreen(
          roomId: roomId,
          title: title.isEmpty ? widget.spaceName : title,
        ),
      ),
    );
    _refresh();
  }

  Future<void> _joinRoom(SpaceLiveRoom room) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveRoomScreen(
          roomId: room.id,
          title: room.title?.isNotEmpty == true ? room.title! : widget.spaceName,
        ),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.spaceName} - Live Rooms')),
      body: FutureBuilder<List<SpaceLiveRoom>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final rooms = snapshot.data ?? [];
          if (rooms.isEmpty) {
            return const Center(
              child: Text('No live rooms right now. Start one below.'),
            );
          }
          return ListView.builder(
            itemCount: rooms.length,
            itemBuilder: (context, index) {
              final room = rooms[index];
              return ListTile(
                leading: const Icon(Icons.groups),
                title: Text(room.title?.isNotEmpty == true ? room.title! : 'Live room'),
                subtitle: Text('${room.participantCount} in the room'),
                trailing: FilledButton(
                  onPressed: () => _joinRoom(room),
                  child: const Text('JOIN'),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startRoom,
        icon: const Icon(Icons.add),
        label: const Text('Start a room'),
      ),
    );
  }
}
