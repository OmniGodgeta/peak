import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/community_repository.dart';
import '../../../data/event_repository.dart';

/// Create or edit a community event.
class EventEditScreen extends ConsumerStatefulWidget {
  const EventEditScreen({super.key, required this.community, this.existing});
  final Community community;
  final CommunityEvent? existing;

  @override
  ConsumerState<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends ConsumerState<EventEditScreen> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final _location = TextEditingController(
    text: widget.existing?.location ?? '',
  );
  late DateTime _start =
      widget.existing?.startsAt ??
      DateTime.now().add(const Duration(days: 1, hours: 1)).copyWithMinute0();
  late DateTime? _end = widget.existing?.endsAt;
  late String? _channelId = widget.existing?.channelId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final picked = await _pickDateTime(_start);
    if (picked != null) {
      setState(() {
        final delta = _end?.difference(_start);
        _start = picked;
        if (delta != null) _end = picked.add(delta);
      });
    }
  }

  Future<void> _pickEnd() async {
    final picked = await _pickDateTime(
      _end ?? _start.add(const Duration(hours: 1)),
    );
    if (picked != null) setState(() => _end = picked);
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'A title is needed.');
      return;
    }
    if (_end != null && _end!.isBefore(_start)) {
      setState(() => _error = 'The end time is before the start.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(eventRepositoryProvider);
      if (widget.existing == null) {
        await repo.create(
          communityId: widget.community.id,
          title: _title.text.trim(),
          startsAt: _start,
          description: _description.text.trim(),
          location: _location.text.trim().isEmpty
              ? null
              : _location.text.trim(),
          endsAt: _end,
          channelId: _channelId,
        );
      } else {
        await repo.update(
          eventId: widget.existing!.id,
          title: _title.text.trim(),
          startsAt: _start,
          description: _description.text.trim(),
          location: _location.text.trim().isEmpty
              ? null
              : _location.text.trim(),
          endsAt: _end,
          channelId: _channelId,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels =
        ref
            .watch(communityChannelsProvider(widget.community.id))
            .asData
            ?.value ??
        const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New event' : 'Edit event'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            maxLength: 140,
            decoration: const InputDecoration(
              labelText: 'Title',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('Starts'),
            subtitle: Text(_fmt(_start)),
            onTap: _pickStart,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_outlined),
            title: const Text('Ends'),
            subtitle: Text(_end == null ? 'Not set' : _fmt(_end!)),
            trailing: _end == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _end = null),
                  ),
            onTap: _pickEnd,
          ),
          TextField(
            controller: _location,
            maxLength: 280,
            decoration: const InputDecoration(
              labelText: 'Location or link',
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            maxLength: 4000,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Details',
              alignLabelWithHint: true,
            ),
          ),
          if (channels.length > 1) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _channelId,
              decoration: const InputDecoration(
                labelText: 'Channel (optional)',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('None')),
                for (final ch in channels)
                  DropdownMenuItem(value: ch.id, child: Text('#${ch.name}')),
              ],
              onChanged: (v) => setState(() => _channelId = v),
            ),
          ],
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

String _fmt(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hm =
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return '${d.day} ${months[d.month - 1]} ${d.year}, $hm';
}

extension _Round on DateTime {
  DateTime copyWithMinute0() => DateTime(year, month, day, hour);
}
