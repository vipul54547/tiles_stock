import '../services/supabase_data_service.dart';

/// Resolves each stockist's OWN word for a canonical surface, for buyer cards.
/// The canonical surface stays the filter/search key; this only changes what the
/// buyer READS on the card:
///   • stockist has a different word → "Raindrops (Sugar)"
///   • their word is the same        → "Sugar"
///   • no word set                   → "Sugar" (canonical)
/// Keyed by stockist sequential_id (how buyer designs carry their stockist).
/// (project_per_brand_surface_mode)
/// Shared, load-once instance for buyer surfaces — mirrors the small global
/// catalogs the buyer screens already share.
final surfaceLabels = SurfaceLabels();

class SurfaceLabels {
  final _svc = SupabaseDataService();

  // '<stockistSeq>|<canonicalSurface>' -> normalised raw + display word.
  final Map<String, ({String raw, String display})> _map = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final rows = await _svc.publicSurfaceLabels();
    for (final r in rows) {
      final seq = (r['stockist'] ?? '').toString();
      final surf = (r['surface'] ?? '').toString();
      if (seq.isEmpty || surf.isEmpty) continue;
      _map['$seq|$surf'] = (
        raw: (r['raw'] ?? '').toString(),
        display: (r['display'] ?? '').toString(),
      );
    }
    _loaded = true;
  }

  /// The surface text to show for a design owned by [stockistSeq] whose canonical
  /// surface is [canonical]. '' when the surface is None/empty.
  String label(String stockistSeq, String canonical) {
    final c = canonical.trim();
    if (c.isEmpty || c.toLowerCase() == 'none') return '';
    final e = _map['$stockistSeq|$c'];
    if (e == null) return c;
    // Same word (compared on the normalised key) → show the nicer canonical.
    if (e.raw == normalizeSurfaceRaw(c)) return c;
    final w = e.display.trim();
    return w.isEmpty ? c : '$w ($c)';
  }
}
