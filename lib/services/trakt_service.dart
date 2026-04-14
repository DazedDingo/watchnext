import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// Trakt.tv OAuth + REST client.
///
/// Auth flow (per trakt.tv/docs/api/authentication#device-auth — using
/// authorization code because we have a usable redirect scheme on Android):
///   1. openBrowserAuth() → launches Trakt consent → returns auth code.
///   2. exchangeCode(code) → posts to /oauth/token → stores access + refresh
///      tokens on the member doc.
///   3. refreshIfNeeded() → proactive refresh before API calls.
///
/// The access token is scoped to one user. Household member-doc storage means
/// the partner's token is invisible to the other user (Firestore rules allow
/// members to read siblings' docs by design for read-only fields, but tokens
/// are only ever *written* by the owner — see callers).
class TraktService {
  TraktService({http.Client? client, FirebaseFirestore? db})
      : _client = client ?? http.Client(),
        _db = db ?? FirebaseFirestore.instance;

  final http.Client _client;
  final FirebaseFirestore _db;

  static const _api = 'https://api.trakt.tv';
  static const _apiVersion = '2';
  static const _redirectUri = 'com.household.watchnext://trakt-callback';
  static const _callbackScheme = 'com.household.watchnext';

  // Client ID + secret injected at build time. Both ship inside the APK — this
  // is acceptable for a personal two-user app but should NOT be a pattern for
  // public distribution. Trakt's public client flow is OAuth 2.0 code grant.
  static const String _clientId = String.fromEnvironment('TRAKT_CLIENT_ID');
  static const String _clientSecret = String.fromEnvironment('TRAKT_CLIENT_SECRET');

  static bool get isConfigured => _clientId.isNotEmpty && _clientSecret.isNotEmpty;

