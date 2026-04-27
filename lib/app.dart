import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'providers/household_provider.dart';
import 'providers/mode_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/tonights_pick_provider.dart';
import 'providers/trakt_provider.dart';
import 'providers/upnext_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/splash_screen.dart';
import 'screens/household/setup_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/discover/discover_screen.dart';
import 'screens/library/library_screen.dart';
import 'screens/stats/stats_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/profile/report_issue_screen.dart';
import 'screens/profile/trakt_link_screen.dart';
import 'screens/decide/decide_screen.dart';
import 'screens/predict/reveal_screen.dart';
import 'screens/share/share_confirm_sheet.dart';
import 'screens/title_detail/title_detail_screen.dart';
import 'services/home_widget_service.dart';
import 'services/notification_service.dart';
import 'widgets/liquid_nav_bar.dart';

/// Pure redirect rule for the app router. Extracted so it can be unit-tested
/// without Firebase init. Called on every navigation attempt.
String? computeRouterRedirect({required bool signedIn, required String loc}) {
  final isPublic =
      loc == '/splash' || loc == '/login' || loc.startsWith('/setup');
  if (!signedIn && !isPublic) return '/login';
  if (signedIn && loc == '/login') return '/home';
  return null;
}

final _router = GoRouter(
  initialLocation: '/splash',
  redirect: (_, state) => computeRouterRedirect(
    signedIn: FirebaseAuth.instance.currentUser != null,
    loc: state.matchedLocation,
  ),
  routes: [
    GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(
      path: '/setup',
      builder: (_, state) => SetupScreen(
        inviteCode: state.uri.queryParameters['code'],
      ),
    ),
    GoRoute(
      path: '/title/:mediaType/:tmdbId',
      builder: (_, state) {
        final tmdbId = int.tryParse(state.pathParameters['tmdbId'] ?? '');
        if (tmdbId == null) return const _ErrorScreen('Invalid title link.');
        return TitleDetailScreen(
          mediaType: state.pathParameters['mediaType']!,
          tmdbId: tmdbId,
        );
      },
    ),
    GoRoute(path: '/decide', builder: (_, _) => const DecideScreen()),
    GoRoute(
      path: '/reveal/:mediaType/:tmdbId',
      builder: (_, state) {
        final tmdbId = int.tryParse(state.pathParameters['tmdbId'] ?? '');
        if (tmdbId == null) return const _ErrorScreen('Invalid reveal link.');
        return RevealScreen(
          mediaType: state.pathParameters['mediaType']!,
          tmdbId: tmdbId,
        );
      },
    ),
    ShellRoute(
      builder: (_, _, child) => ScaffoldWithNavBar(child: child),
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/discover', builder: (_, _) => const DiscoverScreen()),
        GoRoute(path: '/library', builder: (_, _) => const LibraryScreen()),
        // Back-compat redirects — old deep links and existing notifications
        // can still point at the retired routes.
        GoRoute(path: '/watchlist', redirect: (_, _) => '/library'),
        GoRoute(path: '/history', redirect: (_, _) => '/library'),
        // Stats moved under Profile (dropped from top-level nav to keep the
        // bar at four destinations). Legacy /stats + /stats/* redirect so
        // old deep links still land.
        GoRoute(path: '/stats', redirect: (_, _) => '/profile/stats'),
        GoRoute(
          path: '/profile',
          builder: (_, _) => const ProfileScreen(),
          routes: [
            GoRoute(path: 'stats', builder: (_, _) => const StatsScreen()),
            GoRoute(path: 'trakt', builder: (_, _) => const TraktLinkScreen()),
            GoRoute(
              path: 'report-issue',
              builder: (_, _) => const ReportIssueScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

class WatchNextApp extends ConsumerWidget {
  const WatchNextApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeDataProvider);
    return MaterialApp.router(
      title: 'WatchNext',
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      routerConfig: _router,
    );
  }
}

class ScaffoldWithNavBar extends ConsumerStatefulWidget {
  final Widget child;
  const ScaffoldWithNavBar({super.key, required this.child});

  @override
  ConsumerState<ScaffoldWithNavBar> createState() => _ScaffoldWithNavBarState();
}

class _ErrorScreen extends StatelessWidget {
  final String message;
  const _ErrorScreen(this.message);
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(message)),
      );
}

class _ScaffoldWithNavBarState extends ConsumerState<ScaffoldWithNavBar> with WidgetsBindingObserver {
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  StreamSubscription<Uri>? _widgetTapSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeSyncTrakt();
      _wireShareListeners();
      _initNotifications();
      _wireWidgetBridge();
      _pushWidgets();
    });
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _widgetTapSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeSyncTrakt();
      _pushWidgets();
    }
  }

  void _wireShareListeners() {
    // Warm-start: app already running when user hits Share.
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
          _handleShared,
          onError: (_) {},
        );
    // Cold-start: app launched by the share intent. Consume once.
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleShared(files);
      ReceiveSharingIntent.instance.reset();
    }).catchError((_) {});
  }

  void _handleShared(List<SharedMediaFile> files) {
    if (files.isEmpty || !mounted) return;
    // Android SEND/text arrives with type == SharedMediaType.text and the
    // URL/text payload on `path`.
    final payload = files
        .where((f) => f.type == SharedMediaType.text || f.type == SharedMediaType.url)
        .map((f) => f.path)
        .firstOrNull;
    if (payload == null || payload.trim().isEmpty) return;
    final future = ref.read(shareParserProvider).parse(payload);
    ShareConfirmSheet.show(context, future: future);
  }

  Future<void> _initNotifications() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null || !mounted) return;
      await NotificationService.init(
        householdId: householdId,
        uid: user.uid,
        context: context,
      );
    } catch (_) {
      // Best-effort — notification failures must not block the app.
    }
  }

  void _wireWidgetBridge() {
    // Cold-start: app launched by tapping a home-screen widget tile.
    HomeWidgetService.initialLaunchUri().then((uri) {
      if (uri == null || !mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _routeWidgetUri(uri);
      });
    }).catchError((_) {});

    // Warm-tap stream: app already running when user taps the widget.
    _widgetTapSub = HomeWidgetService.widgetTapStream().listen(
      (uri) {
        if (!mounted) return;
        _routeWidgetUri(uri);
      },
      onError: (_) {},
    );
  }

  void _routeWidgetUri(Uri u) {
    // Expected shape: wn://title/{mediaType}/{tmdbId}. Drop anything else
    // defensively — no point routing on a malformed URI.
    if (u.host != 'title') return;
    final segs = u.pathSegments;
    if (segs.length < 2) return;
    final mediaType = segs[0];
    final tmdbId = segs[1];
    if (mediaType.isEmpty || tmdbId.isEmpty) return;
    if (mediaType != 'movie' && mediaType != 'tv') return;
    if (int.tryParse(tmdbId) == null) return;
    context.go('/title/$mediaType/$tmdbId');
  }

  Future<void> _pushWidgets() async {
    try {
      final upNext = ref.read(upNextProvider).value ?? const <UpNextEpisode>[];
      final pick = ref.read(tonightsPickProvider).value;
      await HomeWidgetService.pushUpNext(upNext);
      await HomeWidgetService.pushTonightsPick(pick);
    } catch (_) {
      // Best-effort — a widget push failing must never block the app.
    }
  }

  Future<void> _maybeSyncTrakt() async {
    // Best-effort; surfaces nothing to the user unless this is slow on a
    // metered network (it runs behind the UI). Errors are swallowed so a
    // transient Trakt hiccup never blocks navigation.
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final householdId = await ref.read(householdIdProvider.future);
      if (householdId == null) return;
      await ref.read(traktSyncServiceProvider).syncIfStale(
            householdId: householdId,
            uid: user.uid,
          );
    } catch (_) {
      // Intentional: silent failure — see comment above.
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    int selectedIndex = 0;
    if (location.startsWith('/discover')) selectedIndex = 1;
    if (location.startsWith('/library') ||
        location.startsWith('/watchlist') ||
        location.startsWith('/history')) {
      selectedIndex = 2;
    }
    // Stats now lives under Profile as a nested route (/profile/stats); the
    // Profile tab stays highlighted while the user is inside Stats.
    if (location.startsWith('/profile') || location.startsWith('/stats')) {
      selectedIndex = 3;
    }

    return Scaffold(
      body: widget.child,
      // 56px icon-only bar — 4 destinations. Stats was folded into Profile
      // (see CLAUDE.md gotcha "Library tab"). LiquidNavBar keeps the same
      // footprint as the retired M3 NavigationBar but renders a gradient
      // accent "blob" indicator with a soft glow that slides between tabs.
      bottomNavigationBar: LiquidNavBar(
        selectedIndex: selectedIndex,
        destinations: const [
          LiquidNavDestination(icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
          LiquidNavDestination(icon: Icons.explore_outlined, selectedIcon: Icons.explore, label: 'Discover'),
          LiquidNavDestination(icon: Icons.video_library_outlined, selectedIcon: Icons.video_library, label: 'Library'),
          LiquidNavDestination(icon: Icons.person_outline, selectedIcon: Icons.person, label: 'Profile'),
        ],
        onDestinationSelected: (i) {
          const routes = ['/home', '/discover', '/library', '/profile'];
          context.go(routes[i]);
        },
      ),
    );
  }
}
