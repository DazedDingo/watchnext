import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import 'rating_pusher.dart';

/// Trakt.tv OAuth + REST client.
///
/// The client_secret lives only in Cloud Functions. The client_id is **not**
/// a secret — Trakt requires it as the `trakt-api-key` header on every
/// request, so it ships in the APK. Only the three calls that require the
/// secret (token exchange, refresh, revoke) are proxied via callables.
class TraktService implements RatingPusher {
  TraktService({
    http.Client? client,
    FirebaseFirestore? db,
    FirebaseFunctions? functions,
  })  : _client = client ?? http.Client(),
        _db = db ?? FirebaseFirestore.instance,
        _functionsField = functions;

  final http.Client _client;
  final FirebaseFirestore _db;

  // Lazily resolved so unit tests that only exercise the HTTP surface don't
  // need a real Firebase app behind FirebaseFunctions.instance.
  // Callables live in europe-west2 (co-located with Firestore in London).
  FirebaseFunctions? _functionsField;
  FirebaseFunctions get _functions =>
      _functionsField ??= FirebaseFunctions.instanceFor(region: 'europe-west2');

  static const _api = 'https://api.trakt.tv';
  static const _apiVersion = '2';
  static const _redirectUri = 'com.household.watchnext://trakt-callback';
  static const _callbackScheme = 'com.household.watchnext';

  // Client ID only — public header value. Secret is server-side.
  static const String _clientId = String.fromEnvironment('TRAKT_CLIENT_ID');

  static bool get isConfigured => _clientId.isNotEmpty;

  String _randomState() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random.secure();
    return List.generate(32, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Future<String> openBrowserAuth() async {
    if (!isConfigured) {
      throw StateError('TRAKT_CLIENT_ID missing. See env.example.json.');
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

  /// Exchange auth code for tokens via Cloud Function, persist onto member doc.
  Future<void> exchangeCode({
    required String code,
    required String householdId,
    required String uid,
  }) async {
    final res = await _functions.httpsCallable('traktExchangeCode').call({
      'code': code,
      'redirectUri': _redirectUri,
    });
    final tokens = _TraktTokens.fromCallable(res.data as Map);

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

  /// Sets the user's Trakt history-scope flag, which the sync service reads
  /// to decide how to stamp `context` on imported ratings. Valid values:
  /// `shared` (with partner), `personal` (solo), `mixed` (don't stamp).
  Future<void> setHistoryScope({
    required String householdId,
    required String uid,
    required String scope,
  }) async {
    await _db.doc('households/$householdId/members/$uid').set({
      'trakt_history_scope': scope,
    }, SetOptions(merge: true));
  }

  /// Unlink: revoke via Cloud Function, then clear our copy.
  Future<void> unlink({required String householdId, required String uid}) async {
    final memberRef = _db.doc('households/$householdId/members/$uid');
    final snap = await memberRef.get();
    final token = snap.data()?['trakt_access_token'] as String?;
    if (token != null && token.isNotEmpty) {
      try {
        await _functions.httpsCallable('traktRevoke').call({'token': token});
      } catch (_) {
        // Best-effort — still clear local state even if Trakt revoke fails.
      }
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

  /// Returns a live access token, refreshing via Cloud Function if the current
  /// one is within 5 minutes of expiry.
  @override
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

    final res = await _functions.httpsCallable('traktRefreshToken').call({
      'refreshToken': refresh,
      'redirectUri': _redirectUri,
    });
    final tokens = _TraktTokens.fromCallable(res.data as Map);
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

  Future<List<Map<String, dynamic>>> fetchHistory({
    required String token,
    required String type,
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
    required String type,
  }) async {
    final res = await _getJson('/sync/ratings/$type', token);
    return (res as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<void> pushRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
    required int stars,
  }) async {
    final rating10 = (stars * 2).clamp(1, 10);
    final body = {
      _syncKeyFor(level): [
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

  @override
  Future<void> removeRating({
    required String token,
    required String level,
    required Map<String, dynamic> traktRef,
  }) async {
    final body = {
      _syncKeyFor(level): [traktRef],
    };
    final res = await _client.post(
      Uri.parse('$_api/sync/ratings/remove'),
      headers: _headers(token),
      body: json.encode(body),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Trakt remove rating ${res.statusCode}: ${res.body}');
    }
  }

  String _syncKeyFor(String level) => switch (level) {
        'movie' => 'movies',
        'show' => 'shows',
        'season' => 'seasons',
        'episode' => 'episodes',
        _ => throw ArgumentError('Bad level: $level'),
      };

  Future<List<Map<String, dynamic>>> fetchTrending(String token, {required String type}) async {
    final res = await _getJson('/$type/trending', token, query: {'limit': '30'});
    return (res as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> fetchRecommendations(String token, {required String type}) async {
    final res = await _getJson('/recommendations/$type', token);
    return (res as List).cast<Map<String, dynamic>>();
  }

  static int mapTraktToStars(int trakt) {
    if (trakt <= 0) return 0;
    return ((trakt + 1) ~/ 2).clamp(1, 5);
  }

  Future<User?> currentFirebaseUser() async => FirebaseAuth.instance.currentUser;

  void dispose() => _client.close();
}

class _TraktTokens {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  _TraktTokens({required this.accessToken, required this.refreshToken, required this.expiresAt});

  factory _TraktTokens.fromCallable(Map data) {
    final expiresAtSecs = (data['expires_at_seconds'] as num?)?.toInt();
    final expiresAt = expiresAtSecs != null
        ? DateTime.fromMillisecondsSinceEpoch(expiresAtSecs * 1000, isUtc: true)
        : DateTime.now().toUtc().add(const Duration(days: 90));
    return _TraktTokens(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String,
      expiresAt: expiresAt,
    );
  }
}