  String _randomState() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random.secure();
    return List.generate(32, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Step 1: launch Trakt authorize URL in a custom tab. Returns an auth code.
  /// Throws on user cancel or CSRF state mismatch.
  Future<String> openBrowserAuth() async {
    if (!isConfigured) {
      throw StateError('TRAKT_CLIENT_ID/SECRET missing. See env.example.json.');
    }
    final state = _randomState();
    final authUrl = Uri.https('trakt.tv', '/oauth/authorize', {
      'response_type': 'code',
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'state': state,
    }).toString();

    final result = await FlutterWebAuth2.authenticate(
      url: authUrl,
      callbackUrlScheme: _callbackScheme,
    );
    final parsed = Uri.parse(result);

    final returnedState = parsed.queryParameters['state'];
    if (returnedState != state) {
      throw StateError('OAuth state mismatch — possible CSRF, aborting.');
    }
    final code = parsed.queryParameters['code'];
    if (code == null || code.isEmpty) {
      final err = parsed.queryParameters['error'] ?? 'no code returned';
      throw StateError('Trakt auth failed: $err');
    }
    return code;
  }

  /// Step 2: exchange auth code for tokens, persist onto the member doc.
  Future<void> exchangeCode({
    required String code,
    required String householdId,
    required String uid,
  }) async {
    final res = await _client.post(
      Uri.parse('$_api/oauth/token'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'code': code,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'redirect_uri': _redirectUri,
        'grant_type': 'authorization_code',
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Trakt token exchange ${res.statusCode}: ${res.body}');
    }
    final body = json.decode(res.body) as Map<String, dynamic>;
    final tokens = _TraktTokens.fromJson(body);

    // Fetch the Trakt user slug so we can attribute history rows correctly.
    final settings = await _getJson('/users/settings', tokens.accessToken);
    final traktUserId = (settings['user']?['ids']?['slug'] ?? settings['user']?['username']) as String?;

    await _db.doc('households/$householdId/members/$uid').set({
      'trakt_access_token': tokens.accessToken,
      'trakt_refresh_token': tokens.refreshToken,
      'trakt_token_expires_at': Timestamp.fromDate(tokens.expiresAt),
      'trakt_user_id': traktUserId,
      'trakt_linked_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Unlink: revoke on Trakt's side, then clear our copy.
  Future<void> unlink({required String householdId, required String uid}) async {
    final memberRef = _db.doc('households/$householdId/members/$uid');
    final snap = await memberRef.get();
    final token = snap.data()?['trakt_access_token'] as String?;
    if (token != null && token.isNotEmpty) {
      // Best-effort revoke; ignore failures (we'll still clear our copy).
      try {
        await _client.post(
          Uri.parse('$_api/oauth/revoke'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'token': token,
            'client_id': _clientId,
            'client_secret': _clientSecret,
          }),
        );
      } catch (_) {}
    }
    await memberRef.set({
      'trakt_access_token': null,
      'trakt_refresh_token': null,
      'trakt_token_expires_at': null,
      'trakt_user_id': null,
      'trakt_linked_at': null,
      'last_trakt_sync': null,
    }, SetOptions(merge: true));
  }

  /// Returns a live access token, refreshing via stored refresh token if the
  /// current one is within 5 minutes of expiry.
  Future<String> getLiveAccessToken({required String householdId, required String uid}) async {
    final memberRef = _db.doc('households/$householdId/members/$uid');
    final snap = await memberRef.get();
    final data = snap.data();
    if (data == null) throw StateError('Member doc missing.');
    final token = data['trakt_access_token'] as String?;
    final refresh = data['trakt_refresh_token'] as String?;
    final expiresAt = (data['trakt_token_expires_at'] as Timestamp?)?.toDate();
    if (token == null || refresh == null) throw StateError('Trakt not linked.');

    final soon = DateTime.now().add(const Duration(minutes: 5));
    if (expiresAt != null && expiresAt.isAfter(soon)) return token;

    // Refresh.
    final res = await _client.post(
      Uri.parse('$_api/oauth/token'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'refresh_token': refresh,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'redirect_uri': _redirectUri,
        'grant_type': 'refresh_token',
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Trakt refresh ${res.statusCode}: ${res.body}');
    }
    final tokens = _TraktTokens.fromJson(json.decode(res.body) as Map<String, dynamic>);
    await memberRef.set({
      'trakt_access_token': tokens.accessToken,
      'trakt_refresh_token': tokens.refreshToken,
      'trakt_token_expires_at': Timestamp.fromDate(tokens.expiresAt),
    }, SetOptions(merge: true));
    return tokens.accessToken;
  }

  Map<String, String> _headers(String token) => {
        'Content-Type': 'application/json',
        'trakt-api-version': _apiVersion,
        'trakt-api-key': _clientId,
        'Authorization': 'Bearer $token',
      };

  Future<dynamic> _getJson(String path, String token, {Map<String, String>? query}) async {
    final uri = Uri.parse('$_api$path').replace(queryParameters: {
      'extended': 'full',
      ...?query,
    });
    final res = await _client.get(uri, headers: _headers(token));
    if (res.statusCode != 200) {
      throw Exception('Trakt GET $path ${res.statusCode}: ${res.body}');
    }
    return json.decode(res.body);
  }

  /// Paginated history pull. `type` is 'movies' or 'shows' (shows returns
  /// per-episode rows). Returns the accumulated list.
  Future<List<Map<String, dynamic>>> fetchHistory({
    required String token,
    required String type, // 'movies' | 'shows'
    DateTime? startAt,
    int pageLimit = 100,
  }) async {
    final out = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final res = await _client.get(
        Uri.parse('$_api/sync/history/$type').replace(queryParameters: {
          'extended': 'full',
          'page': '$page',
          'limit': '$pageLimit',
          if (startAt != null) 'start_at': startAt.toUtc().toIso8601String(),
        }),
        headers: _headers(token),
      );
      if (res.statusCode != 200) {
        throw Exception('Trakt history $type page $page ${res.statusCode}: ${res.body}');
      }
      final rows = (json.decode(res.body) as List).cast<Map<String, dynamic>>();
      out.addAll(rows);
      final totalPages = int.tryParse(res.headers['x-pagination-page-count'] ?? '1') ?? 1;
      if (page >= totalPages || rows.isEmpty) break;
      page += 1;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> fetchRatings({
    required String token,
    required String type, // 'movies' | 'shows' | 'seasons' | 'episodes'
  }) async {
    final res = await _getJson('/sync/ratings/$type', token);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Push a single WatchNext rating to Trakt. Stars 1-5 map to 2-10 (×2).
  Future<void> pushRating({
    required String token,
    required String level, // 'movie' | 'show' | 'season' | 'episode'
    required Map<String, dynamic> traktRef, // {"ids": {"trakt": 1234}} or with season/number
    required int stars,
  }) async {
    final rating10 = (stars * 2).clamp(1, 10);
    final key = switch (level) {
      'movie' => 'movies',
      'show' => 'shows',
      'season' => 'seasons',
      'episode' => 'episodes',
      _ => throw ArgumentError('Bad level: $level'),
    };
    final body = {
      key: [
        {
          ...traktRef,
          'rating': rating10,
          'rated_at': DateTime.now().toUtc().toIso8601String(),
        },
      ],
    };
    final res = await _client.post(
      Uri.parse('$_api/sync/ratings'),
      headers: _headers(token),
      body: json.encode(body),
    );
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw Exception('Trakt push rating ${res.statusCode}: ${res.body}');
    }
  }

  /// Convenience for trending feeds (Phase 7 Discover surfaces).
  Future<List<Map<String, dynamic>>> fetchTrending(String token, {required String type}) async {
    final res = await _getJson('/$type/trending', token, query: {'limit': '30'});
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Convenience for the current user's Trakt-curated recommendations.
  Future<List<Map<String, dynamic>>> fetchRecommendations(String token, {required String type}) async {
    final res = await _getJson('/recommendations/$type', token);
    return (res as List).cast<Map<String, dynamic>>();
  }

  /// Trakt → WatchNext star mapping. Trakt is 1-10; we halve (ceiling).
  static int mapTraktToStars(int trakt) {
    if (trakt <= 0) return 0;
    return ((trakt + 1) ~/ 2).clamp(1, 5);
  }

  /// Used by the account link UI to confirm we're talking to the right person.
  Future<User?> currentFirebaseUser() async => FirebaseAuth.instance.currentUser;

  void dispose() => _client.close();
}

class _TraktTokens {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  _TraktTokens({required this.accessToken, required this.refreshToken, required this.expiresAt});

  factory _TraktTokens.fromJson(Map<String, dynamic> j) {
    final createdAt = (j['created_at'] as num?)?.toInt() ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final expiresIn = (j['expires_in'] as num?)?.toInt() ?? 7776000; // 90d default
    return _TraktTokens(
      accessToken: j['access_token'] as String,
      refreshToken: j['refresh_token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch((createdAt + expiresIn) * 1000, isUtc: true),
    );
  }
}
