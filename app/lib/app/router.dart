import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/env.dart';
import '../data/profile_repository.dart';
import '../data/supabase_providers.dart';
import '../features/auth/onboarding_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/settings/account_closing_screen.dart';
import '../updater/update_gate.dart';
import '../updater/update_service.dart';
import '../features/communities/communities_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/media/media_screen.dart';
import '../features/media/video_link_screen.dart';
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

      // A build below minSupportedVersionCode is locked out entirely.
      final blocked =
          ref.read(updateCheckProvider).asData?.value.status ==
          UpdateStatus.blocked;
      if (blocked) {
        return state.matchedLocation == '/update-required'
            ? null
            : '/update-required';
      }
      if (state.matchedLocation == '/update-required') return '/feed';

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

      // Account scheduled for deletion → locked to the closing screen.
      final atClosing = loc == '/account-closing';
      if (profileAsync.asData?.value?.deletionRequestedAt != null) {
        return atClosing ? null : '/account-closing';
      }
      if (atClosing) return '/feed';

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
      GoRoute(
        path: '/account-closing',
        builder: (_, _) => const AccountClosingScreen(),
      ),
      GoRoute(
        path: '/update-required',
        builder: (_, _) => const UpdateRequiredScreen(),
      ),
      // Shared video link: peak.social/v/<id> (and the in-app deep link).
      GoRoute(
        path: '/v/:id',
        builder: (_, state) =>
            VideoLinkScreen(id: state.pathParameters['id'] ?? ''),
      ),
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
              GoRoute(path: '/media', builder: (_, _) => const MediaScreen()),
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
    ref.listen(updateCheckProvider, (_, _) => notifyListeners());
  }
}
