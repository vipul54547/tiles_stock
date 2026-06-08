import 'dart:math';
import '../models/tile_design.dart';

// ── Catalog ranking ────────────────────────────────────────────────────────
//
// Re-orders the All-Designs catalog with a blended, fair-looking ranking that
// mixes several signals instead of grouping by stockist:
//   • recency      — new designs surface high
//   • quantity     — bigger stock surfaces high (log-scaled so 1000 ≠ 20×50)
//   • priority     — the stockist's priority gives a subtle boost (never a block)
//   • size share   — sizes weighted by their % of total stock (capped)
//   • random nudge — varies per session so the order changes each app open
//
// On top of the score it does a 7-day weight rotation (each weekday emphasises
// a different signal, so over a week every stockist/design gets time near the
// top) and a diversity interleave (no two adjacent tiles share a stockist or a
// size), giving the "multiple stockists & sizes per page" mix.
//
// Pure in-memory maths over the already-fetched list — a sort + one pass, a few
// milliseconds even for thousands of designs, so it's safe to re-run on every
// load. Pass a fresh [seed] per session to reshuffle each time the app opens.

class _W {
  final double nw, qt, pr, sz, rn;
  const _W(this.nw, this.qt, this.pr, this.sz, this.rn);
}

// One weight profile per weekday. Every day keeps all signals in play but leans
// on a different one, so the catalog feels different across the week.
const List<_W> _weekly = [
  _W(0.45, 0.20, 0.15, 0.10, 0.10), // Mon — newest-led
  _W(0.20, 0.45, 0.15, 0.10, 0.10), // Tue — stock-led
  _W(0.20, 0.15, 0.40, 0.10, 0.15), // Wed — priority-led
  _W(0.25, 0.20, 0.15, 0.30, 0.10), // Thu — size-balanced
  _W(0.20, 0.20, 0.15, 0.10, 0.35), // Fri — discovery (random-led)
  _W(0.30, 0.30, 0.15, 0.15, 0.10), // Sat — new + stock
  _W(0.25, 0.20, 0.25, 0.15, 0.15), // Sun — balanced
];

// Deterministic 0..1 value from a key + seed (stable within a session).
double _hashUnit(String key, int seed) {
  var h = 0x811c9dc5 ^ seed;
  for (final c in key.codeUnits) {
    h = (h ^ c) * 0x01000193;
    h &= 0x7fffffff;
  }
  return (h % 100000) / 100000.0;
}

List<TileDesign> rankDesigns(List<TileDesign> designs, {int? seed}) {
  if (designs.length < 3) return List.of(designs);
  final s = seed ?? DateTime.now().microsecondsSinceEpoch;
  final w = _weekly[(DateTime.now().weekday - 1) % 7];

  // ── normalisation references ──
  final now = DateTime.now();
  var maxQtyLog = 0.0;
  final sizeBoxes = <String, int>{};
  var totalBoxes = 0;
  var maxPriority = 0.0;
  for (final d in designs) {
    final ql = log(1 + d.boxQuantity);
    if (ql > maxQtyLog) maxQtyLog = ql;
    sizeBoxes[d.size] = (sizeBoxes[d.size] ?? 0) + d.boxQuantity;
    totalBoxes += d.boxQuantity;
    if (d.stockistPriority > maxPriority) maxPriority = d.stockistPriority;
  }
  var maxSizeShare = 0.0;
  sizeBoxes.forEach((_, b) {
    final share = totalBoxes == 0 ? 0.0 : b / totalBoxes;
    if (share > maxSizeShare) maxSizeShare = share;
  });

  double scoreOf(TileDesign d) {
    // recency: exponential decay (~30-day half-life), newest ≈ 1.
    final ageDays = now.difference(d.createdAt).inHours / 24.0;
    final recency = exp(-ageDays.clamp(0, 3650) / 30.0);
    final qty = maxQtyLog == 0 ? 0.0 : log(1 + d.boxQuantity) / maxQtyLog;
    final pri = maxPriority == 0 ? 0.0 : d.stockistPriority / maxPriority;
    final share =
        totalBoxes == 0 ? 0.0 : (sizeBoxes[d.size] ?? 0) / totalBoxes;
    // capped so a dominant size surfaces more without swallowing the page.
    final size = maxSizeShare == 0 ? 0.0 : (share / maxSizeShare).clamp(0.0, 1.0);
    final rnd = _hashUnit(d.id, s);
    return w.nw * recency +
        w.qt * qty +
        w.pr * pri +
        w.sz * size +
        w.rn * rnd;
  }

  final pool = List.of(designs)
    ..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));

  // ── diversity interleave ──
  // Greedily emit the best-scoring candidate that doesn't repeat a stockist or
  // size seen in the last [window] placements; relax if none qualifies.
  const window = 2;
  final out = <TileDesign>[];
  final recentStockists = <String>[];
  final recentSizes = <String>[];
  bool ok(TileDesign d) =>
      (d.stockistId.isEmpty || !recentStockists.contains(d.stockistId)) &&
      !recentSizes.contains(d.size);

  while (pool.isNotEmpty) {
    var pick = pool.indexWhere(ok);
    if (pick < 0) {
      // relax the size rule, keep stockists apart where possible
      pick = pool.indexWhere((d) =>
          d.stockistId.isEmpty || !recentStockists.contains(d.stockistId));
    }
    if (pick < 0) pick = 0; // give up: take the best remaining
    final d = pool.removeAt(pick);
    out.add(d);
    recentStockists.add(d.stockistId);
    if (recentStockists.length > window) recentStockists.removeAt(0);
    recentSizes.add(d.size);
    if (recentSizes.length > window) recentSizes.removeAt(0);
  }
  return out;
}
