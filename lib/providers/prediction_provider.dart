import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/prediction.dart';
import '../services/prediction_service.dart';
import 'household_provider.dart';

final predictionServiceProvider =
    Provider<PredictionService>((_) => PredictionService());

/// Stream a single prediction doc. Auto-disposes when the screen closes.
/// Key: predictionId ('mediaType:tmdbId').
final predictionProvider =
    StreamProvider.autoDispose.family<Prediction?, String>((ref, id) async* {
  final householdId = ref.watch(householdIdProvider).value;
  if (householdId == null) { yield null; return; }
  yield* ref.watch(predictionServiceProvider).stream(householdId, id);
});
