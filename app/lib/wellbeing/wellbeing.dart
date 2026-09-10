import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-device wellbeing preferences. Like [dataLightProvider], this lives on the
/// device, not the account — it's about your relationship with the phone.
class WellbeingSettings {
  const WellbeingSettings({
    this.breakAfterMinutes = 0, // 0 = off
    this.greyscaleAlways = false,
    this.quietStartMin, // minutes since midnight
    this.quietEndMin,
    this.quietGreyscale = true,
    this.quietHideCounts = true,
  });

  final int breakAfterMinutes;
  final bool greyscaleAlways;
  final int? quietStartMin;
  final int? quietEndMin;
  final bool quietGreyscale;
  final bool quietHideCounts;

  bool get hasQuietHours => quietStartMin != null && quietEndMin != null;

  bool get isQuietNow {
    if (!hasQuietHours) return false;
    final now = TimeOfDay.now();
    final m = now.hour * 60 + now.minute;
    final s = quietStartMin!, e = quietEndMin!;
    return s <= e ? (m >= s && m < e) : (m >= s || m < e); // wraps midnight
  }

  bool get greyscaleActive => greyscaleAlways || (isQuietNow && quietGreyscale);
  bool get hideCounts => isQuietNow && quietHideCounts;

  WellbeingSettings copyWith({
    int? breakAfterMinutes,
    bool? greyscaleAlways,
    Object? quietStartMin = _sentinel,
    Object? quietEndMin = _sentinel,
    bool? quietGreyscale,
    bool? quietHideCounts,
  }) => WellbeingSettings(
    breakAfterMinutes: breakAfterMinutes ?? this.breakAfterMinutes,
    greyscaleAlways: greyscaleAlways ?? this.greyscaleAlways,
    quietStartMin: quietStartMin == _sentinel
        ? this.quietStartMin
        : quietStartMin as int?,
    quietEndMin: quietEndMin == _sentinel
        ? this.quietEndMin
        : quietEndMin as int?,
    quietGreyscale: quietGreyscale ?? this.quietGreyscale,
    quietHideCounts: quietHideCounts ?? this.quietHideCounts,
  );

  static const _sentinel = Object();

  String encode() => [
    breakAfterMinutes,
    greyscaleAlways ? 1 : 0,
    quietStartMin ?? -1,
    quietEndMin ?? -1,
    quietGreyscale ? 1 : 0,
    quietHideCounts ? 1 : 0,
  ].join(',');

  static WellbeingSettings decode(String? s) {
    if (s == null) return const WellbeingSettings();
    final p = s.split(',');
    if (p.length < 6) return const WellbeingSettings();
    int? nz(String v) => int.parse(v) < 0 ? null : int.parse(v);
    return WellbeingSettings(
      breakAfterMinutes: int.tryParse(p[0]) ?? 0,
      greyscaleAlways: p[1] == '1',
      quietStartMin: nz(p[2]),
      quietEndMin: nz(p[3]),
      quietGreyscale: p[4] == '1',
      quietHideCounts: p[5] == '1',
    );
  }
}

class Wellbeing extends Notifier<WellbeingSettings> {
  static const _key = 'peak.settings.wellbeing';
  final FlutterSecureStorage _store = const FlutterSecureStorage();

  @override
  WellbeingSettings build() {
    _load();
    return const WellbeingSettings();
  }

  Future<void> _load() async {
    try {
      state = WellbeingSettings.decode(await _store.read(key: _key));
    } catch (_) {}
  }

  Future<void> update(WellbeingSettings next) async {
    state = next;
    try {
      await _store.write(key: _key, value: next.encode());
    } catch (_) {}
  }
}

final wellbeingProvider = NotifierProvider<Wellbeing, WellbeingSettings>(
  Wellbeing.new,
);

/// Minutes of continuous foreground use in the current session. Resets when the
/// app has been backgrounded for more than three minutes.
class SessionClock extends Notifier<int> {
  Timer? _timer;
  DateTime _start = DateTime.now();
  _LifecycleWatch? _watch;

  @override
  int build() {
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      state = DateTime.now().difference(_start).inMinutes;
    });
    _watch = _LifecycleWatch(onLongResume: reset);
    WidgetsBinding.instance.addObserver(_watch!);
    ref.onDispose(() {
      _timer?.cancel();
      if (_watch != null) WidgetsBinding.instance.removeObserver(_watch!);
    });
    return 0;
  }

  void reset() {
    _start = DateTime.now();
    state = 0;
  }
}

class _LifecycleWatch extends WidgetsBindingObserver {
  _LifecycleWatch({required this.onLongResume});
  final VoidCallback onLongResume;
  DateTime? _pausedAt;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final gap = _pausedAt == null
          ? Duration.zero
          : DateTime.now().difference(_pausedAt!);
      if (gap > const Duration(minutes: 3)) onLongResume();
      _pausedAt = null;
    }
  }
}

final sessionClockProvider = NotifierProvider<SessionClock, int>(
  SessionClock.new,
);
