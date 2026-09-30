import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:unifiedpush/unifiedpush.dart';

/// What the tap on a notification should open.
typedef PushTap = void Function(Map<String, dynamic> payload);

/// Outcome of turning push on from settings.
sealed class PushSetup {
  const PushSetup();
}

class PushOn extends PushSetup {
  const PushOn(this.distributor);
  final String distributor;
}

/// No UnifiedPush distributor app (ntfy, NextPush, ...) is installed.
class PushNoDistributor extends PushSetup {
  const PushNoDistributor();
}

/// More than one is installed: let the person choose.
class PushPickDistributor extends PushSetup {
  const PushPickDistributor(this.distributors);
  final List<String> distributors;
}

/// Push notifications over UnifiedPush — the person's own distributor app
/// (ntfy, NextPush, …) holds the connection, not Google. Messages arrive
/// Web Push-encrypted (RFC 8291); the connector decrypts them on the device.
/// Android only: web and iOS have no UnifiedPush.
///
/// When the app isn't running, the connector starts a headless Flutter
/// engine with `--unifiedpush-bg`; main() then only calls [startBackground].
class PushService {
  PushService._();
  static final instance = PushService._();

  static const _kEndpoint = 'peak.push.endpoint';
  static const _kP256dh = 'peak.push.p256dh';
  static const _kAuth = 'peak.push.auth';

  final _store = const FlutterSecureStorage();
  final _notes = FlutterLocalNotificationsPlugin();
  bool _notesReady = false;

  /// Set by the app shell once the router exists.
  PushTap? onTap;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  SupabaseClient? get _db {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  // ── startup ───────────────────────────────────────────────────────────

  Future<void> start() async {
    if (!supported) return;
    await _initNotifications();
    await _initUnifiedPush();
    if (await UnifiedPush.getDistributor() != null) {
      await UnifiedPush.register();
    }
    _db?.auth.onAuthStateChange.listen((e) {
      if (e.event == AuthChangeEvent.signedIn) _registerWithServer();
    });
    // Opened by tapping a notification while the app was closed.
    final launch = await _notes.getNotificationAppLaunchDetails();
    final p = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && p != null) _tap(p);
  }

  /// The headless path: just enough to receive a message and show it.
  Future<void> startBackground() async {
    if (!supported) return;
    await _initNotifications();
    await _initUnifiedPush();
  }

