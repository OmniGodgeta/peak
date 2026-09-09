import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-device display preferences. Kept on the device (not the account) — this
/// is about the connection in your hand, not who you are.
class DataLight extends Notifier<bool> {
  static const _key = 'peak.settings.data_light';
  final FlutterSecureStorage _store = const FlutterSecureStorage();

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    try {
      if (await _store.read(key: _key) == 'true') state = true;
    } catch (_) {
      // storage unavailable (private window etc.) — default stays off
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await _store.write(key: _key, value: '$value');
    } catch (_) {}
  }
}

/// When true, images don't auto-download — the reader taps to load each one.
final dataLightProvider = NotifierProvider<DataLight, bool>(DataLight.new);
