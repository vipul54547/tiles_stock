import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../models/stockist.dart';
import '../models/tile_design.dart';
import '../services/supabase_data_service.dart';
import '../services/supabase_auth_service.dart';
import '../widgets/tile_card.dart';
import '../services/cloudinary_service.dart';
import 'end_user/stockist_group_screen.dart'
    show stockistGroups, loadStockistGroupsFromDb, confirmToggleStockistInGroup;
import '../models/choice_state.dart';
import '../widgets/smart_search_toggle.dart';
import '../utils/design_ranking.dart';
import '../utils/my_choice.dart';
import '../utils/tile_types.dart';
import '../widgets/filter_section.dart';
import '../widgets/notification_bell.dart';
import '../utils/stockist_tiers.dart';
import '../utils/guest_gate.dart';
import '../models/claimed_catalog.dart';

const _qualities = ['Premium', 'Standard'];
// Distinct from the primary blue (0xFF1B4F72) used for stockist ID / view-profile,
// so a group's coloured circle never blends with the profile identity.
const _groupColors = [Color(0xFFEF6C00), Color(0xFF2E7D32), Color(0xFF6A1B9A)];
const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
};

class _StockistData {
  final Stockist stockist;
  final int totalBoxes;
  final Set<String> qualities;
  final List<TileDesign> designs;

  _StockistData({
    required this.stockist,
    required this.totalBoxes,
    required this.qualities,
    required this.designs,
  });
}

class StockistsOverviewScreen extends StatefulWidget {
  const StockistsOverviewScreen({super.key});

  @override
  State<StockistsOverviewScreen> createState() => _State();
}

