import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Walks lib/ and returns the set of collection/doc names the client
/// reads or writes under `/households/{hid}/<name>`. This is a static
/// source scan — no runtime Firestore involved.
Set<String> _discoverHouseholdChildPaths(Directory libDir) {
  // Matches both `.collection('households/$hid/foo')` and
  // `.doc('households/$hid/foo/...')` regardless of interpolation style.
  final rx = RegExp(r"households/\$\{?[A-Za-z_][A-Za-z0-9_.]*\}?/([A-Za-z_]+)");
  final found = <String>{};
  for (final f in libDir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    for (final m in rx.allMatches(f.readAsStringSync())) {
      found.add(m.group(1)!);
    }
  }
  return found;
}

/// Lightweight sanity checks over firestore.rules to catch the class of bug
/// we hit pre-QA: a collection the client reads/writes, but no matching
/// rule (which silently default-denies). This is a text-level check, not a
/// true rules emulator — but it's fast and runs in CI. For full coverage
/// use @firebase/rules-unit-testing with the Firestore emulator.
void main() {
  // Rules file is sibling of pubspec.yaml; find the repo root dynamically
  // so the test runs from any working directory.
  File rulesFile() {
    for (var dir = Directory.current;
        dir.path != dir.parent.path;
        dir = dir.parent) {
      final f = File('${dir.path}/firestore.rules');
      if (f.existsSync()) return f;
    }
    throw StateError('firestore.rules not found');
  }

  late String rules;
  setUpAll(() {
    rules = rulesFile().readAsStringSync();
  });

  group('firestore.rules — required paths present', () {
    // Every collection path the Flutter client reads or writes MUST have a
    // `match` rule under /households/{householdId}. Missing = default-deny.
    const requiredHouseholdCollections = {
      'members',
      'watchEntries',
      'ratings',
      'watchlist', // regression guard — missing here blocked the entire feature
      'predictions',
      'recommendations',
      'decisionHistory',
      'conciergeHistory',
    };

    for (final name in requiredHouseholdCollections) {
      test('has a rule for /households/{id}/$name', () {
        expect(
          rules.contains(RegExp('match\\s+/$name/\\{')),
          isTrue,
          reason:
              'Missing `match /$name/{id}` under /households/{householdId}. '
              'The client hits this collection — without a rule it will be '
              'default-denied and the feature breaks silently.',
        );
      });
    }

    test('has a rule for household-scoped tasteProfile (even-segment path)',
        () {
      expect(rules.contains(RegExp(r'match\s+/tasteProfile/\{')), isTrue);
    });

    test('has a rule for household-scoped gamification (even-segment path)',
        () {
      expect(rules.contains(RegExp(r'match\s+/gamification/\{')), isTrue);
    });

    test('has a rule for /users/{uid}', () {
      expect(rules.contains(RegExp(r'match\s+/users/\{uid\}')), isTrue);
    });

    test('has a rule for /invites/{token}', () {
      expect(rules.contains(RegExp(r'match\s+/invites/\{token\}')), isTrue);
    });

    test('has a read rule for /redditMentions/{id}', () {
      expect(rules.contains(RegExp(r'match\s+/redditMentions/\{')), isTrue);
    });

    test(
        '/redditMentions is server-write-only (no public write endpoint for '
        'Reddit-sourced candidates)', () {
      // Block begins at `match /redditMentions/{id}` and ends at first `}` on
      // its own line. Inside that block, write must resolve to false.
      final m = RegExp(
        r'match\s+/redditMentions/\{[^}]+\}\s*\{[^{}]*\}',
        multiLine: true,
      ).firstMatch(rules);
      expect(m, isNotNull, reason: 'redditMentions block not parseable');
      expect(m!.group(0)!, contains('allow write: if false'));
    });

    test('households are delete-forbidden', () {
      expect(rules.contains(RegExp(r'allow\s+delete:\s*if\s+false')), isTrue);
    });
  });

  group('firestore.rules — membership predicate', () {
    test('isMember(householdId) function is defined', () {
      expect(rules.contains(RegExp(r'function\s+isMember\(householdId\)')),
          isTrue);
      expect(rules, contains('request.auth.uid'));
      expect(rules.contains(RegExp(r'members/\$\(request\.auth\.uid\)')),
          isTrue);
    });

    test('household update requires membership', () {
      // The household root must only allow update from existing members.
      expect(rules.contains(RegExp(r'allow\s+update:\s*if\s+isMember')),
          isTrue);
    });
  });

  group('firestore.rules — discovered client paths', () {
    // Regression guard for the exact class of bug that caused PERMISSION_DENIED
    // on Stats and Title Detail: a collection gets added to the client, no
    // rule is added for it, and it silently default-denies. The hardcoded
    // list above doesn't protect against NEW collections — this one does.
    test('every households/{hid}/<child> path hit by lib/ has a matching rule',
        () {
      final libDir = Directory('${rulesFile().parent.path}/lib');
      expect(libDir.existsSync(), isTrue, reason: 'lib/ not found');

      final discovered = _discoverHouseholdChildPaths(libDir);
      expect(discovered, isNotEmpty,
          reason: 'Regex failed — no household child paths found in lib/');

      final missing = <String>[];
      for (final name in discovered) {
        if (!rules.contains(RegExp('match\\s+/$name/\\{'))) missing.add(name);
      }
      expect(
        missing,
        isEmpty,
        reason:
            'Client hits these household child paths with no matching rule — '
            'Firestore will default-deny them and the feature breaks with '
            'PERMISSION_DENIED: $missing',
      );
    });
  });
}
