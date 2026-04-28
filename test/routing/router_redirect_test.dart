import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/app.dart';

void main() {
  group('computeRouterRedirect', () {
    test('unauthed user on a protected route is sent to /login', () {
      expect(computeRouterRedirect(signedIn: false, loc: '/home'), '/login');
      expect(
          computeRouterRedirect(signedIn: false, loc: '/discover'), '/login');
      expect(computeRouterRedirect(signedIn: false, loc: '/library'), '/login');
      expect(computeRouterRedirect(signedIn: false, loc: '/profile'), '/login');
      // Legacy routes still redirect to /login when signed out — the
      // back-compat redirect to /library only fires for signed-in users.
      expect(computeRouterRedirect(signedIn: false, loc: '/history'), '/login');
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
      expect(computeRouterRedirect(signedIn: true, loc: '/library'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/profile'), isNull);
      // Legacy paths pass the auth redirect; GoRoute redirect inside the
      // shell forwards to /library for signed-in users.
      expect(computeRouterRedirect(signedIn: true, loc: '/history'), isNull);
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

    test('/splash is public — unauthed users stay there to watch the intro',
        () {
      expect(computeRouterRedirect(signedIn: false, loc: '/splash'), isNull);
      expect(computeRouterRedirect(signedIn: true, loc: '/splash'), isNull);
    });

    group('home-screen widget deep links (wn:// scheme)', () {
      // Widget tap PendingIntents fire `wn://title/{mediaType}/{tmdbId}`.
      // On cold start Flutter forwards the URI as the initial route; the
      // redirect translates it into a real internal path.

      test('wn://title/tv/{id} → /title/tv/{id} for a signed-in user', () {
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://title/tv/1399'),
          '/title/tv/1399',
        );
      });

      test('wn://title/movie/{id} → /title/movie/{id} for a signed-in user',
          () {
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://title/movie/42'),
          '/title/movie/42',
        );
      });

      test('wn:// link from an unauth user → /login', () {
        expect(
          computeRouterRedirect(signedIn: false, loc: 'wn://title/tv/1399'),
          '/login',
        );
      });

      test('malformed wn:// URI falls back to /home for signed-in users',
          () {
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://garbage'),
          '/home',
        );
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://title/tv'),
          '/home',
        );
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://title/film/abc'),
          '/home',
        );
      });

      test('malformed wn:// URI falls back to /login for unauth users', () {
        expect(
          computeRouterRedirect(signedIn: false, loc: 'wn://garbage'),
          '/login',
        );
      });

      test('wn://title/tv/{id}?season=3&episode=4 preserves season + episode',
          () {
        expect(
          computeRouterRedirect(
              signedIn: true, loc: 'wn://title/tv/1399?season=3&episode=4'),
          '/title/tv/1399?season=3&episode=4',
        );
      });

      test('non-season/episode query params are stripped', () {
        expect(
          computeRouterRedirect(
              signedIn: true,
              loc: 'wn://title/tv/1399?season=3&episode=4&foo=bar'),
          '/title/tv/1399?season=3&episode=4',
        );
      });

      test('wn://title/tv/{id} without query params still translates plainly',
          () {
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://title/tv/1399'),
          '/title/tv/1399',
        );
      });

      test('wn://refresh resolves to /home for signed-in users', () {
        // Refresh tile fires `wn://refresh` — the bridge handles the
        // re-fetch logic in Dart; the redirect just needs to land the
        // user somewhere valid (defence in depth in case Flutter's
        // engine routes the URI before the bridge has a chance to).
        expect(
          computeRouterRedirect(signedIn: true, loc: 'wn://refresh'),
          '/home',
        );
        expect(
          computeRouterRedirect(signedIn: false, loc: 'wn://refresh'),
          '/login',
        );
      });
    });
  });
}
