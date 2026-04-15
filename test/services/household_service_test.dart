import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchnext/services/household_service.dart';

void main() {
  group('HouseholdService.isValidInviteCode', () {
    test('accepts 20-64 alphanumerics', () {
      expect(HouseholdService.isValidInviteCode('a' * 20), isTrue);
      expect(HouseholdService.isValidInviteCode('a' * 32), isTrue);
      expect(HouseholdService.isValidInviteCode('a' * 64), isTrue);
      expect(HouseholdService.isValidInviteCode('abc123XYZ' * 4), isTrue);
    });

    test('rejects too-short, too-long, and non-alphanumeric codes', () {
      expect(HouseholdService.isValidInviteCode(''), isFalse);
      expect(HouseholdService.isValidInviteCode('a' * 19), isFalse);
      expect(HouseholdService.isValidInviteCode('a' * 65), isFalse);
      expect(HouseholdService.isValidInviteCode('with-dash' * 4), isFalse);
      expect(HouseholdService.isValidInviteCode('has space' * 4), isFalse);
      expect(HouseholdService.isValidInviteCode('a' * 30 + '!'), isFalse);
    });
  });

  group('HouseholdService with FakeFirebaseFirestore', () {
    late FakeFirebaseFirestore db;
    late HouseholdService svc;

    setUp(() {
      db = FakeFirebaseFirestore();
      svc = HouseholdService(db: db);
    });

    test('createHousehold writes household, member, user pointer, and invite',
        () async {
      final user = MockUser(
        uid: 'u1',
        displayName: 'Alice',
        email: 'alice@example.com',
      );
      final id = await svc.createHousehold(user);
      expect(id, isNotEmpty);

      final hh = await db.doc('households/$id').get();
      expect(hh.data()!['createdBy'], 'u1');
      expect(hh.data()!['invite_code'], matches(RegExp(r'^[a-z0-9]{32}$')));

      final member = await db.doc('households/$id/members/u1').get();
      expect(member.exists, isTrue);
      expect(member.data()!['display_name'], 'Alice');
      expect(member.data()!['email'], 'alice@example.com');
      expect(member.data()!['default_mode'], 'together');

      final userPtr = await db.doc('users/u1').get();
      expect(userPtr.data()!['householdId'], id);

      final invite = hh.data()!['invite_code'] as String;
      final inviteDoc = await db.doc('invites/$invite').get();
      expect(inviteDoc.data()!['householdId'], id);
    });

    test('joinByInviteCode returns null for unknown code', () async {
      final user = MockUser(uid: 'u2');
      expect(await svc.joinByInviteCode(user, 'bogus'), isNull);
    });

    test('joinByInviteCode adds second member', () async {
      final alice = MockUser(uid: 'u1', displayName: 'Alice');
      final hhId = await svc.createHousehold(alice);

      final inviteCode =
          (await db.doc('households/$hhId').get()).data()!['invite_code']
              as String;
      final bob = MockUser(uid: 'u2', displayName: 'Bob');
      final joinedId = await svc.joinByInviteCode(bob, inviteCode);
      expect(joinedId, hhId);

      final members =
          await db.collection('households/$hhId/members').get();
      expect(members.size, 2);
      expect(members.docs.map((d) => d.id).toSet(), {'u1', 'u2'});

      final bobPtr = await db.doc('users/u2').get();
      expect(bobPtr.data()!['householdId'], hhId);
    });

    test('joinByInviteCode throws when household is full', () async {
      final alice = MockUser(uid: 'u1');
      final hhId = await svc.createHousehold(alice);
      final invite =
          (await db.doc('households/$hhId').get()).data()!['invite_code']
              as String;
      await svc.joinByInviteCode(MockUser(uid: 'u2'), invite);

      expect(
        () => svc.joinByInviteCode(MockUser(uid: 'u3'), invite),
        throwsException,
      );
    });

    test('re-joining (same uid) is idempotent and does not throw', () async {
      final alice = MockUser(uid: 'u1');
      final hhId = await svc.createHousehold(alice);
      final invite =
          (await db.doc('households/$hhId').get()).data()!['invite_code']
              as String;
      final result = await svc.joinByInviteCode(alice, invite);
      expect(result, hhId);
    });

    test('getHouseholdIdForUser returns null when user doc missing',
        () async {
      expect(await svc.getHouseholdIdForUser('nobody'), isNull);
    });

    test('getHouseholdIdForUser returns id after creation', () async {
      final alice = MockUser(uid: 'u1');
      final hhId = await svc.createHousehold(alice);
      expect(await svc.getHouseholdIdForUser('u1'), hhId);
    });
  });
}