  Future<void> _initNotifications() async {
    if (_notesReady) return;
    await _notes.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) _tap(r.payload!);
      },
    );
    final android = _notes.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin
    >();
    for (final c in const [
      AndroidNotificationChannel(
        'calls',
        'Calls',
        description: 'Someone is calling you',
        importance: Importance.max,
      ),
      AndroidNotificationChannel(
        'messages',
        'Messages',
        description: 'New direct messages',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'activity',
        'Activity',
        description: 'Replies, likes and follows',
        importance: Importance.defaultImportance,
      ),
    ]) {
      await android?.createNotificationChannel(c);
    }
    _notesReady = true;
  }

  Future<void> _initUnifiedPush() => UnifiedPush.initialize(
    onNewEndpoint: (endpoint, _) => _onNewEndpoint(endpoint),
    onUnregistered: (_) => _forgetEndpoint(),
    onMessage: (message, _) => _onMessage(message),
  );

  // ── settings ──────────────────────────────────────────────────────────

  Future<bool> get isOn async =>
      supported && await _store.read(key: _kEndpoint) != null;

  Future<String?> get distributor async =>
      supported ? UnifiedPush.getDistributor() : Future.value(null);

  /// Turn push on. May need the person to pick or install a distributor.
  Future<PushSetup> enable() async {
    await _initNotifications();
    await _notes
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final current = await UnifiedPush.getDistributor();
    if (current != null) {
      await UnifiedPush.register();
      return PushOn(current);
    }
    final all = await UnifiedPush.getDistributors();
    if (all.isEmpty) return const PushNoDistributor();
    if (all.length > 1) return PushPickDistributor(all);
    return useDistributor(all.single);
  }

  Future<PushSetup> useDistributor(String d) async {
    await UnifiedPush.saveDistributor(d);
    await UnifiedPush.register();
    return PushOn(d);
  }

  Future<void> disable() async {
    await _unregisterFromServer();
    await UnifiedPush.unregister();
    await _forgetEndpoint();
  }

  /// Sign out, first stopping this device from getting the account's pushes.
  Future<void> signOut(SupabaseClient db) async {
    await _unregisterFromServer();
    await db.auth.signOut();
  }

  // ── endpoint bookkeeping ──────────────────────────────────────────────

  Future<void> _onNewEndpoint(PushEndpoint e) async {
    final keys = e.pubKeySet;
    if (keys == null) {
      // Without keys we can't encrypt, and Peak never sends plaintext.
      debugPrint('push: distributor gave no Web Push keys; not registering');
      return;
    }
    await _store.write(key: _kEndpoint, value: e.url);
    await _store.write(key: _kP256dh, value: keys.pubKey);
    await _store.write(key: _kAuth, value: keys.auth);
    await _registerWithServer();
  }

  Future<void> _forgetEndpoint() async {
    await _store.delete(key: _kEndpoint);
    await _store.delete(key: _kP256dh);
    await _store.delete(key: _kAuth);
  }

  Future<void> _registerWithServer() async {
    final db = _db;
    if (db == null || db.auth.currentUser == null) return;
    final endpoint = await _store.read(key: _kEndpoint);
    final p256dh = await _store.read(key: _kP256dh);
    final auth = await _store.read(key: _kAuth);
    if (endpoint == null || p256dh == null || auth == null) return;
    try {
      await db.rpc(
        'register_push_subscription',
        params: {'p_endpoint': endpoint, 'p_p256dh': p256dh, 'p_auth': auth},
      );
    } catch (e) {
      debugPrint('push: register failed: $e');
    }
  }

  Future<void> _unregisterFromServer() async {
    final db = _db;
    final endpoint = await _store.read(key: _kEndpoint);
    if (db == null || db.auth.currentUser == null || endpoint == null) return;
    try {
      await db.rpc(
        'unregister_push_subscription',
        params: {'p_endpoint': endpoint},
      );
    } catch (e) {
      debugPrint('push: unregister failed: $e');
    }
  }

  // ── incoming ──────────────────────────────────────────────────────────

  Future<void> _onMessage(PushMessage m) async {
    if (!m.decrypted) return; // Peak only sends encrypted payloads.
    final Map<String, dynamic> p;
    try {
      p = Map<String, dynamic>.from(jsonDecode(utf8.decode(m.content)) as Map);
    } catch (_) {
      return;
    }
    await _initNotifications();
    await showPush(p);
  }

  /// Shows [p] (a push-dispatch payload) as a system notification.
  Future<void> showPush(Map<String, dynamic> p) async {
    final kind = p['t'] as String? ?? 'notice';
    final channel = switch (kind) {
      'call' => ('calls', 'Calls', Importance.max, Priority.max),
      'message' => ('messages', 'Messages', Importance.high, Priority.high),
      _ => ('activity', 'Activity', Importance.defaultImportance, Priority.defaultPriority),
    };
    // One notification per call / per chat / for all activity, replaced
    // rather than stacked.
    final id = switch (kind) {
      'call' => (p['room'] as String? ?? '').hashCode,
      'message' => (p['ref'] as String? ?? '').hashCode,
      _ => 1,
    };
    await _notes.show(
      id: id,
      title: p['title'] as String? ?? 'Peak',
      body: p['body'] as String? ?? '',
      payload: jsonEncode(p),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.$1,
          channel.$2,
          importance: channel.$3,
          priority: channel.$4,
          category: kind == 'call'
              ? AndroidNotificationCategory.call
              : (kind == 'message'
                    ? AndroidNotificationCategory.message
                    : AndroidNotificationCategory.social),
          // A missed ring shouldn't linger as if it were still ringing.
          timeoutAfter: kind == 'call' ? 60000 : null,
          autoCancel: true,
        ),
      ),
    );
  }

  void _tap(String payload) {
    try {
      onTap?.call(Map<String, dynamic>.from(jsonDecode(payload) as Map));
    } catch (_) {}
  }
}

/// Where tapping a push should go, as a router location.
String pushRoute(Map<String, dynamic> p) {
  switch (p['t']) {
    case 'call':
      final room = p['room'] as String?;
      if (room == null || room.isEmpty) return '/messages';
      return Uri(
        path: '/call/$room',
        queryParameters: {'title': (p['body'] as String?) ?? 'Call'},
      ).toString();
    case 'message':
      return '/messages';
    default:
      return '/feed';
  }
}
