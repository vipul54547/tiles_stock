import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/tile_design.dart';
import '../utils/quality_merge.dart';
import 'tile_card.dart';

/// The banded, quality-merged buyer grid — a non-scrolling Column of
/// StaggeredGrid blocks (wrap it in a scroll view / SliverToBoxAdapter; never
/// put a real sliver after a masonry grid → endless scroll). Concept families
/// (>=2 distinct masters sharing size + family_key) are ringed in a thin
/// coloured band; a rich family (>=3 masters) is nudged a few slots up the
/// newest-first order (capped). Shared by the stockist portfolio and the
/// in-app DISCOVER feed. (Scenario-2 buyer merge · steps 2 & 4)
class MergedFamilyGrid extends StatelessWidget {
  final List<MergedDesign> cards;

  /// Opens the design detail for cards[index] (index == position in [cards]).
  final void Function(int index) onOpenDetail;

  /// Opens the Premium/Standard/Both chooser for a merged card.
  final void Function(MergedDesign card) onChoiceTap;
  final bool Function(MergedDesign card) isChosen;

  /// When non-null the card shows a tappable seller/brand chip (discover feed).
  /// Portfolio leaves it null (already scoped to one stockist).
  final void Function(MergedDesign card)? onStockistTap;

  /// Optional DNA-tag ▾ expander on each card (My Suppliers). Returns the card's
  /// DNA tags grouped by attribute for [repId]; null/empty → no arrow.
  final Map<String, List<String>>? Function(String repId)? dnaTagsFor;

  /// The design id whose DNA chips are currently expanded (one open at a time).
  final String? expandedDnaId;

  /// Toggles the DNA expansion for [repId] (open it / collapse it).
  final void Function(String repId)? onToggleDnaExpand;

  final EdgeInsets padding;

  const MergedFamilyGrid({
    super.key,
    required this.cards,
    required this.onOpenDetail,
    required this.onChoiceTap,
    required this.isChosen,
    this.onStockistTap,
    this.dnaTagsFor,
    this.expandedDnaId,
    this.onToggleDnaExpand,
    this.padding = const EdgeInsets.fromLTRB(12, 4, 12, 12),
  });

  static const List<Color> _familyColors = [
    Color(0xFF1B9E77), Color(0xFFD95F02), Color(0xFF7570B3),
    Color(0xFFE7298A), Color(0xFF66A61E), Color(0xFFE6AB02),
    Color(0xFFA6761D), Color(0xFF1F78B4),
  ];
  Color _famColorFor(String gk) =>
      _familyColors[gk.hashCode.abs() % _familyColors.length];
  String _gkOf(TileDesign d) =>
      d.familyKey.isEmpty ? '' : '${d.size}|${d.familyKey}';
  static int _famBoost(int masters) =>
      masters < 3 ? 0 : (4 + (masters - 3) * 2).clamp(0, 12);

  Widget _tileCard(int i) {
    final m = cards[i];
    final rep = m.rep;
    return TileCard(
      design: rep,
      premiumBoxes: m.premium != null ? m.premiumBoxes : null,
      standardBoxes: m.standard != null ? m.standardBoxes : null,
      onTap: () => onOpenDetail(i),
      isChosen: isChosen(m),
      onChoiceTap: () => onChoiceTap(m),
      onStockistTap:
          onStockistTap == null ? null : () => onStockistTap!(m),
      dnaTagsByAttribute: dnaTagsFor?.call(rep.id),
      isDnaExpanded: expandedDnaId == rep.id,
      onToggleDnaExpand:
          onToggleDnaExpand == null ? null : () => onToggleDnaExpand!(rep.id),
      onCollapseDnaIfExpanded: onToggleDnaExpand == null
          ? null
          : () {
              if (expandedDnaId == rep.id) onToggleDnaExpand!(rep.id);
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = cards;
    final masters = <String, Set<String>>{};
    final firstPos = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      final rep = list[i].rep;
      final gk = _gkOf(rep);
      if (gk.isEmpty) continue;
      (masters[gk] ??= <String>{})
          .add(rep.libraryId.isNotEmpty ? rep.libraryId : rep.id);
      firstPos.putIfAbsent(gk, () => i);
    }
    bool isFam(String gk) => gk.isNotEmpty && (masters[gk]?.length ?? 0) >= 2;

    // Order blocks (families + singles) by key = position − family boost, stable
    // on ties so the unboosted order is preserved.
    final ordered =
        <({double key, int seq, bool fam, String gk, List<int> idx})>[];
    final seen = <String>{};
    var seq = 0;
    for (var i = 0; i < list.length; i++) {
      final gk = _gkOf(list[i].rep);
      if (isFam(gk)) {
        if (seen.contains(gk)) continue;
        seen.add(gk);
        final idx = [
          for (var j = 0; j < list.length; j++)
            if (_gkOf(list[j].rep) == gk) j
        ];
        ordered.add((
          key: (firstPos[gk]! - _famBoost(masters[gk]!.length)).toDouble(),
          seq: seq++,
          fam: true,
          gk: gk,
          idx: idx,
        ));
      } else {
        ordered.add(
            (key: i.toDouble(), seq: seq++, fam: false, gk: '', idx: [i]));
      }
    }
    ordered.sort((a, b) {
      final c = a.key.compareTo(b.key);
      return c != 0 ? c : a.seq.compareTo(b.seq);
    });

    // Consecutive singles → one masonry run; each family → its band.
    final widgets = <Widget>[];
    var run = <Widget>[];
    void flush() {
      if (run.isEmpty) return;
      final items = run;
      run = [];
      widgets.add(_staggeredRun(items));
    }
    for (final b in ordered) {
      if (!b.fam) {
        run.add(_tileCard(b.idx.first));
        continue;
      }
      flush();
      widgets.add(
          _familyBand(b.gk, [for (final j in b.idx) _tileCard(j)]));
    }
    flush();

    return Padding(
      padding: padding,
      child: Column(
        children: [
          for (var i = 0; i < widgets.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            widgets[i],
          ],
        ],
      ),
    );
  }

  Widget _staggeredRun(List<Widget> items) => StaggeredGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          for (final w in items)
            StaggeredGridTile.fit(crossAxisCellCount: 1, child: w),
        ],
      );

  Widget _familyBand(String gk, List<Widget> members) {
    final color = _famColorFor(gk);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.4),
        borderRadius: BorderRadius.circular(14),
        color: color.withValues(alpha: 0.04),
      ),
      padding: const EdgeInsets.all(8),
      child: StaggeredGrid.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: [
          for (final w in members)
            StaggeredGridTile.fit(crossAxisCellCount: 1, child: w),
        ],
      ),
    );
  }
}
