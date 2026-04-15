import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/app.dart';

void main() {
  group('computeRouterRedirect', () {
    test('unauthed user on a protected route is sent to /login', () {
      expect(computeRouterRedirect(signedIn: false, loc: '/home'), '/login');
      expect(
          computeRouterRedirect(signedIn: false, loc: '/discover'), '/login');
      expect(computeRouterRedirect(signedIn: false, loc: '/history'), '/login');
      expect(computeRouterRedirect(signedIn: false, loc: '/profile'), '/login');
      expect(
          computeRouterRedirect(signedIn: false, loc: '/watchlist'), '/login');
      expect(
          computeRouterRedirect(
              signedIn: false, loc: '/title/movie/42'),
          '/login');
      expect(
          computeRouterRedirect(
              signedIn: false, loc: '/reveal/movie/42'),
          '/login');
    });

    test('unauthed user on /login stays on /login', () {
      expect(computeRouterRedirect(signedIn: false, loc: '/login'), isNull);
    });

    test('unauthed user on /setup stays (setup is public for deep-links)',
        () {
      expect(computeRouterRedirect(signedIn: false, loc: '/setup'), isNull);
      expect(
          computeRouterRedirect(signedIn: false, loc: '/setup?code=abc'),
          isNull);
    });

    test('signed-in user on /login bounces to /home', () {
      expect(computeRouterRedirect(signedIn: true, loc: '/login'), '/home');
    });

    test('signed-in user on any authed route passes through', () {
      expect(computeRouterRedirect(signedIn: true, loc: '/home'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/discover'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/history'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/profile'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/watchlist'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/decide'), isNull);
      expect(
          computeRouterRedirect(signedIn: true, loc: '/title/movie/42'),
          isNull);
      expect(
          computeRouterRedirect(signedIn: true, loc: '/reveal/tv/1399'),
          isNull);
    });

    test('signed-in user on /setup can still access setup', () {
      expect(computeRouterRedirect(signedIn: true, loc: '/setup'), isNull);
    });
  });
}