class _State extends State<StockistsOverviewScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<_StockistData> _allData = [];
  List<TileDesign> _allDesigns = [];
  List<String> _allSizes = [];
  List<String> _allSurfaces = [];
  bool _loading = true;
  bool _viewDesigns = false;

  // Father & Child market context — a single global toggle that governs every
  // buyer tab (Group / Stock / All Design). 'Public' = the Open Market,
  // 'Private' = the buyer's claimed Closed Market, 'Both' = the two merged.
  String _market = 'Public'; // 'Public' | 'Private' | 'Both'
  // Claimed (Closed Market) designs and the per-stockist cards derived from them.
  List<TileDesign> _privateDesigns = [];
  List<_StockistData> _privateData = [];
  // The buyer's claimed-catalog summaries (for the "Manage saved" remove list).
  List<ClaimedCatalog> _claimedCatalogs = [];

  final _searchCtrl = TextEditingController();
  String _searchQuery  = '';
  bool _searchActive   = false;
  bool _searchByDesign = true; // true = design name, false = stockist

  // Quality filter
  final Set<String> _selectedQualities = {};

  // Stockist filter (Size + Finish)
  final Set<String> _selectedSizes = {};
  final Set<String> _selectedSurfaces = {};


  // Design filter (Qty, Stock Type — in addition to shared Size/Finish/Quality)
  final Set<String> _selectedTypes = {};
  final Set<String> _selectedThickness = {};
  String _designStockType = 'Both';
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();

  int get _designFilterCount {
    int c = _selectedSizes.length +
        _selectedSurfaces.length +
        _selectedTypes.length +
        _selectedThickness.length;
    if (_designStockType != 'Both') c++;
    if (_minQtyCtrl.text.isNotEmpty) c++;
    if (_maxQtyCtrl.text.isNotEmpty) c++;
    return c;
  }

  // Group filter
  int _activeGroupIndex = -1;

  // Shared design-filter predicate — applies every active facet (quality, size,
  // surface, colour, tile type, thickness, stock type, qty). Used by both the
  // Stock (stockist) view and the All-Design grid so their filters match.
  bool _matchesDesignFacets(TileDesign t) {
    if (_selectedQualities.isNotEmpty && !_selectedQualities.contains(t.quality)) {
      return false;
    }
    if (_selectedSizes.isNotEmpty && !_selectedSizes.contains(t.size)) return false;
    if (_selectedSurfaces.isNotEmpty &&
        !_selectedSurfaces.contains(t.surfaceType)) {
      return false;
    }
    if (_selectedTypes.isNotEmpty && !_selectedTypes.contains(t.tileType)) {
      return false;
    }
    if (_selectedThickness.isNotEmpty &&
        !_selectedThickness.contains(thicknessBandOf(t))) {
      return false;
    }
    if (_designStockType != 'Both' &&
        !(t.stockType == _designStockType || t.stockType == 'Both')) {
      return false;
    }
    final mn = int.tryParse(_minQtyCtrl.text);
    final mx = int.tryParse(_maxQtyCtrl.text);
    if (mn != null && t.boxQuantity < mn) return false;
    if (mx != null && t.boxQuantity > mx) return false;
    return true;
  }

  // True when any design facet (beyond quality, which has its own chips) is set.
  bool get _anyDesignFilterActive =>
      _selectedQualities.isNotEmpty || _designFilterCount > 0;

  // Platform-level benchmarks — computed as getters so they always
  // reflect the active filters.
  List<TileDesign> get _platformFilteredDesigns =>
      _allData.expand((d) => d.designs).where(_matchesDesignFacets).toList();

  double get _platformAvgBoxesPerDesign {
    final designs = _platformFilteredDesigns;
    if (designs.isEmpty) return 0;
    return designs.fold(0, (sum, d) => sum + d.boxQuantity) / designs.length;
  }

  double get _platformAvgBoxesPerStockist {
    if (_allData.isEmpty) return 0;
    final total = _platformFilteredDesigns.fold(0, (sum, d) => sum + d.boxQuantity);
    return total / _allData.length;
  }


  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _dismissKeyboard();
    _searchCtrl.clear();
    setState(() {
      _searchQuery    = '';
      _searchActive   = false;
      _searchByDesign = true;
    });
  }

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _service.getMarketStockists(),
      _service.getAllDesigns(),
    ]);

    // Link-only stockists are hidden from the public market (reachable only via
    // their share link).
    final stockists =
        (results[0] as List<Stockist>).where((s) => s.isListed).toList();
    final designs = results[1] as List<TileDesign>;
    await loadStockistGroupsFromDb(); // the user's saved group filters
    await loadMyChoices();            // restore saved My Choice selections

    // Order sizes & surfaces by the admin master sequence (unknown ones fall to
    // the end), so the filter + size table rows/columns match that order.
    final sizeOrder = await _service.getActiveSizeNames();
    final finishOrder = await _service.getActiveFinishNames();
    int rankIn(List<String> order, String v) {
      final i = order.indexOf(v);
      return i < 0 ? 1 << 20 : i;
    }
    final sizes = designs.map((d) => d.size).toSet().toList()
      ..sort((a, b) {
        final r = rankIn(sizeOrder, a).compareTo(rankIn(sizeOrder, b));
        return r != 0 ? r : a.compareTo(b);
      });
    final surfaces = designs.map((d) => d.surfaceType).toSet().toList()
      ..sort((a, b) {
        final r = rankIn(finishOrder, a).compareTo(rankIn(finishOrder, b));
        return r != 0 ? r : a.compareTo(b);
      });

    final data = stockists.asMap().entries.map((e) {
      final s = e.value;
      final myDesigns = designs.where((d) => d.stockistId == s.id).toList();
      final totalBoxes = myDesigns.fold(0, (sum, d) => sum + d.boxQuantity);
      final quals = myDesigns.map((d) => d.quality).toSet();

      return _StockistData(
        stockist: s,
        totalBoxes: totalBoxes,
        qualities: quals,
        designs: myDesigns,
      );
    }).toList();

    // ── Private (Closed Market) — the buyer's claimed catalogs ───────────────
    // Loaded for logged-in buyers only (guests have none). Designs come back in
    // the same masked shape as the open market, so anonymity holds. We group
    // them per stockist (using the claimed-catalog summary for the masked name /
    // city) to build the same _StockistData cards the Stock view already renders.
    var privateDesigns = <TileDesign>[];
    var privateData = <_StockistData>[];
    var claimedCatalogs = <ClaimedCatalog>[];
    if (!isGuest) {
      final priv = await _service.getMyPrivateDesigns();
      final claimed = await _service.getMyClaimedCatalogs();
      claimedCatalogs = claimed;
      final infoByKey = <String, ClaimedCatalog>{};
      for (final c in claimed) {
        infoByKey[c.stockistKey] = c;
      }
      final byStockist = <String, List<TileDesign>>{};
      for (final d in priv) {
        byStockist.putIfAbsent(d.stockistId, () => []).add(d);
      }
      privateData = byStockist.entries.map((e) {
        final info = infoByKey[e.key];
        final s = Stockist(
          id: e.key,
          name: (info != null && info.stockistName.isNotEmpty)
              ? info.stockistName
              : e.key,
          email: '',
          phone: '',
          city: info?.stockistCity ?? '',
          state: '',
          address: '',
          createdAt: DateTime.now(),
        );
        return _StockistData(
          stockist: s,
          totalBoxes: e.value.fold(0, (sum, d) => sum + d.boxQuantity),
          qualities: e.value.map((d) => d.quality).toSet(),
          designs: e.value,
        );
      }).toList();
      privateDesigns =
          rankDesigns(priv, seed: DateTime.now().microsecondsSinceEpoch);
    }

    setState(() {
      _allData = data;
      // Blended catalog ranking (fresh per-session seed) for the All-Design grid.
      _allDesigns =
          rankDesigns(designs, seed: DateTime.now().microsecondsSinceEpoch);
      _privateDesigns = privateDesigns;
      _privateData = privateData;
      _claimedCatalogs = claimedCatalogs;
      _allSizes = sizes;
      _allSurfaces = surfaces;
      _loading = false;
    });
  }

  List<TileDesign> _stockistDesigns(_StockistData d) =>
      d.designs.where(_matchesDesignFacets).toList();

  // Stockist display name for a sequential id (for the group confirm dialog).
  String _stockistName(String seqId) {
    for (final sd in _allData) {
      if (sd.stockist.id == seqId) return sd.stockist.name;
    }
    return '';
  }

  int _filteredBoxCount(_StockistData d) {
    final designs = _stockistDesigns(d);
    return designs.fold(0, (sum, t) => sum + t.boxQuantity);
  }

  double _filteredPerDesignAvg(_StockistData d) {
    final designs = _stockistDesigns(d);
    if (designs.isEmpty) return 0;
    return designs.fold(0, (sum, t) => sum + t.boxQuantity) / designs.length;
  }

  int _tier(_StockistData d) {
    final aboveAvg1 = _filteredPerDesignAvg(d) >= _platformAvgBoxesPerDesign;
    final aboveAvg2 = _filteredBoxCount(d) >= _platformAvgBoxesPerStockist;
    if (aboveAvg1 && aboveAvg2) return 1;
    if (!aboveAvg1 && aboveAvg2) return 2;
    if (aboveAvg1 && !aboveAvg2) return 3;
    return 4;
  }

  // ── Market-aware base lists ───────────────────────────────────────────────
  // Every tab reads these instead of the raw public lists, so switching the
  // market toggle re-filters stockists *and* designs together.
  List<_StockistData> get _marketData {
    switch (_market) {
      case 'Private':
        return _privateData;
      case 'Both':
        return [..._allData, ..._privateData];
      default:
        return _allData;
    }
  }

  List<TileDesign> get _marketDesigns {
    switch (_market) {
      case 'Private':
        return _privateDesigns;
      case 'Both':
        return [..._allDesigns, ..._privateDesigns];
      default:
        return _allDesigns;
    }
  }

  List<_StockistData> get _filteredData {
    var result = _marketData;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result
          .where((d) =>
              d.stockist.name.toLowerCase().contains(q) ||
              d.stockist.id.toLowerCase().contains(q))
          .toList();
    }
    if (_activeGroupIndex >= 0) {
      final groupIds = stockistGroups[_activeGroupIndex].stockistIds;
      result = result.where((d) => groupIds.contains(d.stockist.id)).toList();
    }
    // Keep only stockists that carry at least one design matching every active
    // facet (size, surface, colour, type, thickness, stock type, qty, quality).
    if (_anyDesignFilterActive) {
      result =
          result.where((d) => d.designs.any(_matchesDesignFacets)).toList();
    }
    result.sort((a, b) {
      // 1) membership tier (Platinum > Gold > Silver > none) — admin-set.
      final typeDiff = stockistTierRank(b.stockist.stockistType)
          .compareTo(stockistTierRank(a.stockist.stockistType));
      if (typeDiff != 0) return typeDiff;
      // 2) priority within the tier (higher shown first) — admin-set.
      final prioDiff = b.stockist.priority.compareTo(a.stockist.priority);
      if (prioDiff != 0) return prioDiff;
      // 3) automatic stock-volume ranking as the tiebreaker.
      final tierDiff = _tier(a).compareTo(_tier(b));
      if (tierDiff != 0) return tierDiff;
      return _filteredPerDesignAvg(b).compareTo(_filteredPerDesignAvg(a));
    });
    return result;
  }

  List<TileDesign> get _filteredDesigns {
    var result = _marketDesigns;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      if (_searchByDesign) {
        result = result.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
      } else {
        final matchingIds = _marketData
            .where((sd) =>
                sd.stockist.name.toLowerCase().contains(q) ||
                sd.stockist.id.toLowerCase().contains(q))
            .map((sd) => sd.stockist.id)
            .toSet();
        result = result.where((d) => matchingIds.contains(d.stockistId)).toList();
      }
    }
    if (_activeGroupIndex >= 0) {
      final groupIds = stockistGroups[_activeGroupIndex].stockistIds;
      result = result.where((d) => groupIds.contains(d.stockistId)).toList();
    }
    if (_selectedQualities.isNotEmpty) {
      result = result.where((d) => _selectedQualities.contains(d.quality)).toList();
    }
    if (_selectedSizes.isNotEmpty) {
      result = result.where((d) => _selectedSizes.contains(d.size)).toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      result = result.where((d) => _selectedSurfaces.contains(d.surfaceType)).toList();
    }
    if (_selectedTypes.isNotEmpty) {
      result = result.where((d) => _selectedTypes.contains(d.tileType)).toList();
    }
    if (_selectedThickness.isNotEmpty) {
      result = result
          .where((d) => _selectedThickness.contains(thicknessBandOf(d)))
          .toList();
    }
    if (_designStockType != 'Both') {
      result = result
          .where((d) => d.stockType == _designStockType || d.stockType == 'Both')
          .toList();
    }
    final minQty = int.tryParse(_minQtyCtrl.text);
    final maxQty = int.tryParse(_maxQtyCtrl.text);
    if (minQty != null) result = result.where((d) => d.boxQuantity >= minQty).toList();
    if (maxQty != null) result = result.where((d) => d.boxQuantity <= maxQty).toList();
    // Preserve the blended ranking order from _load (no quantity re-sort).
    return result;
  }

  // Removable chips for the active-filter bar above the all-design grid.
  List<ActiveFilter> _activeDesignFilters() {
    final out = <ActiveFilter>[];
    void addSet(Set<String> set, [String Function(String)? fmt]) {
      for (final v in set.toList()) {
        out.add(ActiveFilter(
            fmt == null ? v : fmt(v), () => setState(() => set.remove(v))));
      }
    }
    addSet(_selectedSizes, (v) => v.replaceAll(' mm', ''));
    addSet(_selectedSurfaces);
    addSet(_selectedTypes);
    addSet(_selectedThickness);
    addSet(_selectedQualities);
    if (_designStockType != 'Both') {
      out.add(ActiveFilter(
          _designStockType, () => setState(() => _designStockType = 'Both')));
    }
    final mn = _minQtyCtrl.text.trim();
    final mx = _maxQtyCtrl.text.trim();
    if (mn.isNotEmpty || mx.isNotEmpty) {
      out.add(ActiveFilter(
          'Qty ${mn.isEmpty ? '0' : mn}–${mx.isEmpty ? '∞' : mx}',
          () => setState(() {
                _minQtyCtrl.clear();
                _maxQtyCtrl.clear();
              })));
    }
    return out;
  }

  void _clearAllDesignFilters() => setState(() {
        _selectedSizes.clear();
        _selectedSurfaces.clear();
        _selectedTypes.clear();
        _selectedThickness.clear();
        _selectedQualities.clear();
        _designStockType = 'Both';
        _minQtyCtrl.clear();
        _maxQtyCtrl.clear();
      });

  static const _filterStockTypes = ['One Time', 'Regular', 'Both'];

  void _showDesignFilterSheet() {
    _dismissKeyboard();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.82;
    var localSizes      = Set<String>.from(_selectedSizes);
    var localSurfaces   = Set<String>.from(_selectedSurfaces);
    var localTypes      = Set<String>.from(_selectedTypes);
    var localThickness  = Set<String>.from(_selectedThickness);
    final thicknessBands = availableThicknessBands(_allDesigns);
    var localStockType  = _designStockType;

    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget filterChip(String label, bool sel, VoidCallback onTap) =>
              GestureDetector(
                onTap: () { FocusManager.instance.primaryFocus?.unfocus(); onTap(); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF1B4F72) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade400),
                  ),
                  child: Text(label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : Colors.grey.shade700,
                      )),
                ),
              );

          Widget chipWrap(List<String> options, Set<String> sel) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options
                    .map((o) => filterChip(o, sel.contains(o), () => setSheet(() {
                          if (sel.contains(o)) {
                            sel.remove(o);
                          } else {
                            sel.add(o);
                          }
                        })))
                    .toList(),
              );

          int previewCount() {
            var r = _marketDesigns;
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              if (_searchByDesign) {
                r = r.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
              } else {
                final ids = _marketData
                    .where((sd) =>
                        sd.stockist.name.toLowerCase().contains(q) ||
                        sd.stockist.id.toLowerCase().contains(q))
                    .map((sd) => sd.stockist.id)
                    .toSet();
                r = r.where((d) => ids.contains(d.stockistId)).toList();
              }
            }
            if (_activeGroupIndex >= 0) {
              final g = stockistGroups[_activeGroupIndex].stockistIds;
              r = r.where((d) => g.contains(d.stockistId)).toList();
            }
            if (_selectedQualities.isNotEmpty) {
              r = r.where((d) => _selectedQualities.contains(d.quality)).toList();
            }
            if (localSizes.isNotEmpty) r = r.where((d) => localSizes.contains(d.size)).toList();
            if (localSurfaces.isNotEmpty) r = r.where((d) => localSurfaces.contains(d.surfaceType)).toList();
            if (localTypes.isNotEmpty) r = r.where((d) => localTypes.contains(d.tileType)).toList();
            if (localThickness.isNotEmpty) {
              r = r.where((d) => localThickness.contains(thicknessBandOf(d))).toList();
            }
            if (localStockType != 'Both') {
              r = r.where((d) => d.stockType == localStockType || d.stockType == 'Both').toList();
            }
            final mn = int.tryParse(_minQtyCtrl.text);
            final mx = int.tryParse(_maxQtyCtrl.text);
            if (mn != null) r = r.where((d) => d.boxQuantity >= mn).toList();
            if (mx != null) r = r.where((d) => d.boxQuantity <= mx).toList();
            return r.length;
          }

          final qtyRow = Row(children: [
            Expanded(
              child: TextField(
                controller: _minQtyCtrl,
                keyboardType: TextInputType.number,
                onChanged: (_) => setSheet(() {}),
                decoration: InputDecoration(
                  hintText: 'Min', isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _maxQtyCtrl,
                keyboardType: TextInputType.number,
                onChanged: (_) => setSheet(() {}),
                decoration: InputDecoration(
                  hintText: 'Max', isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ]);

          return SizedBox(
            height: sheetHeight,
            child: Column(
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      const Text('Filter Designs',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setSheet(() {
                          localSizes.clear();
                          localSurfaces.clear();
                          localTypes.clear();
                          localThickness.clear();
                          localStockType = 'Both';
                          _minQtyCtrl.clear();
                          _maxQtyCtrl.clear();
                        }),
                        child: const Text('Reset all',
                            style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                // Pinned Quantity — always visible at the top.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Quantity (boxes)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 8),
                      qtyRow,
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    children: [
                      FilterSection(
                        title: 'Size',
                        summary: filterSummary(localSizes),
                        child: chipWrap(_allSizes, localSizes),
                      ),
                      FilterSection(
                        title: 'Finish',
                        summary: filterSummary(localSurfaces),
                        child: chipWrap(_allSurfaces, localSurfaces),
                      ),
                      FilterSection(
                        title: 'Tile Type',
                        summary: filterSummary(localTypes),
                        child: chipWrap(kTileTypes, localTypes),
                      ),
                      if (thicknessBands.isNotEmpty)
                        FilterSection(
                          title: 'Thickness (approx)',
                          summary: filterSummary(localThickness),
                          child: chipWrap(thicknessBands, localThickness),
                        ),
                      FilterSection(
                        title: 'Stock Type',
                        summary: localStockType,
                        child: Wrap(spacing: 8, runSpacing: 8,
                          children: _filterStockTypes.map((t) => filterChip(
                            t, localStockType == t,
                            () => setSheet(() => localStockType = t),
                          )).toList()),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(ctx).pop(true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4F72),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text('Show ${previewCount()} designs',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      if (!mounted) return;
      // Apply on any close (Apply button, swipe-down, or tap-outside).
      setState(() {
        _selectedSizes      ..clear()..addAll(localSizes);
        _selectedSurfaces   ..clear()..addAll(localSurfaces);
        _selectedTypes      ..clear()..addAll(localTypes);
        _selectedThickness  ..clear()..addAll(localThickness);
        _designStockType    = localStockType;
      });
    });
  }

  void _openDesignSheet(int startIndex, List<TileDesign> list) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.75;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        int idx = startIndex;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final d = list[idx];
            final imageUrl = d.faceImageUrls.isNotEmpty
                ? d.faceImageUrls.first
                : '';
            final isFirst = idx == 0;
            final isLast = idx == list.length - 1;

            return Container(
              height: sheetHeight,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle + close button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: GestureDetector(
                            onTap: () => Navigator.of(ctx).pop(),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close,
                                  size: 18, color: Colors.grey),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Big image (bottom-sheet preview → medium thumbnail)
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(imageUrl, width: 800),
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: Colors.grey.shade200),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[200],
                        child: const Icon(Icons.image_not_supported, size: 48),
                      ),
                    ),
                  ),
                  // Prev / Next immediately after image
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: isFirst ? null : () => setSheet(() => idx--),
                            icon: const Icon(Icons.arrow_back_ios, size: 14),
                            label: const Text('Prev'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1B4F72),
                              side: const BorderSide(color: Color(0xFF1B4F72)),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '${idx + 1} / ${list.length}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: isLast ? null : () => setSheet(() => idx++),
                            icon: const Icon(Icons.arrow_forward_ios, size: 14),
                            label: const Text('Next'),
                            iconAlignment: IconAlignment.end,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1B4F72),
                              side: const BorderSide(color: Color(0xFF1B4F72)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Design name + box count
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 17),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () {
                                  final id = d.id;
                                  if (myChoiceQuantities.containsKey(id)) {
                                    setMyChoiceQty(id, 0);
                                  } else {
                                    setMyChoiceQty(id, d.boxQuantity);
                                  }
                                  setSheet(() {});
                                  setState(() {});
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: myChoiceQuantities.containsKey(d.id)
                                        ? const Color(0xFF1B4F72)
                                        : const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.3)),
                                  ),
                                  child: Icon(
                                    myChoiceQuantities.containsKey(d.id)
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_outline_rounded,
                                    size: 16,
                                    color: myChoiceQuantities.containsKey(d.id)
                                        ? Colors.white
                                        : const Color(0xFF1B4F72),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  '${d.boxQuantity} boxes',
                                  style: const TextStyle(
                                    color: Color(0xFF1B4F72),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Size / finish / quality chips, plus the stockist's
                          // own finish wording when it differs from the standard.
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _infoChip(d.size.replaceAll(' mm', '')),
                              _infoChip(d.surfaceType),
                              _infoChip(d.quality),
                              if (d.finishLabel != null &&
                                  d.finishLabel!.trim().isNotEmpty &&
                                  d.finishLabel!.toLowerCase() !=
                                      d.surfaceType.toLowerCase())
                                _stockistFinishChip(d.finishLabel!.trim()),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Stockist ID chip + group circles
                          Row(
                            children: [
                              GestureDetector(
                                onTap: () {
                                  Navigator.of(ctx).pop();
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted) {
                                      context.push('/stockist/${d.stockistId}/portfolio');
                                    }
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.25)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.storefront_outlined,
                                          size: 14, color: Color(0xFF1B4F72)),
                                      const SizedBox(width: 6),
                                      Text(
                                        'ID: ${d.stockistId}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF1B4F72),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.arrow_forward_ios,
                                          size: 11, color: Color(0xFF1B4F72)),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              ...List.generate(stockistGroups.length, (i) {
                                final color = _groupColors[i % _groupColors.length];
                                final inGroup = stockistGroups[i].stockistIds
                                    .contains(d.stockistId);
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: GestureDetector(
                                    onTap: () async {
                                      final changed =
                                          await confirmToggleStockistInGroup(
                                        context,
                                        groupIndex: i,
                                        stockistId: d.stockistId,
                                        stockistName: _stockistName(d.stockistId),
                                      );
                                      if (changed) {
                                        setSheet(() {});
                                        setState(() {});
                                      }
                                    },
                                    child: Tooltip(
                                      message: stockistGroups[i].name,
                                      child: Container(
                                        width: 30,
                                        height: 30,
                                        decoration: BoxDecoration(
                                          color: inGroup
                                              ? color
                                              : color.withValues(alpha: 0.1),
                                          shape: BoxShape.circle,
                                          border:
                                              Border.all(color: color, width: 1.5),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${i + 1}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: inGroup ? Colors.white : color,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // View Tile Details button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted) context.push('/design/${d.id}');
                                });
                              },
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: const Text('View Tile Details'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1B4F72),
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                          // Clear the system navigation bar (edge-to-edge).
                          SizedBox(height: MediaQuery.of(ctx).viewPadding.bottom),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Widget _infoChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: const Color(0xFF1B4F72).withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF1B4F72),
            fontWeight: FontWeight.w500,
          ),
        ),
      );

  // The stockist's own wording for the finish (finish_label), labelled so the
  // buyer can tell it apart from the standard finish chip and recognise the
  // design by the stockist's name too.
  Widget _stockistFinishChip(String name) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFE65100).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border:
              Border.all(color: const Color(0xFFE65100).withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storefront_outlined,
                size: 12, color: Color(0xFFE65100)),
            const SizedBox(width: 4),
            Text(
              'Stockist: $name',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFE65100),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );

  Widget _navButton(String label, IconData icon, VoidCallback? onTap,
      {bool active = false, int badgeCount = 0}) {
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.white : Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 14,
                color: active ? const Color(0xFF1B4F72) : Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? const Color(0xFF1B4F72) : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );

    if (badgeCount <= 0) return Expanded(child: btn);

    return Expanded(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          btn,
          Positioned(
            top: -5,
            right: 2,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$badgeCount',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      // When this screen was pushed (e.g. admin opening it from the panel) show
      // a Back button; when it's the buyer's home root, show Logout instead.
      leading: Navigator.canPop(context)
          ? const BackButton()
          : IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Logout',
              onPressed: () async {
                await SupabaseAuthService().logout();
                if (context.mounted) context.go('/login');
              },
            ),
      title: const Text('Tiles Stock'),
      actions: [
        if (!isGuest)
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: 'Add a stock catalog link',
            onPressed: _showAddCatalogDialog,
          ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _load,
        ),
        const NotificationBell(),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Row(
            children: [
              _navButton(
                'Group',
                Icons.group_outlined,
                () async {
                  await context.push('/stockist-groups');
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(width: 8),
              _navButton(
                'Stock',
                Icons.inventory_2_outlined,
                _viewDesigns ? () => setState(() => _viewDesigns = false) : null,
                active: !_viewDesigns,
              ),
              const SizedBox(width: 8),
              _navButton(
                'All Design',
                Icons.grid_view_rounded,
                _viewDesigns ? null : () => setState(() => _viewDesigns = true),
                active: _viewDesigns,
              ),
              const SizedBox(width: 8),
              _navButton(
                'My Choice',
                Icons.bookmark_outlined,
                () async {
                  await context.push('/my-choices');
                  if (mounted) setState(() {});
                },
                badgeCount: myChoiceQuantities.length,
              ),
            ],
          ),
        ),
      ),
    );

    if (_loading) {
      return Scaffold(
        appBar: appBar,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final filteredStockists = _filteredData;
    final filteredDesigns = _filteredDesigns;
    // System navigation-bar height — added to the grid's bottom padding so the
    // last row isn't clipped by the Android nav bar (edge-to-edge).
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      appBar: appBar,
      body: Column(
        children: [
          if (!isGuest && !_searchActive) _buildMarketRow(),
          if (!isGuest &&
              !_searchActive &&
              _market != 'Public' &&
              _claimedCatalogs.isNotEmpty)
            _buildManageSavedBar(),
          _buildQualityRow(),
          _buildGroupRow(
              _viewDesigns ? filteredDesigns.length : filteredStockists.length),
          if (_viewDesigns)
            ActiveFilterBar(
                filters: _activeDesignFilters(),
                onClearAll: _clearAllDesignFilters),
          Expanded(
            child: _viewDesigns
                ? filteredDesigns.isEmpty
                    ? _marketEmpty(designs: true)
                    : MasonryGridView.count(
                        padding: EdgeInsets.fromLTRB(12, 4, 12, 12 + bottomInset),
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        itemCount: filteredDesigns.length,
                        itemBuilder: (_, i) => TileCard(
                          design: filteredDesigns[i],
                          onTap: () => _openDesignSheet(i, filteredDesigns),
                          isChosen: myChoiceQuantities
                              .containsKey(filteredDesigns[i].id),
                          onChoiceTap: () => setState(() {
                            final id = filteredDesigns[i].id;
                            if (myChoiceQuantities.containsKey(id)) {
                              setMyChoiceQty(id, 0);
                            } else {
                              setMyChoiceQty(id, filteredDesigns[i].boxQuantity);
                            }
                          }),
                          onStockistTap: () => context.push(
                            '/stockist/${filteredDesigns[i].stockistId}/portfolio',
                            extra: filteredDesigns[i].id,
                          ),
                        ),
                      )
                : filteredStockists.isEmpty
                    ? _marketEmpty(designs: false)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        itemCount: filteredStockists.length,
                        itemBuilder: (_, i) => _StockistCard(
                          data: filteredStockists[i],
                          sizes: _allSizes,
                          surfaces: _allSurfaces,
                          selectedQualities: _selectedQualities,
                          selectedSizes: _selectedSizes,
                          selectedSurfaces: _selectedSurfaces,
                          matches: _matchesDesignFacets,
                          onViewProfile: () async {
                            await context.push(
                                '/stockist/${filteredStockists[i].stockist.id}/portfolio');
                            if (mounted) _load();
                          },
                          onToggleGroup: (groupIndex) async {
                            final s = filteredStockists[i].stockist;
                            final changed = await confirmToggleStockistInGroup(
                              context,
                              groupIndex: groupIndex,
                              stockistId: s.id,
                              stockistName: s.name,
                            );
                            if (changed && mounted) setState(() {});
                          },
                        ),
                      ),
          ),
          if (!_viewDesigns) _buildLegend(),
        ],
      ),
    );
  }

  // ── Group filter row ─────────────────────────────────────────────────────

  Widget _searchToggleChip({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B4F72) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? const Color(0xFF1B4F72) : Colors.grey.shade400,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: active ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : Colors.grey.shade700,
                )),
          ],
        ),
      ),
    );
  }

  Widget _groupChip(String label, bool active, VoidCallback? onTap,
      {Color? badgeColor, int? badgeNumber}) {
    final hasBadge = badgeColor != null && badgeNumber != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.fromLTRB(hasBadge ? 6 : 12, 6, 12, 6),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF1B4F72)
              : onTap == null
                  ? Colors.grey.shade50
                  : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? const Color(0xFF1B4F72)
                : onTap == null
                    ? Colors.grey.shade200
                    : Colors.grey.shade400,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasBadge) ...[
              // Same coloured numbered circle shown on the tile cards — the legend
              // that ties a group's name to its ① circle.
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.2),
                ),
                child: Center(
                  child: Text(
                    '$badgeNumber',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active
                    ? Colors.white
                    : onTap == null
                        ? Colors.grey.shade400
                        : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupRow(int count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 0, 0),
          child: Row(
            children: [
              _groupChip(
                'All',
                _activeGroupIndex == -1,
                () {
                  _dismissKeyboard();
                  setState(() => _activeGroupIndex = -1);
                },
              ),
              const SizedBox(width: 6),
              for (int i = 0; i < stockistGroups.length; i++) ...[
                _groupChip(
                  stockistGroups[i].stockistIds.isEmpty
                      ? stockistGroups[i].name
                      : '${stockistGroups[i].name} (${stockistGroups[i].stockistIds.length})',
                  _activeGroupIndex == i,
                  stockistGroups[i].stockistIds.isEmpty
                      ? null
                      : () {
                          _dismissKeyboard();
                          setState(() => _activeGroupIndex = i);
                        },
                  badgeColor: _groupColors[i % _groupColors.length],
                  badgeNumber: i + 1,
                ),
                const SizedBox(width: 6),
              ],
              // Compact people-icon action (not a chip) — opens Manage Groups.
              Tooltip(
                message: 'Manage groups',
                child: GestureDetector(
                  onTap: () async {
                    _dismissKeyboard();
                    await context.push('/stockist-groups');
                    if (mounted) {
                      setState(() {
                        if (_activeGroupIndex >= 0 &&
                            stockistGroups[_activeGroupIndex]
                                .stockistIds
                                .isEmpty) {
                          _activeGroupIndex = -1;
                        }
                      });
                    }
                  },
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      color: Color(0xFF1B4F72),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.group_add_outlined,
                        size: 18, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Text(
            _viewDesigns
                ? 'Showing $count design${count == 1 ? '' : 's'}'
                : 'Showing $count stockist${count == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  // ── Market toggle (Father & Child) ───────────────────────────────────────
  // One global control above every tab. Switching it re-filters the Group,
  // Stock and All-Design views together. Hidden for guests, who have no
  // claimed (Private / Closed Market) catalogs.
  Widget _buildMarketRow() {
    const labels = ['Public', 'Private', 'Both'];
    const brand = Color(0xFF1B4F72);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            Expanded(
              child: GestureDetector(
                onTap: () {
                  _dismissKeyboard();
                  setState(() => _market = labels[i]);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _market == labels[i] ? brand : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _market == labels[i]
                            ? brand
                            : Colors.grey.shade300),
                  ),
                  child: Text(
                    labels[i] == 'Private' && _privateDesigns.isNotEmpty
                        ? 'Private (${_privateDesigns.length})'
                        : labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _market == labels[i]
                          ? Colors.white
                          : Colors.grey.shade700,
                    ),
                  ),
                ),
              ),
            ),
            if (i < labels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  // A small "Manage saved" entry on the Private / Both market — lets the buyer
  // remove a supplier's stock catalog they previously claimed.
  Widget _buildManageSavedBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _showManageSavedSheet,
          icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
          label: Text('Manage saved (${_claimedCatalogs.length})'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF1B4F72),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }

  // Bottom sheet listing the buyer's saved (claimed) stock catalogs, each with a
  // Remove action that un-claims it (drops it from the Private market).
  Future<void> _showManageSavedSheet() async {
    var changed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final items = List<ClaimedCatalog>.from(_claimedCatalogs);
        return StatefulBuilder(
          builder: (ctx, setSheet) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text('Saved stock catalogs',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                      'Remove a supplier to stop seeing their stock in your '
                      'Private market. You can add it again with the link.',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('No saved stock catalogs.',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Colors.grey.shade200),
                        itemBuilder: (_, i) {
                          final c = items[i];
                          final title = c.stockistName.isNotEmpty
                              ? c.stockistName
                              : c.name;
                          final sub = [
                            if (c.name.isNotEmpty && c.name != title) c.name,
                            '${c.designCount} design${c.designCount == 1 ? '' : 's'}',
                            if (c.stockistCity.isNotEmpty) c.stockistCity,
                          ].join('  ·  ');
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor:
                                  const Color(0xFF1B4F72).withValues(alpha: 0.1),
                              child: const Icon(Icons.storefront_outlined,
                                  color: Color(0xFF1B4F72), size: 20),
                            ),
                            title: Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14)),
                            subtitle: Text(sub,
                                style: const TextStyle(fontSize: 12)),
                            trailing: TextButton.icon(
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Remove saved catalog?'),
                                    content: Text(
                                        'Remove "$title" from your Private '
                                        'market? You can add it again later '
                                        'with their link.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, false),
                                          child: const Text('Cancel')),
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dctx, true),
                                          child: const Text('Remove',
                                              style: TextStyle(
                                                  color: Colors.red))),
                                    ],
                                  ),
                                );
                                if (confirm != true) return;
                                try {
                                  await _service.unclaimCatalog(c.catalogId);
                                  changed = true;
                                  setSheet(() => items.removeAt(i));
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                          content: Text('$e'),
                                          backgroundColor: Colors.red));
                                }
                              },
                              icon: const Icon(Icons.delete_outline, size: 18),
                              label: const Text('Remove'),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.red),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (changed && mounted) {
      await _load(); // refresh the Private market + counts
    }
  }

  // Per-market empty placeholder. On the Private market with nothing claimed,
  // guide the buyer to paste a supplier's link instead of a bare "not found".
  Widget _marketEmpty({required bool designs}) {
    if (_market == 'Private' && _privateDesigns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              const Text('No private stock catalogs yet',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                  'When a supplier shares a private stock catalog link with you, '
                  'tap "Add a stock catalog link" to save it here.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _showAddCatalogDialog,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Add stock catalog link'),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Text(designs ? 'No designs found' : 'No stockists found',
          style: const TextStyle(color: Colors.grey)),
    );
  }

  // Pull the share token out of whatever the buyer pasted. Accepts a full link
  // containing /s/<token> or a bare alphanumeric token. Returns null for junk
  // (e.g. a random URL with no /s/… path), so we can reject it before it ever
  // reaches the server.
  static String? _resolveCatalogToken(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'/s/([A-Za-z0-9]+)').firstMatch(t);
    if (m != null) return m.group(1);
    if (RegExp(r'^[A-Za-z0-9]+$').hasMatch(t)) return t; // a bare token
    return null;
  }

  // Paste a share link → claim the stock catalog → it lands in the Private
  // market. The input is validated locally first (must contain a /s/ token or
  // be a bare token) so foreign/garbage URLs are rejected with a friendly
  // message instead of being sent to the server.
  Future<void> _showAddCatalogDialog() async {
    if (blockIfGuest(context, feature: 'Saved stock catalogs')) return;
    final ctrl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setDialog) => AlertDialog(
            title: const Text('Add a Stock Catalog'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Paste the stock catalog link your supplier shared with '
                    'you. It will be saved to your Private market.',
                    style: TextStyle(fontSize: 12.5)),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  onChanged: (_) {
                    if (error != null) setDialog(() => error = null);
                  },
                  decoration: InputDecoration(
                    hintText: 'https://tilesdesign.in/s/…',
                    isDense: true,
                    errorText: error,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () {
                    final resolved = _resolveCatalogToken(ctrl.text);
                    if (resolved == null) {
                      setDialog(() => error =
                          "That doesn't look like a stock catalog link. "
                          'Paste the full link your supplier shared (it '
                          'contains /s/…).');
                      return;
                    }
                    Navigator.pop(ctx, resolved);
                  },
                  child: const Text('Add')),
            ],
          ),
        );
      },
    );
    if (token == null) return;
    try {
      final res = await _service.claimCatalog(token);
      final name = (res['catalog_name'] ?? 'Stock catalog').toString();
      if (!mounted) return;
      await _load(); // refresh the private market + cards
      if (!mounted) return;
      setState(() => _market = 'Private'); // jump to what they just added
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved "$name" to your Private market'),
          backgroundColor: Colors.green));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  // ── Quality filter row + inline search toggle ────────────────────────────

  Widget _buildQualityRow() {
    if (_searchActive) {
      final hint = !_viewDesigns || !_searchByDesign
          ? 'Search stockist name or ID...'
          : (smartSearch
              ? 'Smart: white = bianco, carrara…'
              : 'Search design name…');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search field row
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    onSubmitted: (_) => _closeSearch(),
                    decoration: InputDecoration(
                      hintText: hint,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (_searchByDesign) ...[
                  SmartSearchToggle(onChanged: () => setState(() {})),
                  const SizedBox(width: 8),
                ],
                GestureDetector(
                  onTap: _closeSearch,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child:
                        const Icon(Icons.close, size: 20, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          // Toggle chips — only in All Design view
          if (_viewDesigns)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  _searchToggleChip(
                    label: 'Design Name',
                    icon: Icons.grid_view_rounded,
                    active: _searchByDesign,
                    onTap: () {
                      if (!_searchByDesign) {
                        _searchCtrl.clear();
                        setState(() {
                          _searchByDesign = true;
                          _searchQuery    = '';
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _searchToggleChip(
                    label: 'Stockist',
                    icon: Icons.storefront_outlined,
                    active: !_searchByDesign,
                    onTap: () {
                      if (_searchByDesign) {
                        _searchCtrl.clear();
                        setState(() {
                          _searchByDesign = false;
                          _searchQuery    = '';
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          ..._qualities.map((q) {
            final m = _qualityMeta[q]!;
            final selected = _selectedQualities.contains(q);
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  _dismissKeyboard();
                  setState(() {
                    if (selected) { _selectedQualities.remove(q); } else { _selectedQualities.add(q); }
                  });
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  decoration: BoxDecoration(
                    color: selected ? m.fg : m.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: m.fg, width: selected ? 2 : 1),
                    boxShadow: selected
                        ? [BoxShadow(
                            color: m.fg.withValues(alpha: 0.22),
                            blurRadius: 4,
                            offset: const Offset(0, 2))]
                        : [],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(m.icon, size: 12, color: selected ? Colors.white : m.fg),
                      const SizedBox(width: 3),
                      Text(q,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: selected ? Colors.white : m.fg,
                          )),
                    ],
                  ),
                ),
              ),
            );
          }),
          GestureDetector(
            onTap: () => setState(() => _searchActive = true),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1565C0), width: 1),
              ),
              child: const Icon(Icons.search, size: 16, color: Color(0xFF1565C0)),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _showDesignFilterSheet,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: (_designFilterCount) > 0
                        ? const Color(0xFF1B4F72)
                        : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_designFilterCount) > 0
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade400,
                    ),
                  ),
                  child: Icon(Icons.tune_rounded,
                      size: 16,
                      color: (_designFilterCount) > 0
                          ? Colors.white
                          : Colors.grey.shade600),
                ),
                if ((_designFilterCount) > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                            '$_designFilterCount',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if ((_designFilterCount) > 0) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => setState(() {
                _selectedSizes.clear();
                _selectedSurfaces.clear();
                _selectedTypes.clear();
                _selectedThickness.clear();
                _selectedQualities.clear();
                _designStockType = 'Both';
                _minQtyCtrl.clear();
                _maxQtyCtrl.clear();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade300),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.close, size: 12, color: Colors.red.shade700),
                    const SizedBox(width: 3),
                    Text('Clear',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.red.shade700)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Legend ────────────────────────────────────────────────────────────────

  Widget _buildLegend() {
    return Container(
      // Bottom inset clears the Android system nav bar (edge-to-edge).
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 8 + MediaQuery.of(context).viewPadding.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _legendItem(const Color(0xFFE8F5E9), const Color(0xFF388E3C), 'High stock (40+)'),
          const SizedBox(width: 16),
          _legendItem(const Color(0xFFFFEBEE), const Color(0xFFC62828), 'Zero stock'),
          const SizedBox(width: 16),
          _legendItem(const Color(0xFFF5F5F5), const Color(0xFF757575), 'Normal'),
        ],
      ),
    );
  }

  Widget _legendItem(Color bg, Color fg, String label) => Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: fg.withValues(alpha: 0.4)),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: fg)),
        ],
      );
}

