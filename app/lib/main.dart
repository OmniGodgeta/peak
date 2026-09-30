import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/env.dart';
import 'push/push_service.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Env.isConfigured) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      // Local `supabase start` still issues a legacy anon JWT; publishable keys
      // come with the hosted project in Phase 0.
      // ignore: deprecated_member_use
      anonKey: Env.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  // Started headless by the UnifiedPush connector to deliver a push while
  // the app is closed: show it, don't build any UI.
  if (args.contains('--unifiedpush-bg')) {
    await PushService.instance.startBackground();
    return;
  }

  runApp(const ProviderScope(child: PeakApp()));
  await PushService.instance.start();
}
