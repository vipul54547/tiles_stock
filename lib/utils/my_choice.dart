import '../models/choice_state.dart';
import '../services/supabase_data_service.dart';

// Keeps the in-memory [myChoiceQuantities] map and the per-user `my_choices`
// table in sync. Use these instead of mutating the map directly so every change
// (add / change qty / remove / clear) is saved to the user's account.

final _svc = SupabaseDataService();

/// Set a design's chosen quantity (qty <= 0 removes it). Persists in the
/// background. No-op persistence for guests (currentEndUserId empty).
void setMyChoiceQty(String designId, int qty) {
  if (qty <= 0) {
    myChoiceQuantities.remove(designId);
  } else {
    myChoiceQuantities[designId] = qty;
  }
  _svc.upsertChoice(designId, qty); // fire-and-forget
}

/// Remove a design from My Choice.
void removeMyChoice(String designId) => setMyChoiceQty(designId, 0);

/// Clear all choices (memory + saved).
void clearMyChoices() {
  myChoiceQuantities.clear();
  _svc.clearChoices();
}

/// Load the signed-in end user's saved choices into [myChoiceQuantities].
Future<void> loadMyChoices() async {
  final saved = await _svc.getMyChoices();
  myChoiceQuantities
    ..clear()
    ..addAll(saved);
}