// ── Stockist card ─────────────────────────────────────────────────────────────

class _StockistCard extends StatelessWidget {
  final _StockistData data;
  final List<String> sizes;
  final List<String> surfaces;
  final Set<String> selectedQualities;
  final Set<String> selectedSizes;
  final Set<String> selectedSurfaces;
  /// Full design-facet predicate (quality, size, surface, colour, type,
  /// thickness, stock type, qty range) so the card's totals/table show only
  /// designs that match every active filter.
  final bool Function(TileDesign) matches;
  final VoidCallback onViewProfile;
  final void Function(int groupIndex) onToggleGroup;

  const _StockistCard({
    required this.data,
    required this.sizes,
    required this.surfaces,
    required this.selectedQualities,
    required this.selectedSizes,
    required this.selectedSurfaces,
    required this.matches,
    required this.onViewProfile,
    required this.onToggleGroup,
  });

  // Returns (boxTable, countTable, totalBoxes, totalDesigns). Only designs that
  // pass [matches] (all active filters incl. the qty range) are counted, so the
  // totals/table reflect exactly what's filtered.
  (Map<String, Map<String, int>>, Map<String, Map<String, int>>, int, int)
      _computeDisplayData(List<String> dispSizes, List<String> dispSurfaces) {
    final filtered = data.designs.where(matches).toList();

    final totalBoxes   = filtered.fold(0, (sum, d) => sum + d.boxQuantity);
    final totalDesigns = filtered.length;

    final boxTable   = <String, Map<String, int>>{};
    final countTable = <String, Map<String, int>>{};
    for (final size in dispSizes) {
      boxTable[size]   = {};
      countTable[size] = {};
      for (final surface in dispSurfaces) {
        final cell = filtered
            .where((d) => d.size == size && d.surfaceType == surface)
            .toList();
        boxTable[size]![surface] =
            cell.fold(0, (sum, d) => sum + d.boxQuantity);
        countTable[size]![surface] = cell.length;
      }
    }
    return (boxTable, countTable, totalBoxes, totalDesigns);
  }

