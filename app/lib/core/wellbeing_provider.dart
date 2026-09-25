import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Represents the current wellbeing state of the user.
enum WellbeingStatus { normal, warning, breakRequired }

/// A provider that tracks user engagement to detect "doomscrolling".
/// It monitors continuous active time and scrolling velocity.
class WellbeingNotifier extends Notifier<WellbeingStatus> {
  DateTime? _activityStartTime;
  int _scrollCount = 0;
  Timer? _timer;

  @override
  WellbeingStatus build() {
    ref.onDispose(() => _timer?.cancel());
    return WellbeingStatus.normal;
  }

  void recordActivity() {
    if (_activityStartTime == null) {
      _activityStartTime = DateTime.now();
      _startTimer();
    }
  }

  void recordScroll() {
    _scrollCount++;
    if (_scrollCount > 50) { // High velocity threshold
      _checkWellbeing();
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _checkWellbeing();
    });
  }

  void _checkWellbeing() {
    if (_activityStartTime == null) return;

    final duration = DateTime.now().difference(_activityStartTime!);
    
    if (duration.inMinutes >= 30 && _scrollCount > 100) {
      state = WellbeingStatus.breakRequired;
    } else if (duration.inMinutes >= 15) {
      state = WellbeingStatus.warning;
    } else {
      state = WellbeingStatus.normal;
    }
  }

  void reset() {
    _activityStartTime = null;
    _scrollCount = 0;
    _timer?.cancel();
    state = WellbeingStatus.normal;
  }

}

final wellbeingProvider = NotifierProvider<WellbeingNotifier, WellbeingStatus>(
  WellbeingNotifier.new,
);

final wellbeingSettingsProvider = Provider<bool>((ref) => true);

