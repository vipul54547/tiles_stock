import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/tile_card.dart';
import 'stockist_group_screen.dart'
    show stockistGroups, loadStockistGroupsFromDb, confirmToggleStockistInGroup;
import '../../models/choice_state.dart';
import '../../utils/finishes.dart';
import '../../utils/guest_gate.dart';
import '../../utils/design_ranking.dart';
import '../../utils/my_choice.dart';
import '../../utils/tile_types.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/smart_search_toggle.dart';

const _filterSizes      = ['600x600 mm', '800x800 mm', '300x600 mm', '1200x600 mm'];
const _filterQualities  = ['Premium', 'Standard'];
const _filterStockTypes = ['One Time', 'Regular', 'Both'];

const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
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
  String _stockType = 'Both';
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
    final finishes = await _service.getActiveFinishNames();
    final sizes = await _service.getActiveSizeNames();
    // Stockist seq-id → name (for the group confirm dialog). Empty for guests.
    // Masked: anonymized stockists surface as trade name + public code.
    final stockists = await _service.getMarketStockists();
    if (!mounted) return;
    setState(() {
      _designs = ranked;
      _surfaceOpts = finishes;
      _sizeOpts = sizes;
      _stockistNames = {for (final s in stockists) s.id: s.name};
      _loading = false;
    });
  }

  // Stockist display name for a sequential id (for the group confirm dialog).
  String _stockistName(String seqId) => _stockistNames[seqId] ?? '';

  List<TileDesign> get _filtered {
    var result = _designs;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
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
    if (_stockType != 'Both') {
      result = result
          .where((d) => d.stockType == _stockType || d.stockType == 'Both')
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
    if (_stockType != 'Both') {
      out.add(ActiveFilter(
          _stockType, () => setState(() => _stockType = 'Both')));
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

  void _clearAllFilters() => setState(() {
        _selectedSizes.clear();
        _selectedSurfaces.clear();
        _selectedTypes.clear();
        _selectedThickness.clear();
        _selectedQualities.clear();
        _stockType = 'Both';
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
    if (_stockType != 'Both') c++;
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
    final thicknessBands = availableThicknessBands(_designs);
    var localStockType = _stockType;
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

          // Live count of designs that the current (local) selections would show.
          int previewCount() {
            var r = _designs;
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
            if (localStockType != 'Both') {
              r = r.where((d) => d.stockType == localStockType || d.stockType == 'Both').toList();
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
                          localStockType = 'Both';
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
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _filterStockTypes
                              .map((t) => filterChip(t, localStockType == t,
                                  () => setSheet(() => localStockType = t)))
                              .toList(),
                        ),
                      ),
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
        _stockType         = localStockType;
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
    final list = _filtered;
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
                            _stockType = 'Both';
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
                      ? const Center(
                          child: Text('No designs found',
                              style: TextStyle(color: Colors.grey)))
                      : MasonryGridView.count(
                          padding:
                              const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) => TileCard(
                            design: _filtered[i],
                            onTap: () => _openDesign(i),
                            isChosen: myChoiceQuantities
                                .containsKey(_filtered[i].id),
                            onChoiceTap: () => setState(() {
                              final id = _filtered[i].id;
                              if (myChoiceQuantities.containsKey(id)) {
                                setMyChoiceQty(id, 0);
                              } else {
                                setMyChoiceQty(id, _filtered[i].boxQuantity);
                              }
                            }),
                            onStockistTap: () => context.push(
                              '/stockist/${_filtered[i].stockistId}/portfolio',
                              extra: _filtered[i].id,
                            ),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
