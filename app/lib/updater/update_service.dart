import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'update_backend_stub.dart'
    if (dart.library.io) 'update_backend_io.dart'
    as backend;
import 'update_models.dart';

export 'update_models.dart';

/// Thin facade over the platform updater backend (real on Android, no-op
/// elsewhere). The backend is picked at compile time by conditional import.
class UpdateService {
  Future<UpdateCheck> check() => backend.checkForUpdate();

  Stream<DownloadProgress> downloadAndInstall(AppRelease release) =>
      backend.downloadAndInstall(release);

  Future<bool?> canInstallPackages() => backend.canInstallPackages();

  Future<void> openInstallSettings() => backend.openInstallSettings();
}

final updateServiceProvider = Provider<UpdateService>((ref) => UpdateService());

/// Checked once per app launch; the gate + banner watch this. Invalidate it to
/// re-check ("Check for updates" in settings).
final updateCheckProvider = FutureProvider<UpdateCheck>((ref) async {
  return ref.watch(updateServiceProvider).check();
});

/// "1.2.3 (45)" — the running build, for the settings screen.
final appVersionLabelProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.buildNumber.isEmpty
      ? info.version
      : '${info.version} (${info.buildNumber})';
});