  @override
  Widget build(BuildContext context) {
    final s = data.stockist;
    final dispSizes = selectedSizes.isEmpty
        ? sizes
        : sizes.where((sz) => selectedSizes.contains(sz)).toList();
    final dispSurfaces = selectedSurfaces.isEmpty
        ? surfaces
        : surfaces.where((sf) => selectedSurfaces.contains(sf)).toList();
    final (boxTable, countTable, displayBoxes, displayDesigns) =
        _computeDisplayData(dispSizes, dispSurfaces);
    final qualityLabel = selectedQualities.isEmpty
        ? null
        : selectedQualities.join(' / ');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('ID: ${s.id}',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                          '$displayDesigns design${displayDesigns == 1 ? '' : 's'} · $displayBoxes boxes',
                          style: const TextStyle(
                              color: Color(0xFF1B4F72),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ),
                    if (qualityLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          qualityLabel,
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onViewProfile,
                    icon: const Icon(Icons.storefront_outlined, size: 16),
                    label: const Text('View Profile'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B4F72),
                      side: const BorderSide(color: Color(0xFF1B4F72)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ...List.generate(stockistGroups.length, (i) {
                  final inGroup = stockistGroups[i].stockistIds.contains(s.id);
                  final color = _groupColors[i];
                  return Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: GestureDetector(
                      onTap: () => onToggleGroup(i),
                      child: Tooltip(
                        message: stockistGroups[i].name,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: inGroup ? color : color.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                            border: Border.all(color: color, width: 1.5),
                          ),
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: inGroup ? Colors.white : color,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _buildTable(boxTable, countTable, dispSizes, dispSurfaces),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(
      Map<String, Map<String, int>> boxTable,
      Map<String, Map<String, int>> countTable,
      List<String> dispSizes,
      List<String> dispSurfaces) {
    const firstColW = 88.0;
    const cellW = 56.0;
    const headerH = 30.0;
    const cellH = 38.0; // taller: holds boxes on top + (designs) beneath

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _headerCell('Size', firstColW, headerH),
            ...dispSurfaces.map((sf) => _headerCell(sf, cellW, headerH)),
          ],
        ),
        ...dispSizes.map((size) => Row(
              children: [
                _sizeCell(size, firstColW, cellH),
                ...dispSurfaces.map((sf) {
                  final boxes = boxTable[size]?[sf] ?? 0;
                  final count = countTable[size]?[sf] ?? 0;
                  return _boxCell(boxes, count, cellW, cellH);
                }),
              ],
            )),
        // Legend so the bracket number is clear.
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 2),
          child: Text('boxes (designs)',
              style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        ),
      ],
    );
  }

  Widget _headerCell(String text, double w, double h) => Container(
        width: w, height: h,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
          border: Border.all(color: const Color(0xFFCCCCCC), width: 0.5),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF1B4F72)),
            textAlign: TextAlign.center),
      );

  Widget _sizeCell(String text, double w, double h) => Container(
        width: w, height: h,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          border: Border.all(color: const Color(0xFFCCCCCC), width: 0.5),
        ),
        child: Text(text.replaceAll(' mm', ''),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
      );

  // Stacked cell: box total (bold, coloured) on top, design count (small, grey)
  // in brackets beneath. Empty cells just show a dash.
  Widget _boxCell(int boxes, int count, double w, double h) {
    final Color bg;
    final Color fg;
    if (boxes == 0) {
      bg = const Color(0xFFFFEBEE); fg = const Color(0xFFC62828);
    } else if (boxes >= 40) {
      bg = const Color(0xFFE8F5E9); fg = const Color(0xFF388E3C);
    } else {
      bg = const Color(0xFFF5F5F5); fg = const Color(0xFF616161);
    }
    return Container(
      width: w, height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: const Color(0xFFCCCCCC), width: 0.5),
      ),
      child: boxes == 0
          ? Text('-',
              style: TextStyle(
                  fontSize: 12, color: fg, fontWeight: FontWeight.w600))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('$boxes',
                    style: TextStyle(
                        fontSize: 13, color: fg, fontWeight: FontWeight.bold)),
                Text('($count)',
                    style: TextStyle(
                        fontSize: 9, color: Colors.grey.shade500)),
              ],
            ),
    );
  }
}
