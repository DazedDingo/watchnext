import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import 'screens/auth/login_screen.dart';
import 'screens/household/setup_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/discover/discover_screen.dart';
import 'screens/history/history_screen.dart';
import 'screens/stats/stats_screen.dart';
import 'screens/profile/profile_screen.dart';

final _router = GoRouter(
  initialLocation: '/login',
  routes: [
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    GoRoute(
      path: '/setup',
      builder: (_, state) => SetupScreen(
        inviteCode: state.uri.queryParameters['code'],
      ),
    ),
    ShellRoute(
      builder: (_, __, child) => ScaffoldWithNavBar(child: child),
      routes: [
        GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/discover', builder: (_, __) => const DiscoverScreen()),
        GoRoute(path: '/history', builder: (_, __) => const HistoryScreen()),
        GoRoute(path: '/stats', builder: (_, __) => const StatsScreen()),
        GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      ],
    ),
  ],
);

class WatchNextApp extends StatelessWidget {
  const WatchNextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'WatchNext',
      theme: appDarkTheme,
      darkTheme: appDarkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: _router,
    );
  }
}

class ScaffoldWithNavBar extends ConsumerWidget {
  final Widget child;
  const ScaffoldWithNavBar({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();
    int selectedIndex = 0;
    if (location.startsWith('/discover')) selectedIndex = 1;
    if (location.startsWith('/history')) selectedIndex = 2;
    if (location.startsWith('/stats')) selectedIndex = 3;
    if (location.startsWith('/profile')) selectedIndex = 4;

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Discover'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
        onDestinationSelected: (i) {
          const routes = ['/home', '/discover', '/history', '/stats', '/profile'];
          context.go(routes[i]);
        },
      ),
    );
  }
}
