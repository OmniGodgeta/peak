import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/env.dart';
import '../data/profile_repository.dart';
import '../data/supabase_providers.dart';
import '../features/auth/onboarding_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/communities/communities_screen.dart';
import '../features/discovery/discovery_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/home/home_shell.dart';
import '../features/messaging/messaging_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/settings/not_configured_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/feed',
    refreshListenable: _AuthRefresh(ref),
    redirect: (context, state) {
      if (!Env.isConfigured) {
        return state.matchedLocation == '/not-configured'
            ? null
            : '/not-configured';
      }

      final signedIn = ref.read(currentUserProvider) != null;
      final loc = state.matchedLocation;
      final atAuth = loc == '/sign-in';
      final atOnboarding = loc == '/onboarding';

      if (!signedIn) return atAuth ? null : '/sign-in';

      // Signed in but no profile row yet → onboarding.
      final profileAsync = ref.read(myProfileProvider);
      if (!profileAsync.isLoading && profileAsync.asData?.value == null) {
        return atOnboarding ? null : '/onboarding';
      }
      if (atAuth || atOnboarding) return '/feed';
      return null;
    },
    routes: [
      GoRoute(
        path: '/not-configured',
        builder: (_, _) => const NotConfiguredScreen(),
      ),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/feed', builder: (_, _) => const FeedScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/messages',
                builder: (_, _) => const MessagingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/communities',
                builder: (_, _) => const CommunitiesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/discover',
                builder: (_, _) => const DiscoveryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/me', builder: (_, _) => const ProfileScreen()),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Bridges Riverpod auth/profile changes to go_router's refresh.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authStateProvider, (_, _) => notifyListeners());
    ref.listen(myProfileProvider, (_, _) => notifyListeners());
  }
}
