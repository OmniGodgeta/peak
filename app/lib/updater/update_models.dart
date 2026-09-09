/// One row of the `app-version` manifest (the Android entry).
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.notes,
    required this.minSupportedVersionCode,
  });

  final String versionName;
  final int versionCode;
  final String? apkUrl;
  final String? sha256;
  final String? notes;
  final int minSupportedVersionCode;

  factory AppRelease.fromJson(Map<String, dynamic> m) => AppRelease(
    versionName: (m['versionName'] as String?) ?? '',
    versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
    apkUrl: m['apkUrl'] as String?,
    sha256: (m['sha256'] as String?)?.toLowerCase(),
    notes: m['notes'] as String?,
    minSupportedVersionCode:
        (m['minSupportedVersionCode'] as num?)?.toInt() ?? 0,
  );
}

enum UpdateStatus {
  /// Running the latest (or newer), or checks don't apply on this build.
  upToDate,

  /// A newer version exists — nudge, but the app still works.
  available,

  /// Below `minSupportedVersionCode` — block until updated.
  blocked,
}

class UpdateCheck {
  const UpdateCheck({
    required this.status,
    required this.currentVersionCode,
    this.release,
  });

  final UpdateStatus status;
  final int currentVersionCode;
  final AppRelease? release;

  static const none = UpdateCheck(
    status: UpdateStatus.upToDate,
    currentVersionCode: 0,
  );
}

/// Progress of an in-progress update download.
class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;
  final int total;
  double? get fraction => total > 0 ? received / total : null;
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}
