import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_providers.dart';

/// A community event (`community_events`).
class CommunityEvent {
  const CommunityEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.location,
    required this.startsAt,
    required this.endsAt,
    required this.canceled,
    required this.channelId,
    required this.channelName,
    required this.creatorName,
    required this.goingCount,
    required this.maybeCount,
    required this.myStatus,
  });

  final String id;
  final String title;
  final String description;
  final String? location;
  final DateTime startsAt; // UTC instant
  final DateTime? endsAt;
  final bool canceled;
  final String? channelId;
  final String? channelName;
  final String? creatorName;
  final int goingCount;
  final int maybeCount;
  final String? myStatus; // going | maybe | not_going | null

  bool get isPast => (endsAt ?? startsAt).isBefore(DateTime.now());

  factory CommunityEvent.fromMap(Map<String, dynamic> m) => CommunityEvent(
    id: m['id'] as String,
    title: m['title'] as String,
    description: (m['description'] as String?) ?? '',
    location: m['location'] as String?,
    startsAt: DateTime.parse(m['starts_at'] as String).toLocal(),
    endsAt: m['ends_at'] == null
        ? null
        : DateTime.parse(m['ends_at'] as String).toLocal(),
    canceled: (m['canceled'] as bool?) ?? false,
    channelId: m['channel_id'] as String?,
    channelName: m['channel_name'] as String?,
    creatorName: (m['creator_display_name'] as String?)?.isNotEmpty == true
        ? m['creator_display_name'] as String
        : m['creator_handle'] as String?,
    goingCount: (m['going_count'] as int?) ?? 0,
    maybeCount: (m['maybe_count'] as int?) ?? 0,
    myStatus: m['my_status'] as String?,
  );

  /// An RFC 5545 VEVENT for "add to calendar" / .ics export.
  String toIcs({String? communityName}) {
    String stamp(DateTime d) {
      final u = d.toUtc();
      String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
      return '${p(u.year, 4)}${p(u.month)}${p(u.day)}T'
          '${p(u.hour)}${p(u.minute)}${p(u.second)}Z';
    }

    String esc(String s) => s
        .replaceAll(r'\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll(',', r'\,')
        .replaceAll(';', r'\;');

    final end = endsAt ?? startsAt.add(const Duration(hours: 1));
    final desc = [
      if (communityName != null) 'Community: $communityName',
      if (description.isNotEmpty) description,
    ].join('\n\n');

    return [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Peak//Community events//EN',
      'BEGIN:VEVENT',
      'UID:$id@peak.social',
      'DTSTAMP:${stamp(DateTime.now())}',
      'DTSTART:${stamp(startsAt)}',
      'DTEND:${stamp(end)}',
      'SUMMARY:${esc(title)}',
      if (desc.isNotEmpty) 'DESCRIPTION:${esc(desc)}',
      if (location != null && location!.isNotEmpty)
        'LOCATION:${esc(location!)}',
      if (canceled) 'STATUS:CANCELLED',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
  }

  /// A Google Calendar "add event" URL — works on web and mobile.
  Uri get googleCalendarUrl {
    String g(DateTime d) {
      final u = d.toUtc();
      String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
      return '${p(u.year, 4)}${p(u.month)}${p(u.day)}T'
          '${p(u.hour)}${p(u.minute)}${p(u.second)}Z';
    }

    final end = endsAt ?? startsAt.add(const Duration(hours: 1));
    return Uri.https('calendar.google.com', '/calendar/render', {
      'action': 'TEMPLATE',
      'text': title,
      'dates': '${g(startsAt)}/${g(end)}',
      if (description.isNotEmpty) 'details': description,
      if (location != null && location!.isNotEmpty) 'location': location!,
    });
  }
}

class EventAttendee {
  const EventAttendee({
    required this.memberId,
    required this.handle,
    required this.domain,
    required this.displayName,
    required this.avatarPath,
    required this.status,
  });

  final String memberId;
  final String handle;
  final String domain;
  final String displayName;
  final String? avatarPath;
  final String status;

  String get name => displayName.isNotEmpty ? displayName : handle;
  String get fqHandle => '@$handle@$domain';

  factory EventAttendee.fromMap(Map<String, dynamic> m) => EventAttendee(
    memberId: m['member_id'] as String,
    handle: m['handle'] as String,
    domain: (m['domain'] as String?) ?? 'peak.social',
    displayName: (m['display_name'] as String?) ?? '',
    avatarPath: m['avatar_path'] as String?,
    status: m['status'] as String,
  );
}

class EventRepository {
  EventRepository(this._db);
  final SupabaseClient _db;

  Future<List<CommunityEvent>> list(
    String communityId, {
    bool includePast = false,
  }) async {
    final rows = await _db.rpc(
      'community_events',
      params: {'p_community_id': communityId, 'p_include_past': includePast},
    ) as List;
    return [
      for (final r in rows) CommunityEvent.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<List<EventAttendee>> attendees(
    String eventId, {
    String status = 'going',
  }) async {
    final rows = await _db.rpc(
      'event_attendees',
      params: {'p_event_id': eventId, 'p_status': status},
    ) as List;
    return [
      for (final r in rows) EventAttendee.fromMap(r as Map<String, dynamic>),
    ];
  }

  Future<String> create({
    required String communityId,
    required String title,
    required DateTime startsAt,
    String description = '',
    String? location,
    DateTime? endsAt,
    String? channelId,
  }) async {
    return await _db.rpc(
      'create_event',
      params: {
        'p_community_id': communityId,
        'p_title': title,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_description': description,
        'p_location': location,
        'p_ends_at': endsAt?.toUtc().toIso8601String(),
        'p_channel_id': channelId,
      },
    ) as String;
  }

  Future<void> update({
    required String eventId,
    required String title,
    required DateTime startsAt,
    String description = '',
    String? location,
    DateTime? endsAt,
    String? channelId,
  }) => _db.rpc(
    'update_event',
    params: {
      'p_event_id': eventId,
      'p_title': title,
      'p_starts_at': startsAt.toUtc().toIso8601String(),
      'p_description': description,
      'p_location': location,
      'p_ends_at': endsAt?.toUtc().toIso8601String(),
      'p_channel_id': channelId,
    },
  );

  Future<void> cancel(String eventId) =>
      _db.rpc('cancel_event', params: {'p_event_id': eventId});

  /// [status] is `going`, `maybe`, `not_going`, or `none` to clear.
  Future<void> rsvp(String eventId, String status) => _db.rpc(
    'rsvp_event',
    params: {'p_event_id': eventId, 'p_status': status},
  );
}

final eventRepositoryProvider = Provider<EventRepository>((ref) {
  return EventRepository(ref.watch(supabaseProvider));
});

/// Events for a community, keyed by `(communityId, includePast)`.
final communityEventsProvider =
    FutureProvider.family<List<CommunityEvent>, (String, bool)>((
      ref,
      key,
    ) async {
      return ref
          .watch(eventRepositoryProvider)
          .list(key.$1, includePast: key.$2);
    });

/// Attendees for an event, keyed by `(eventId, status)`.
final eventAttendeesProvider =
    FutureProvider.family<List<EventAttendee>, (String, String)>((
      ref,
      key,
    ) async {
      return ref
          .watch(eventRepositoryProvider)
          .attendees(key.$1, status: key.$2);
    });
