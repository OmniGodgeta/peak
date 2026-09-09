import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/env.dart';
import 'update_models.dart';

const _channel = MethodChannel('peak/updater');

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Poll the manifest and compare against the running build.
Future<UpdateCheck> checkForUpdate() async {
  if (!_isAndroid || Env.supabaseUrl.isEmpty) return UpdateCheck.none;

  final info = await PackageInfo.fromPlatform();
  final current = int.tryParse(info.buildNumber) ?? 0;

  try {
    final uri = Uri.parse('${Env.supabaseUrl}/functions/v1/app-version');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      client.close();
      return UpdateCheck(
        status: UpdateStatus.upToDate,
        currentVersionCode: current,
      );
    }
    final body = await resp.transform(utf8.decoder).join();
    client.close();

    final json = jsonDecode(body) as Map<String, dynamic>;
    final android = json['android'];
    if (android is! Map<String, dynamic>) {
      return UpdateCheck(
        status: UpdateStatus.upToDate,
        currentVersionCode: current,
      );
    }
    final release = AppRelease.fromJson(android);

    final UpdateStatus status;
    if (current < release.minSupportedVersionCode) {
      status = UpdateStatus.blocked;
    } else if (current < release.versionCode) {
      status = UpdateStatus.available;
    } else {
      status = UpdateStatus.upToDate;
    }
    return UpdateCheck(
      status: status,
      currentVersionCode: current,
      release: release,
    );
  } on Exception {
    return UpdateCheck(
      status: UpdateStatus.upToDate,
      currentVersionCode: current,
    );
  }
}

/// Download the APK (yielding progress), verify its sha256 if one is given,
/// then hand it to the system installer via the native channel.
Stream<DownloadProgress> downloadAndInstall(AppRelease release) async* {
  final url = release.apkUrl;
  if (url == null || url.isEmpty) {
    throw const UpdateException('This release has no download link.');
  }

  // Internal cache dir — matches <cache-path> in res/xml/provider_paths.xml.
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/peak-${release.versionCode}.apk');
  if (await file.exists()) await file.delete();

  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  final resp = await req.close();
  if (resp.statusCode != 200) {
    client.close();
    throw UpdateException('Download failed (${resp.statusCode}).');
  }

  final total = resp.contentLength;
  final sink = file.openWrite();
  final hasher = release.sha256 == null ? null : Sha256().newHashSink();
  var received = 0;
  try {
    await for (final chunk in resp) {
      sink.add(chunk);
      hasher?.add(chunk);
      received += chunk.length;
      yield DownloadProgress(received, total);
    }
  } finally {
    await sink.close();
    client.close();
  }

  if (hasher != null) {
    hasher.close();
    final digest = await hasher.hash();
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (hex != release.sha256) {
      await file.delete();
      throw const UpdateException(
        'The download was corrupted (checksum mismatch). Not installing.',
      );
    }
  }

  final ok = await _channel.invokeMethod<bool>('installApk', {
    'path': file.path,
  });
  if (ok != true) {
    throw const UpdateException('Could not start the installer.');
  }
}

Future<bool?> canInstallPackages() async {
  if (!_isAndroid) return null;
  try {
    return await _channel.invokeMethod<bool>('canInstallPackages');
  } on PlatformException {
    return null;
  }
}

Future<void> openInstallSettings() async {
  if (!_isAndroid) return;
  try {
    await _channel.invokeMethod('openInstallSettings');
  } on PlatformException {
    // best effort
  }
}
