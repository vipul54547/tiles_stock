import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/tile_card.dart';
import '../../widgets/merged_family_grid.dart';
import '../../utils/quality_merge.dart';
import '../../widgets/quality_choice_sheet.dart';
import 'stockist_group_screen.dart'
    show stockistGroups, loadStockistGroupsFromDb, confirmToggleStockistInGroup;
import '../../models/choice_state.dart';
import '../../utils/finishes.dart';
import '../../utils/guest_gate.dart';
import '../../utils/design_ranking.dart';
import '../../utils/my_choice.dart';
import '../../utils/buyer_dna.dart';
import '../../utils/tile_types.dart';
import '../../utils/account_actions.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/smart_search_toggle.dart';

const _filterSizes      = ['600x600 mm', '800x800 mm', '300x600 mm', '1200x600 mm'];
const _filterQualities  = ['Premium', 'Standard'];
const _filterStockTypes = ['One Time', 'Continuous', 'Uncertain'];

const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
};

// Distinct from the primary blue (0xFF1B4F72) used for stockist ID / view-profile,
// so a group's coloured circle never blends with the profile identity.
const _groupColors = [Color(0xFFEF6C00), Color(0xFF2E7D32), Color(0xFF6A1B9A)];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs = [];
  // Father & Child: claimed private catalogs (the buyer's Closed Market) and the
  // active market tab — 0 Public (Open Market), 1 Private (Closed Market), 2 Both.
  List<TileDesign> _privateDesigns = [];
  int _tab = 0;
  // Finish + size options for the filter, in the admin's master order.
  List<String> _surfaceOpts = kFinishes;
  List<String> _sizeOpts = _filterSizes;
  Map<String, String> _stockistNames = {}; // seq id → name (group confirm)
  bool _loading = true;

  Set<String> _selectedSizes = {};
  Set<String> _selectedSurfaces = {};
  Set<String> _selectedTypes = {};
  Set<String> _selectedThickness = {};
  Set<String> _selectedQualities = {};
  Set<String> _selectedStockTypes = {};
  // Design DNA (image DNA) — card bottom-sheet + facet filter + DNA-aware search.
  final _dna = BuyerDna();
  final Set<String> _selectedDna = {};
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();
  int _activeGroupIndex = -1;

  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _searchActive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _closeSearch() {
    FocusManager.instance.primaryFocus?.unfocus();
    _searchCtrl.clear();
    setState(() {
      _searchQuery = '';
      _searchActive = false;
    });
  }

  Future<void> _load() async {
    final designs = await _service.getAllDesigns();
    await loadStockistGroupsFromDb(); // refresh the user's saved group filters
    await loadMyChoices();            // restore saved My Choice selections
    // Blended catalog ranking with a fresh per-session seed, so the order
    // varies each time the screen loads (app open / pull-to-refresh).
    final ranked =
        rankDesigns(designs, seed: DateTime.now().microsecondsSinceEpoch);
    // Private (claimed) designs = the buyer's Closed Market. Guests have none.
    final privateRanked = isGuest
        ? <TileDesign>[]
        : rankDesigns(await _service.getMyPrivateDesigns(),
            seed: DateTime.now().microsecondsSinceEpoch);
    final finishes = await _service.getActiveFinishNames();
    final sizes = await _service.getActiveSizeNames();
    // Stockist seq-id → name (for the group confirm dialog). Empty for guests.
    // Masked: anonymized stockists surface as trade name + public code.
    final stockists = await _service.getMarketStockists();
    // Design DNA: global catalog (once) + DNA tags for both pools' designs.
    if (!_dna.hasCatalog) await _dna.loadCatalog();
    await _dna.loadDesigns([
      for (final d in ranked) d.id,
      for (final d in privateRanked) d.id,
    ]);
    if (!mounted) return;
    setState(() {
      _designs = ranked;
      _privateDesigns = privateRanked;
      _surfaceOpts = finishes;
      _sizeOpts = sizes;
      _stockistNames = {for (final s in stockists) s.id: s.name};
      _loading = false;
    });
  }

  // Stockist display name for a sequential id (for the group confirm dialog).
  String _stockistName(String seqId) => _stockistNames[seqId] ?? '';

  // The design pool feeding the grid, per the active market tab.
  List<TileDesign> get _base {
    switch (_tab) {
      case 1:
        return _privateDesigns; // My Suppliers
      default:
        return _designs; // Discover
    }
  }

  List<TileDesign> get _filtered {
    var result = _base;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      // Also match the design's DNA tag words (e.g. "wooden", "matt").
      result = result
          .where((d) =>
              d.matchesSearch(q, smart: smartSearch) ||
              _dna.words(d.id).toLowerCase().contains(q))
          .toList();
    }
    if (_selectedDna.isNotEmpty) {
      result = result.where((d) => _dna.matches(d.id, _selectedDna)).toList();
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
    if (_selectedStockTypes.isNotEmpty) {
      result = result
          .where((d) => _selectedStockTypes.contains(d.stockType))
          .toList();
    }
    final minQty = int.tryParse(_minQtyCtrl.text);
    final maxQty = int.tryParse(_maxQtyCtrl.text);
    if (minQty != null) result = result.where((d) => d.boxQuantity >= minQty).toList();
    if (maxQty != null) result = result.where((d) => d.boxQuantity <= maxQty).toList();
    // Keep the blended ranking order from _load (was previously overridden by a
    // box-quantity sort, which clumped one stockist and never reshuffled).
    return result;
  }

  // Filtered pool folded into merged (Premium+Standard) buyer cards for the
  // banded grid. (Scenario-2 buyer merge)
  List<MergedDesign> get _mergedFiltered => mergeByQuality(_filtered);

  // Removable chips for the active-filter bar above the grid.
  List<ActiveFilter> _activeFilters() {
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
    addSet(_selectedStockTypes);
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

  void _clearAllFilters() => setState(() {
        _selectedSizes.clear();
        _selectedSurfaces.clear();
        _selectedTypes.clear();
        _selectedThickness.clear();
        _selectedQualities.clear();
        _selectedStockTypes.clear();
        _selectedDna.clear();
        _minQtyCtrl.clear();
        _maxQtyCtrl.clear();
      });

  int get _filterCount {
    int c = 0;
    if (_selectedSizes.isNotEmpty) c++;
    if (_selectedSurfaces.isNotEmpty) c++;
    if (_selectedTypes.isNotEmpty) c++;
    if (_selectedThickness.isNotEmpty) c++;
    if (_selectedQualities.isNotEmpty) c++;
    if (_selectedStockTypes.isNotEmpty) c++;
    if (_selectedDna.isNotEmpty) c++;
    if (_minQtyCtrl.text.isNotEmpty) c++;
    if (_maxQtyCtrl.text.isNotEmpty) c++;
    return c;
  }

  void _showFilterSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localTypes     = Set<String>.from(_selectedTypes);
    var localThickness = Set<String>.from(_selectedThickness);
    final thicknessBands = availableThicknessBands(_base);
    final localStockTypes = {..._selectedStockTypes};
    final localDna = {..._selectedDna};
    final dnaInUse = _dna.valueIdsInUse(_base.map((d) => d.id));
    var showMore = false; // reveal advanced facets (Tile Type, Thickness, DNA)
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.82;
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
                onTap: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  onTap();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF1B4F72) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: sel
                            ? const Color(0xFF1B4F72)
                            : Colors.grey.shade400),
                  ),
                  child: Text(label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : Colors.grey.shade700,
                      )),
                ),
              );

          // Multi-select chip group bound to a local set.
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

          // Design DNA (image DNA): one labelled chip row per attribute, showing
          // only values tagged on the current tab's designs. Chips are keyed by
          // value id (names can repeat across attributes).
          Widget dnaSection() {
            final blocks = <Widget>[];
            for (final a in _dna.facets) {
              final values = ((a['values'] as List?) ?? const [])
                  .where((v) => dnaInUse.contains((v['id'] ?? '').toString()))
                  .toList();
              if (values.isEmpty) continue;
              blocks.add(Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text((a['name'] ?? '').toString(),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12.5)),
              ));
              blocks.add(Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in values)
                    Builder(builder: (_) {
                      final id = (v['id'] ?? '').toString();
                      return filterChip(
                        (v['name'] ?? '').toString(),
                        localDna.contains(id),
                        () => setSheet(() => localDna.contains(id)
                            ? localDna.remove(id)
                            : localDna.add(id)),
                      );
                    }),
                ],
              ));
            }
            if (blocks.isEmpty) {
              return const Text('No DNA tags on these designs',
                  style: TextStyle(color: Colors.grey, fontSize: 12));
            }
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
          }

          // Live count of designs that the current (local) selections would show.
          int previewCount() {
            var r = _base;
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              r = r.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
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
            if (localStockTypes.isNotEmpty) {
              r = r.where((d) => localStockTypes.contains(d.stockType)).toList();
            }
            if (localDna.isNotEmpty) {
              r = r.where((d) => _dna.matches(d.id, localDna)).toList();
            }
            final mn = int.tryParse(_minQtyCtrl.text);
            final mx = int.tryParse(_maxQtyCtrl.text);
            if (mn != null) r = r.where((d) => d.boxQuantity >= mn).toList();
            if (mx != null) r = r.where((d) => d.boxQuantity <= mx).toList();
            return r.length;
          }

          final qtyRow = Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _minQtyCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setSheet(() {}),
                  decoration: InputDecoration(
                    hintText: 'Min',
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
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
                    hintText: 'Max',
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          );

          return SizedBox(
            height: sheetHeight,
            child: Column(
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Header row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(
                    children: [
                      const Text('Filter Designs',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setSheet(() {
                          localSizes.clear();
                          localSurfaces.clear();
                          localTypes.clear();
                          localThickness.clear();
                          localStockTypes.clear();
                          localDna.clear();
                          _minQtyCtrl.clear();
                          _maxQtyCtrl.clear();
                        }),
                        child: const Text('Reset all',
                            style: TextStyle(
                                color: Colors.red, fontSize: 13)),
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
                // Scrollable filter content
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      // Essentials — always visible.
                      FilterSection(
                        title: 'Size',
                        summary: filterSummary(localSizes),
                        child: chipWrap(_sizeOpts, localSizes),
                      ),
                      FilterSection(
                        title: 'Finish',
                        summary: filterSummary(localSurfaces),
                        child: chipWrap(_surfaceOpts, localSurfaces),
                      ),
                      FilterSection(
                        title: 'Stock Type',
                        summary: localStockTypes.isEmpty ? 'All' : localStockTypes.join(', '),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _filterStockTypes
                              .map((t) => filterChip(t, localStockTypes.contains(t),
                                  () => setSheet(() => localStockTypes.contains(t)
                                      ? localStockTypes.remove(t)
                                      : localStockTypes.add(t))))
                              .toList(),
                        ),
                      ),
                      // Advanced — behind the "More filters" toggle.
                      MoreFiltersToggle(
                        expanded: showMore,
                        activeHidden: (localTypes.isNotEmpty ? 1 : 0) +
                            (localThickness.isNotEmpty ? 1 : 0) +
                            (localDna.isNotEmpty ? 1 : 0),
                        onToggle: () => setSheet(() => showMore = !showMore),
                      ),
                      if (showMore) ...[
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
                          title: 'Design DNA',
                          summary: localDna.isEmpty
                              ? 'All'
                              : '${localDna.length} selected',
                          child: dnaSection(),
                        ),
                      ],
                    ],
                  ),
                ),
                // Footer — apply, showing the live result count.
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
        _selectedSizes     = Set<String>.from(localSizes);
        _selectedSurfaces  = Set<String>.from(localSurfaces);
        _selectedTypes     = Set<String>.from(localTypes);
        _selectedThickness = Set<String>.from(localThickness);
        _selectedStockTypes = {...localStockTypes};
        _selectedDna
          ..clear()
          ..addAll(localDna);
      });
    });
  }

  // ── Group filter row ──────────────────────────────────────────────────────

  Widget _groupChip(String label, bool active, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
        child: Text(
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
      ),
    );
  }

  Widget _buildGroupRow() {
    final chipsRow = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Row(
        children: [
          Text(
            '${_filtered.length}',
            style: const TextStyle(
              color: Color(0xFF1B4F72),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          Container(
            width: 1,
            height: 16,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: Colors.grey.shade300,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _groupChip(
                    'All',
                    _activeGroupIndex == -1,
                    () => setState(() => _activeGroupIndex = -1),
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
                          : () => setState(() => _activeGroupIndex = i),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _searchActive = !_searchActive),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: _searchActive
                    ? const Color(0xFF1565C0)
                    : const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1565C0), width: 1),
              ),
              child: Icon(
                Icons.search,
                size: 16,
                color: _searchActive ? Colors.white : const Color(0xFF1565C0),
              ),
            ),
          ),
        ],
      ),
    );

    if (!_searchActive) return chipsRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chipsRow,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  onChanged: (v) => setState(() => _searchQuery = v),
                  onSubmitted: (_) => _closeSearch(),
                  decoration: InputDecoration(
                    hintText: smartSearch
                        ? 'Smart: white = bianco, carrara…'
                        : 'Search design name…',
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
              SmartSearchToggle(onChanged: () => setState(() {})),
              const SizedBox(width: 8),
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
      ],
    );
  }

  // ── Design detail modal ───────────────────────────────────────────────────

  void _openDesign(int startIndex) {
    // Page across the merged cards' representative holdings (matches the grid).
    final list = _mergedFiltered.map((m) => m.rep).toList();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.70;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        int idx = startIndex;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final d = list[idx];
            final imageUrl = d.faceImageUrls.isNotEmpty
                ? d.faceImageUrls.first
                : '';

            return Container(
              height: sheetHeight,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(16)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Image (bottom-sheet preview → medium thumbnail, not full-size)
                  AspectRatio(
                    aspectRatio: aspectRatioFromSize(d.size),
                    child: TileImage(url: imageUrl, thumbWidth: 800),
                  ),
                  // Details
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${idx + 1} / ${list.length}',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${d.boxQuantity} boxes',
                                style: const TextStyle(
                                  color: Color(0xFF1B4F72),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
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
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              GestureDetector(
                                onTap: () {
                                  final stockistId = d.stockistId;
                                  Navigator.of(ctx).pop();
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted) context.push('/stockist/$stockistId/portfolio');
                                  });
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1B4F72)
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.25)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.storefront_outlined,
                                          size: 14,
                                          color: Color(0xFF1B4F72)),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Stockist ID: ${d.stockistId}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF1B4F72),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.arrow_forward_ios,
                                          size: 12,
                                          color: Color(0xFF1B4F72)),
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
                                  padding: const EdgeInsets.only(right: 5),
                                  child: GestureDetector(
                                    onTap: () async {
                                      final changed =
                                          await confirmToggleStockistInGroup(
                                        context,
                                        groupIndex: i,
                                        stockistId: d.stockistId,
                                        stockistName:
                                            _stockistName(d.stockistId),
                                      );
                                      if (changed) {
                                        setSheet(() {});
                                        setState(() {});
                                      }
                                    },
                                    child: Tooltip(
                                      message: stockistGroups[i].name,
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          color: inGroup
                                              ? color
                                              : color.withValues(alpha: 0.1),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: color, width: 1.5),
                                        ),
                                        child: Center(
                                          child: Text(
                                            '${i + 1}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: inGroup
                                                  ? Colors.white
                                                  : color,
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
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: idx > 0
                                      ? () => setSheet(() => idx--)
                                      : null,
                                  icon: const Icon(Icons.arrow_back_ios,
                                      size: 14),
                                  label: const Text('Prev'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        const Color(0xFF1B4F72),
                                    side: const BorderSide(
                                        color: Color(0xFF1B4F72)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: idx < list.length - 1
                                      ? () => setSheet(() => idx++)
                                      : null,
                                  icon: const Icon(
                                      Icons.arrow_forward_ios,
                                      size: 14),
                                  label: const Text('Next'),
                                  iconAlignment: IconAlignment.end,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        const Color(0xFF1B4F72),
                                    side: const BorderSide(
                                        color: Color(0xFF1B4F72)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          // Clear the system navigation bar (edge-to-edge).
                          SizedBox(
                              height: MediaQuery.of(ctx).viewPadding.bottom),
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
    );
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

  // Stockist's own finish wording (finish_label), labelled so it's distinct
  // from the standard finish chip.
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
            Text('Stockist: $name',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFE65100),
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      );

  // ── Nav button (top bar) ──────────────────────────────────────────────────

  Widget _topNavBtn(BuildContext context, String label, IconData icon,
      VoidCallback? onTap, {bool active = false}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14,
                  color: active ? const Color(0xFF1B4F72) : Colors.white),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? const Color(0xFF1B4F72) : Colors.white,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  // Discover / My Suppliers segmented tabs.
  Widget _marketTabs() {
    const labels = ['Discover', 'My Suppliers'];
    const brand = Color(0xFF1B4F72);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _tab == i ? brand : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _tab == i ? brand : Colors.grey.shade300),
                  ),
                  child: Text(
                    i == 1 && _privateDesigns.isNotEmpty
                        ? 'My Suppliers (${_privateDesigns.length})'
                        : labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _tab == i ? Colors.white : Colors.grey.shade700),
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

  // Empty-grid placeholder. On the Private tab with nothing claimed yet, guide
  // the buyer to add a supplier's catalog link.
  Widget _emptyState() {
    if (_tab == 1 && _privateDesigns.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              const Text('No private stock catalogues yet',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                  'When a supplier shares a private stock catalogue link with you, '
                  'tap "Add" to save it here.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _showAddCatalogDialog,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Add stock catalogue'),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
        child: Text('No designs found', style: TextStyle(color: Colors.grey)));
  }

  // Paste a share link → claim the catalog → it lands in the Private tab.
  Future<void> _showAddCatalogDialog() async {
    if (blockIfGuest(context, feature: 'Saved stock catalogues')) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a stock catalogue'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Paste the stock catalogue link your supplier shared with you. '
                'It will be saved to your Private tab.',
                style: TextStyle(fontSize: 12.5)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'https://tilesdesign.in/s/…',
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await _service.claimCatalog(ctrl.text);
      final name = (res['catalog_name'] ?? 'Stock catalogue').toString();
      final priv = await _service.getMyPrivateDesigns();
      await _dna.loadDesigns([for (final d in priv) d.id]);
      if (!mounted) return;
      setState(() {
        _privateDesigns = rankDesigns(priv,
            seed: DateTime.now().microsecondsSinceEpoch);
        _tab = 1; // jump to Private so they see what they just added
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved "$name" to your Private tab'),
          backgroundColor: Colors.green));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fc = _filterCount;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home'),
        ),
        title: const Text('All Designs'),
        actions: [
          if (!isGuest && currentEndUserCanClaimPrivate)
            IconButton(
              tooltip: 'Add a stock catalogue link',
              icon: const Icon(Icons.add_link),
              onPressed: _showAddCatalogDialog,
            ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () {},
              ),
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text('3',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await SupabaseAuthService().logout();
              if (context.mounted) context.go('/login');
            },
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: (v) {
              if (v == 'delete') confirmDeleteAccount(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete account')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                // Group & Stock are stockist-based — hidden for guests.
                if (!isGuest) ...[
                  _topNavBtn(context, 'Manage Group', Icons.group_outlined,
                      () {
                    if (!blockIfGuest(context, feature: 'Groups')) {
                      context.push('/stockist-groups');
                    }
                  }),
                  const SizedBox(width: 8),
                  _topNavBtn(context, 'Stock', Icons.inventory_2_outlined,
                      () => context.go('/home')),
                  const SizedBox(width: 8),
                ],
                _topNavBtn(context, 'All Design', Icons.grid_view_rounded,
                    null, active: true),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (isGuest)
                  Container(
                    width: double.infinity,
                    color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: Color(0xFF1B4F72)),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Browsing as guest — register to view stockists, '
                            'contact them and place orders.',
                            style: TextStyle(
                                fontSize: 11.5, color: Color(0xFF1B4F72)),
                          ),
                        ),
                        TextButton(
                          onPressed: () => context.push('/register'),
                          style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              minimumSize: const Size(0, 32)),
                          child: const Text('Register'),
                        ),
                      ],
                    ),
                  ),
                // Father & Child market tabs — Public / Private / Both. Hidden for
                // guests (they can't claim private catalogs).
                if (!isGuest) _marketTabs(),
                // Row 1: quality chips + filter button + clear chip
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      ..._filterQualities.map((q) {
                        final m = _qualityMeta[q]!;
                        final sel = _selectedQualities.contains(q);
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() {
                              if (sel) { _selectedQualities.remove(q); } else { _selectedQualities.add(q); }
                            }),
                            child: Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                              decoration: BoxDecoration(
                                color: sel ? m.fg : m.bg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: m.fg, width: sel ? 2 : 1),
                                boxShadow: sel
                                    ? [BoxShadow(color: m.fg.withValues(alpha: 0.22), blurRadius: 4, offset: const Offset(0, 2))]
                                    : [],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(m.icon, size: 12, color: sel ? Colors.white : m.fg),
                                  const SizedBox(width: 3),
                                  Text(q, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: sel ? Colors.white : m.fg)),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _showFilterSheet,
                            icon: const Icon(Icons.tune, size: 16),
                            label: const Text('Filter'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1B4F72),
                              side: BorderSide(
                                color: fc > 0
                                    ? const Color(0xFF1B4F72)
                                    : Colors.grey.shade400,
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          if (fc > 0)
                            Positioned(
                              top: -6,
                              right: -6,
                              child: Container(
                                width: 18,
                                height: 18,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF1B4F72),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '$fc',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (fc > 0) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => setState(() {
                            _selectedSizes.clear();
                            _selectedSurfaces.clear();
                            _selectedTypes.clear();
                            _selectedThickness.clear();
                            _selectedQualities = {};
                            _selectedStockTypes.clear();
                            _selectedDna.clear();
                            _minQtyCtrl.clear();
                            _maxQtyCtrl.clear();
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.red.shade300),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.close,
                                    size: 13, color: Colors.red.shade700),
                                const SizedBox(width: 4),
                                Text('Clear',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.red.shade700)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _buildGroupRow(),
                ActiveFilterBar(
                    filters: _activeFilters(), onClearAll: _clearAllFilters),
                Expanded(
                  child: _filtered.isEmpty
                      ? _emptyState()
                      : SingleChildScrollView(
                          child: MergedFamilyGrid(
                            cards: _mergedFiltered,
                            onOpenDetail: _openDesign,
                            isChosen: (m) => m.holdings.any((h) =>
                                myChoiceQuantities.containsKey(h.id)),
                            onChoiceTap: (m) async {
                              await showQualityChoiceSheet(context, m);
                              if (mounted) setState(() {});
                            },
                            onStockistTap: (m) => context.push(
                              '/stockist/${m.rep.stockistId}/portfolio',
                              extra: m.rep.id,
                            ),
                            // DNA chips on each card → tap opens the DNA sheet.
                            dnaTagsFor: (id) => _dna.tagsFor(id),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
