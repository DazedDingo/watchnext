import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/household_service.dart';
import 'auth_provider.dart';

final householdServiceProvider = Provider<HouseholdService>((ref) => HouseholdService());

final householdIdProvider = FutureProvider<String?>((ref) async {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return null;
  return ref.read(householdServiceProvider).getHouseholdIdForUser(user.uid);
});

final householdInviteCodeProvider = FutureProvider<String?>((ref) async {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) return null;
  final doc = await FirebaseFirestore.instance.doc('households/$householdId').get();
  return doc.data()?['invite_code'] as String?;
});
