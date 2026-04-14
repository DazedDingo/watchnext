import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/concierge_service.dart';

final conciergeServiceProvider = Provider<ConciergeService>(
  (_) => ConciergeService(),
);
