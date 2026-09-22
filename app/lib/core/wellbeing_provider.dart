import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Represents the current wellbeing state of the user.
enum WellbeingStatus { normal, warning, breakRequired }

/// A provider that tracks user engagement to detect "doomscrolling".
/// It monitors continuous active time and scrolling velocity.
class WellbeingNotifier extends StateNotifier<WellbeingStatus> {
  WellbeingNotifier() : super(WellbeingStatus.normal);

  DateTime? _activityStartTime;
  int _scrollCount = 0;
  Timer? _timer;

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
    
    // Logic for detecting doomscrolling
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

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final wellbeingProvider = StateNotifierProvider<WellbeingNotifier, WellbeingStatus>((ref) {
  return WellbeingNotifier();
});

/// A provider to track whether the user has enabled wellbeing reminders.
final wellbeingSettingsProvider = StateProvider<bool>((ref) => true);
