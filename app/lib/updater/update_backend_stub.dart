import 'update_models.dart';

/// Non-Android / web: the in-app updater doesn't apply.
Future<UpdateCheck> checkForUpdate() async => UpdateCheck.none;

Stream<DownloadProgress> downloadAndInstall(AppRelease release) async* {
  throw const UpdateException('In-app updates are only available on Android.');
}

Future<bool?> canInstallPackages() async => null;

Future<void> openInstallSettings() async {}
