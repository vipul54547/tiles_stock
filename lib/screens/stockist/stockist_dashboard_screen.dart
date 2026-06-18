import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../../models/tile_design.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/tile_card.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/powered_by_tiles_stock.dart';
import '../../widgets/notification_bell.dart';
import '../../models/choice_state.dart';
import '../../utils/tile_types.dart';
import '../../utils/account_actions.dart';

class StockistDashboardScreen extends StatefulWidget {
  const StockistDashboardScreen({super.key});
  @override
  State<StockistDashboardScreen> createState() => _State();
}

const _qualities = ['Premium', 'Standard'];
const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
};

const _sortOptions = [
  (label: 'Default',          value: 'default'),
  (label: 'Name A → Z',      value: 'name_asc'),
  (label: 'Boxes: High → Low', value: 'boxes_high'),
  (label: 'Boxes: Low → High', value: 'boxes_low'),
  (label: 'Quality',           value: 'quality'),
];

const int _lowStockThreshold = 10;

// Design-Stock-Type options for the filter (multi-select; nothing selected =
// show all; 'None' isn't a stored value any more). Matches the buyer filter.
const _filterStockTypes = ['One Time', 'Continuous', 'Uncertain'];

class _State extends State<StockistDashboardScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs = [];
  // The stockist's catalogs (Father & Child) — drives the Public/Private/Both
  // inventory filter and the per-design "Private" badge.
  List<StockCatalog> _catalogs = [];
  String _catalogFilter = 'all'; // 'all' or a specific stock-list (catalog) id
  // Brands (multi-brand). Switcher shown only when the stockist has >1 brand.
  List<Brand> _brands = [];
  String _brandFilter = 'all'; // 'all' | <brandId>
  // This stockist's Design Library — to tell whether a brand is set up yet
  // (its designs/names exist) before letting them upload stock into it.
  List<LibraryEntry> _library = [];
  // Buyer My-Choice interest in this stockist's designs: designId → (buyers, boxes).
  Map<String, ({int buyers, int boxes})> _inquiries = {};
  // Boxes the stockist added that are held for admin approval (big-stock rule).
  int _pendingBoxes = 0;
  bool _loading = true;
  String get _myStockistId => currentStockistUUID;

  // Multi-select / delete mode
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  // My Stock filters — full "All Designs" facet set.
  final Set<String> _selectedQualities = {};
  final Set<String> _selectedSizes = {};
  final Set<String> _selectedSurfaces = {};
  final Set<String> _selectedColours = {};
  final Set<String> _selectedTypes = {};
  final Set<String> _selectedThickness = {};
  Set<String> _selectedStockTypes = {};
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();
  String _sortBy = 'default';
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Count of active facets (quality has its own chips, so it's excluded here).
  int get _filterCount =>
      _selectedSizes.length +
      _selectedSurfaces.length +
      _selectedColours.length +
      _selectedTypes.length +
      _selectedThickness.length +
      (_selectedStockTypes.isNotEmpty ? 1 : 0) +
      (_minQtyCtrl.text.isNotEmpty ? 1 : 0) +
      (_maxQtyCtrl.text.isNotEmpty ? 1 : 0);

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

  Future<void> _confirmDeleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Designs'),
        content: Text(
            'Delete $count design${count == 1 ? '' : 's'}? '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    for (final id in List<String>.from(_selectedIds)) {
      await _service.deleteDesign(id);
    }
    _selectMode = false;
    _selectedIds.clear();
    await _load();
  }

  Future<void> _load() async {
    final data = await _service.getDesignsByStockist(_myStockistId);
    final inquiries = await _service.getMyDesignInquiries();
    final pending = await _service.myPendingStockBoxes();
    final catalogs = await _service.getCatalogs(_myStockistId);
    final brands = await _service.getMyBrands();
    final library = await _service.getMyLibrary();
    if (!mounted) return;
    setState(() {
      _designs = data;
      _inquiries = inquiries;
      _pendingBoxes = pending;
      _catalogs = catalogs;
      _brands = brands;
      _library = library;
      // Drop a stale brand filter if that brand no longer exists.
      if (_brandFilter != 'all' && !_brands.any((b) => b.id == _brandFilter)) {
        _brandFilter = 'all';
      }
      _loading = false;
    });
  }

  // design → its catalogue's brand id (multi-brand). Null when unknown.
  Map<String, String?> get _catalogBrand =>
      {for (final c in _catalogs) c.id: c.brandId};
  String? _designBrandId(TileDesign d) =>
      d.catalogId == null ? null : _catalogBrand[d.catalogId];

  // Stock-list helpers. The active lists in the current brand view drive the
  // dashboard's "filter by list" row; the name map labels each design's card.
  Map<String, String> get _catalogName =>
      {for (final c in _catalogs) c.id: c.name};
  String? _designListName(TileDesign d) =>
      d.catalogId == null ? null : _catalogName[d.catalogId];
  List<StockCatalog> get _filterLists {
    var cs = _catalogs.where((c) => c.isActive);
    if (_brandFilter != 'all') {
      cs = cs.where((c) => c.brandId == _brandFilter);
    }
    return cs.toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }


  // ── Computed ──────────────────────────────────────────────────────────────

  // Out-of-stock (0-box) designs are hidden from the dashboard's stock list,
  // its counts and filters. They still surface in the Inquiry tab if a buyer
  // wants them, so the stockist knows what to restock.
  List<TileDesign> get _inStockDesigns {
    var list = _designs.where((d) => d.boxQuantity > 0);
    if (_brandFilter != 'all') {
      list = list.where((d) => _designBrandId(d) == _brandFilter);
    }
    return list.toList();
  }

  List<TileDesign> get _filteredAndSorted {
    var base = _inStockDesigns;
    // Filter by stock list (catalog). 'all' shows every list.
    if (_catalogFilter != 'all') {
      base = base.where((d) => d.catalogId == _catalogFilter).toList();
    }
    var result = _selectedQualities.isEmpty
        ? base
        : base
            .where((d) => _selectedQualities.contains(d.quality))
            .toList();

    if (_selectedSizes.isNotEmpty) {
      result = result.where((d) => _selectedSizes.contains(d.size)).toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      result =
          result.where((d) => _selectedSurfaces.contains(d.surfaceType)).toList();
    }
    if (_selectedColours.isNotEmpty) {
      result = result.where((d) => _selectedColours.contains(d.colour)).toList();
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
    if (minQty != null) {
      result = result.where((d) => d.boxQuantity >= minQty).toList();
    }
    if (maxQty != null) {
      result = result.where((d) => d.boxQuantity <= maxQty).toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((d) => d.name.toLowerCase().contains(q)).toList();
    }

    switch (_sortBy) {
      case 'name_asc':
        result.sort((a, b) => a.name.compareTo(b.name));
      case 'boxes_high':
        result.sort((a, b) => b.boxQuantity.compareTo(a.boxQuantity));
      case 'boxes_low':
        result.sort((a, b) => a.boxQuantity.compareTo(b.boxQuantity));
      case 'quality':
        result.sort((a, b) => a.quality.compareTo(b.quality));
    }
    return result;
  }

  List<TileDesign> get _buyerInterestDesigns =>
      _designs.where((d) => _inquiries.containsKey(d.id)).toList();

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selectMode = false;
                  _selectedIds.clear();
                }),
              ),
              title: Text(_selectedIds.isEmpty
                  ? 'Select designs'
                  : '${_selectedIds.length} selected'),
              actions: [
                if (_selectedIds.length < _filteredAndSorted.length)
                  TextButton(
                    onPressed: () => setState(() {
                      _selectedIds.addAll(
                          _filteredAndSorted.map((d) => d.id));
                    }),
                    child: const Text('All',
                        style: TextStyle(color: Colors.white)),
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed:
                      _selectedIds.isEmpty ? null : _confirmDeleteSelected,
                ),
              ],
            )
          : AppBar(
              title: const Text('My Dashboard'),
              actions: [
                // Single "Share" entry → the catalog screen (public + private
                // links live there). Replaces the old separate catalogs + share
                // icons (stockists understand "share" best).
                IconButton(
                  icon: const Icon(Icons.collections_outlined),
                  tooltip: 'My Design Library',
                  onPressed: () async {
                    await context.push('/stockist/library');
                    _load();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share my stock catalogue',
                  onPressed: () async {
                    await context.push('/stockist/catalogs');
                    _load();
                  },
                ),
                const NotificationBell(),
                IconButton(
                  icon: const Icon(Icons.logout),
                  onPressed: () async {
                    await SupabaseAuthService().logout();
                    if (!context.mounted) return;
                    context.go('/login');
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: 'Account',
                  onSelected: (v) {
                    if (v == 'delete') confirmDeleteAccount(context);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'delete', child: Text('Delete account')),
                  ],
                ),
              ],
            ),
      // Action buttons moved into the collapsing header (Dispatch / Upload /
      // Add Design row) — no floating buttons.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildMyStockScroll(),
      // Slim platform co-brand footer (hidden during multi-select). Uses
      // Align(heightFactor: 1) — NOT Center — so the bar sizes to the chip's
      // height; a Center here would expand to fill the screen and hide the body.
      bottomNavigationBar: _selectMode
          ? null
          : Container(
              color: Colors.white,
              child: const SafeArea(
                top: false,
                minimum: EdgeInsets.symmetric(vertical: 6),
                child: Align(
                  alignment: Alignment.center,
                  heightFactor: 1,
                  child: PoweredByTilesStock(logoHeight: 18),
                ),
              ),
            ),
    );
  }

  // ── Public / Private / Both filter row (pinned) ───────────────────────────
  // Brand switcher (multi-brand) — All + one chip per brand. Filters the whole
  // stock view (stats, list, facets) to the selected brand's stock.
  Widget _buildBrandFilterRow() {
    Widget chip(String value, String label) {
      final sel = _brandFilter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _brandFilter = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFF6A1B9A) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: sel ? const Color(0xFF6A1B9A) : Colors.grey.shade400),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Colors.grey.shade700)),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 2),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.sell_outlined, size: 15, color: Color(0xFF6A1B9A)),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip('all', 'All brands'),
                  for (final b in _brands)
                    if (b.isActive) chip(b.id, b.name),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Filter the stock view by stock list (All + one chip per list in the current
  // brand). Shown only when the brand has more than one list.
  Widget _buildCatalogFilterRow() {
    Widget chip(String value, String label) {
      final sel = _catalogFilter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _catalogFilter = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: sel ? const Color(0xFF1B4F72) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color:
                      sel ? const Color(0xFF1B4F72) : Colors.grey.shade300),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Colors.grey.shade700)),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 2),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.list_alt, size: 15, color: Color(0xFF1B4F72)),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip('all', 'All lists'),
                  for (final c in _filterLists) chip(c.id, c.name),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stats bar ─────────────────────────────────────────────────────────────

  // Slim, no-logo count line — pinned between the search bar and the grid.
  // Reflects the CURRENT filter/search (no filter = full in-stock totals):
  // design count on the left, total boxes on the right.
  Widget _buildCountLine() {
    final designs = _filteredAndSorted;
    final boxes = designs.fold<int>(0, (s, d) => s + d.boxQuantity);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('${designs.length} designs',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          Text('$boxes boxes',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  // Banner shown when some of the stockist's added stock is held for admin
  // approval (big-stock rule: more than 35,000 boxes added in a day). The rest
  // of their stock stays live; only the held boxes are not live yet.
  Widget _buildPendingBanner() => Container(
        width: double.infinity,
        color: const Color(0xFFFFF3E0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.hourglass_top_rounded,
                size: 16, color: Colors.orange.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Last stock is not live — $_pendingBoxes boxes awaiting admin approval.',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange.shade900),
              ),
            ),
          ],
        ),
      );

  // Slim single-line stat: icon · value · label.
  // ── Tab row ───────────────────────────────────────────────────────────────

  // Row 2 (pinned): My Stock / Buyer Interest tabs + quality chips in one
  // horizontally-scrollable row (All-Design chip style).
  Widget _buildChipRow() {
    final interestCount = _buyerInterestDesigns.length;
    return Container(
      // Extra top padding leaves room for the Inquiry badge that sits above the
      // pill, so it isn't clipped by the header.
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // Clip.none so the badge can sit above the pill without being cut off.
        clipBehavior: Clip.none,
        child: Row(
          children: [
            _tabPill('Stock', Icons.inventory_2_outlined, true, () {}),
            const SizedBox(width: 6),
            // The Inquiry pill opens the full inquiry hub (tokens, filters by
            // status/date/buyer/design, lock/dispatch) — the single place for
            // orders. Reloads the dashboard badge on return.
            _tabPill('Inquiry', Icons.receipt_long_outlined, false, () async {
              await context.push('/stockist/inquiries');
              if (mounted) _load();
            }, badge: interestCount),
            // Gap kept clear of the Inquiry badge while staying compact enough
            // that all four items fit one screen width without scrolling.
            Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(left: 9, right: 8),
                color: Colors.grey.shade300),
            ..._qualities.map((q) {
              final m = _qualityMeta[q]!;
              final sel = _selectedQualities.contains(q);
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (sel) {
                      _selectedQualities.remove(q);
                    } else {
                      _selectedQualities.add(q);
                    }
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 7),
                    decoration: BoxDecoration(
                      color: sel ? m.fg : m.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: m.fg, width: sel ? 2 : 1),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(m.icon, size: 13, color: sel ? Colors.white : m.fg),
                      const SizedBox(width: 4),
                      Text(q,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: sel ? Colors.white : m.fg)),
                    ]),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _tabPill(String label, IconData icon, bool active, VoidCallback onTap,
      {int badge = 0}) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: active ? const Color(0xFF1B4F72) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon,
                  size: 15,
                  color: active ? Colors.white : Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : Colors.grey.shade600)),
            ]),
          ),
          if (badge > 0)
            Positioned(
              top: -6,
              right: -4,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(10)),
                child: Text('$badge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
    );
  }

  // ── My Stock tab ──────────────────────────────────────────────────────────

  // My Stock: rows 1 & 2 scroll AWAY; the search bar + slim count line stay
  // PINNED at the top; the grid scrolls under them.
  Widget _buildMyStockScroll() {
    final designs = _filteredAndSorted;
    return CustomScrollView(
      slivers: [
        // Scroll-away block: pending banner, brand/list filters, the Stock/
        // Inquiry + quality chips, and the action buttons.
        SliverToBoxAdapter(
          child: Column(
            children: [
              if (_pendingBoxes > 0) _buildPendingBanner(),
              if (_brands.length > 1) _buildBrandFilterRow(),
              if (_filterLists.length > 1) _buildCatalogFilterRow(),
              _buildChipRow(),
              _buildActionButtonRow(),
            ],
          ),
        ),
        // Pinned: search/filter + the filter-aware count line.
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeaderDelegate(
            height: 86,
            child: Material(
              color: const Color(0xFFF7F9FA),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildSearchFilterRow(),
                  _buildCountLine(),
                ],
              ),
            ),
          ),
        ),
        if (designs.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
                child: Text('No designs found',
                    style: TextStyle(color: Colors.grey))),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, 12 + MediaQuery.viewPaddingOf(context).bottom),
            sliver: SliverMasonryGrid.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childCount: designs.length,
              itemBuilder: (_, i) => _designTile(designs[i]),
            ),
          ),
      ],
    );
  }

  Widget _designTile(TileDesign d) {
    final outOfStock = d.boxQuantity == 0;
    final lowStock = !outOfStock && d.boxQuantity < _lowStockThreshold;
    final isSelected = _selectedIds.contains(d.id);
    return GestureDetector(
      onLongPress: () => setState(() {
        _selectMode = true;
        _selectedIds.add(d.id);
      }),
      onTap: _selectMode
          ? () => setState(() {
                if (isSelected) {
                  _selectedIds.remove(d.id);
                } else {
                  _selectedIds.add(d.id);
                }
              })
          : null,
      child: Stack(
        children: [
          TileCard(
            design: d,
            onTap: _selectMode
                ? () {}
                : () => context.push('/stockist/stock/edit/${d.id}'),
          ),
          // Stock-list badge — which list this design belongs to (shown only
          // when the brand has more than one list, so it carries information).
          if (_filterLists.length > 1 && _designListName(d) != null)
            Positioned(
              bottom: 6,
              left: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_designListName(d)!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          if (outOfStock || lowStock)
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: outOfStock ? Colors.red : Colors.orange.shade700,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  outOfStock ? 'Out of Stock' : 'Low Stock',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          if (_selectMode)
            Positioned(
              top: 6,
              right: 6,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF1B4F72)
                      : Colors.white.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: const Color(0xFF1B4F72), width: 2),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  // Is this brand set up in the Design Library yet? (Has at least one master
  // carrying this brand's name; the default brand's masters always count.)
  bool _brandHasLibrary(Brand b) =>
      _library.any((e) => e.aliases.containsKey(b.id)) ||
      (b.isDefault && _library.isNotEmpty);

  // Does this brand already have stock (designs in any of its lists)?
  bool _brandHasStock(Brand b) {
    final listIds = _listsForBrand(b).map((c) => c.id).toSet();
    return _designs.any((d) => listIds.contains(d.catalogId));
  }

  // A brand-new brand: no Library designs AND no stock yet. Per the flow, the
  // stockist must set up its designs (Mapping) before uploading stock into it.
  bool _brandNeedsSetup(Brand b) => !_brandHasLibrary(b) && !_brandHasStock(b);

  // A brand's active stock lists (legacy null-brand lists count as the default
  // brand's). Every brand owns at least its 1 default list.
  List<StockCatalog> _listsForBrand(Brand b) =>
      _catalogs
          .where((c) =>
              c.isActive &&
              (c.brandId == b.id || (c.brandId == null && b.isDefault)))
          .toList()
        ..sort((x, y) => x.sortOrder.compareTo(y.sortOrder));

  // One "Adding to" line: a fixed-width label + the value, so Brand / List align.
  Widget _destLine(String label, String value) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(label,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1B4F72))),
          ),
        ],
      );

  // Upload is BRAND-FIRST: a stock list always belongs to one brand, so you pick
  // the BRAND, its stock list is taken automatically (only asked when the brand
  // has more than one), then the source. The chosen list — and therefore its
  // brand — is passed to the importer. PDF is offered only for the main brand
  // (others import via Excel, decision #5).
  void _showUploadSourceSheet() {
    final brands = _brands.where((b) => _listsForBrand(b).isNotEmpty).toList();
    if (brands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No stock lists to upload into yet.')));
      return;
    }
    Brand? brandOf(String? id) {
      for (final b in brands) {
        if (b.id == id) return b;
      }
      return null;
    }

    // Progressive disclosure: pick BRAND first (only when the stockist runs more
    // than one), then only THAT brand's stock list — so a list belonging to
    // another brand is never on screen to mis-tap. Single brand / single list
    // auto-resolve. Seed from the brand currently being viewed, if any.
    String? selBrandId =
        brands.any((b) => b.id == _brandFilter) ? _brandFilter : null;
    String? catId;

    // Quiet, non-blocking upsell: once a stockist SEES Brand/List as named
    // things, they realise they can ask for more — admin grants (and can charge).
    Future<void> contactAdmin() => showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Add a brand or stock list'),
            content: const Text(
                'More brands and stock lists are set up by your admin. Please '
                'contact your admin to add another one.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c), child: const Text('OK')),
            ],
          ),
        );

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          // Resolve the current step. 1 brand auto-selects; >1 forces a pick.
          final brand =
              brandOf(selBrandId) ?? (brands.length == 1 ? brands.first : null);
          final lists =
              brand == null ? <StockCatalog>[] : _listsForBrand(brand);
          // Keep a valid prior list pick; auto when the brand has exactly one.
          final effCatId = brand == null
              ? null
              : (catId != null && lists.any((c) => c.id == catId))
                  ? catId
                  : (lists.length == 1 ? lists.first.id : null);
          final mustPickBrand = brand == null;
          final mustPickList = brand != null && effCatId == null;
          final ready = effCatId != null;
          final isMainBrand = brand?.isDefault ?? false;
          final needsSetup = brand != null && _brandNeedsSetup(brand);
          // Trader / Wholesaler: ingests an arbitrary EXTERNAL supplier PDF via
          // the mapping-assisted importer (which self-builds the Library), not
          // the structured manufacturer PDF flow. See project_actor_types.
          final isImporter = currentStockistIsImporter;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // STEP 1 — choose brand (only when >1 brand and none chosen yet).
                if (mustPickBrand) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
                    child: Text('Upload to which brand?',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  for (final b in brands)
                    ListTile(
                      leading: const Icon(Icons.sell_outlined,
                          color: Color(0xFF1B4F72)),
                      title: Text(b.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setS(() {
                        selBrandId = b.id;
                        catId = null;
                      }),
                    ),
                ],
                // STEP 2 — choose this brand's stock list (only when >1, none yet).
                if (mustPickList) ...[
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 8, right: 16),
                    leading: brands.length > 1
                        ? IconButton(
                            icon: const Icon(Icons.arrow_back),
                            tooltip: 'Back to brands',
                            onPressed: () => setS(() {
                              selBrandId = null;
                              catId = null;
                            }),
                          )
                        : const Icon(Icons.inventory_2_outlined,
                            color: Color(0xFF1B4F72)),
                    title: Text('${brand.name} · choose stock list',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  for (final c in lists)
                    ListTile(
                      leading: const Icon(Icons.inventory_2_outlined,
                          color: Color(0xFF1B4F72)),
                      title: Text(c.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setS(() => catId = c.id),
                    ),
                ],
                // STEP 3 — destination resolved: show WHERE it lands, then source.
                if (ready) ...[
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3F2FD),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Adding to',
                            style: TextStyle(
                                fontSize: 11.5, color: Colors.grey.shade700)),
                        const SizedBox(height: 5),
                        _destLine('Brand', brand!.name),
                        const SizedBox(height: 2),
                        _destLine('List',
                            lists.firstWhere((c) => c.id == effCatId).name),
                        if (brands.length > 1 || lists.length > 1) ...[
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () => setS(() {
                              if (brands.length > 1) selBrandId = null;
                              catId = null;
                            }),
                            child: const Text('Change',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF1B4F72),
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Quiet, once-only upsell nudge — informs, never blocks.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: InkWell(
                      onTap: contactAdmin,
                      child: Text(
                          'Need another brand or stock list? Contact admin ›',
                          style: TextStyle(
                              fontSize: 11.5, color: Colors.grey.shade600)),
                    ),
                  ),
                  const Divider(height: 16),
                  // Source — gated by whether the brand is set up yet.
                  if (needsSetup) ...[
                  // Brand-new brand: its designs aren't in the Library, so stock
                  // has nothing to attach to. Start by mapping the designs in.
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFFE082)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Colors.orange.shade800),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isImporter
                                ? 'This brand has no designs yet. Import your '
                                    'supplier’s PDF — it builds your Library and '
                                    'adds stock in one go.'
                                : 'This brand has no designs yet. Set up its '
                                    'designs in your Library first, then upload '
                                    'stock.',
                            style: TextStyle(
                                fontSize: 12, color: Colors.orange.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Manufacturers map cross-brand design names in via Excel;
                  // importers don't (their design name IS the master), so they
                  // skip this and import the supplier PDF directly.
                  if (!isImporter)
                    ListTile(
                      leading: const Icon(Icons.account_tree_outlined,
                          color: Color(0xFF1B4F72)),
                      title: const Text('Set up designs — Mapping (Excel)'),
                      subtitle: const Text(
                          "Add this brand's designs & names to your Library"),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await context.push('/stockist/library/import-mapping');
                        _load();
                      },
                    ),
                  // PDF is main-brand only. Importers get the mapping-assisted
                  // supplier importer; manufacturers get the structured flow.
                  if (isMainBrand)
                    ListTile(
                      leading: const Icon(Icons.picture_as_pdf,
                          color: Color(0xFF1B4F72)),
                      title: Text(isImporter
                          ? 'Import supplier PDF'
                          : 'Set up from a PDF'),
                      subtitle: Text(isImporter
                          ? 'Builds your Library + adds stock'
                          : 'PDF adds your main brand designs + photos'),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await context.push(
                            isImporter
                                ? '/stockist/stock/import-supplier-pdf'
                                : '/stockist/stock/upload',
                            extra: effCatId);
                        _load();
                      },
                    ),
                ] else ...[
                  // Brand is set up — normal stock upload. PDF is main-brand only.
                  // Importers get the mapping-assisted supplier importer.
                  if (isMainBrand)
                    ListTile(
                      leading: const Icon(Icons.picture_as_pdf,
                          color: Color(0xFF1B4F72)),
                      title: Text(isImporter
                          ? 'Import supplier PDF'
                          : 'Upload PDF stock report'),
                      subtitle: Text(isImporter
                          ? 'Builds your Library + adds stock'
                          : 'Parses designs + tile photos'),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await context.push(
                            isImporter
                                ? '/stockist/stock/import-supplier-pdf'
                                : '/stockist/stock/upload',
                            extra: effCatId);
                        _load();
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.table_view_rounded,
                        color: Color(0xFF2E7D32)),
                    title: const Text('Import Excel stock list'),
                    subtitle: Text(isMainBrand
                        ? 'Design, size, quality, boxes — photos reused'
                        : 'Other brands upload by Excel'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await context.push('/stockist/stock/import-excel',
                          extra: effCatId);
                      _load();
                    },
                  ),
                ],
                ], // end if (ready)
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  // Row 3: Dispatch · Upload · Add Design · Records (compact buttons).
  Widget _buildActionButtonRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Row(
        children: [
          _actionBtn('Dispatch', Icons.remove_circle_outline, Colors.red[700]!,
              () async {
            await context.push('/stockist/stock/dispatch');
            _load();
          }),
          const SizedBox(width: 6),
          _actionBtn('Upload', Icons.upload_file, const Color(0xFF1B4F72),
              _showUploadSourceSheet),
          const SizedBox(width: 6),
          _actionBtn('Add', Icons.add, const Color(0xFF2E7D32), () async {
            // Default the new design to a list in the brand being viewed.
            final lists = _filterLists;
            await context.push('/stockist/stock/add',
                extra: lists.isEmpty ? null : lists.first.id);
            _load();
          }),
          const SizedBox(width: 6),
          _actionBtn('Records', Icons.receipt_long_outlined,
              const Color(0xFF6A1B9A), () async {
            await context.push('/stockist/dispatches');
            _load();
          }),
        ],
      ),
    );
  }

  Widget _actionBtn(
      String label, IconData icon, Color color, VoidCallback? onTap) {
    final enabled = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Column(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Always-visible search bar + Filter (All-Design sheet) + Sort.
  Widget _buildSearchFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search designs...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Filter (All-Design style) with a count badge.
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
                      color: _filterCount > 0
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade400),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              if (_filterCount > 0)
                Positioned(
                  top: -6,
                  right: -6,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: Color(0xFF1B4F72), shape: BoxShape.circle),
                    child: Center(
                      child: Text('$_filterCount',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),
          _iconBox(Icons.sort_rounded, _sortBy != 'default', _showSortSheet),
        ],
      ),
    );
  }

  Widget _iconBox(IconData icon, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1B4F72) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active
                    ? const Color(0xFF1B4F72)
                    : Colors.grey.shade300),
          ),
          child: Icon(icon,
              size: 20,
              color: active ? Colors.white : Colors.grey.shade600),
        ),
      );

  // Full "All Designs" style filter: Size, Finish, Tile Type, Thickness,
  // Colour, Stock Type and a Quantity range, with a live result count. Options
  // are derived from the stockist's in-stock designs (so no empty choices).
  void _showFilterSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    final inStock = _inStockDesigns;
    final sizes    = inStock.map((d) => d.size).toSet().toList()..sort();
    final surfaces = inStock.map((d) => d.surfaceType).toSet().toList()..sort();
    final colours  = inStock
        .map((d) => d.colour)
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final types = inStock
        .map((d) => d.tileType)
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final thicknessBands = availableThicknessBands(inStock);

    // Edit a working copy of the chip selections; they're committed when the
    // sheet closes (Apply button, swipe-down, or tap-outside all apply).
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localColours   = Set<String>.from(_selectedColours);
    var localTypes     = Set<String>.from(_selectedTypes);
    var localThickness = Set<String>.from(_selectedThickness);
    final localStockTypes = {..._selectedStockTypes};
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.82;

    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget chip(String label, bool sel, VoidCallback onTap) =>
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
                          color: sel ? Colors.white : Colors.grey.shade700)),
                ),
              );

          Widget chipWrap(List<String> options, Set<String> sel) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options
                    .map((o) => chip(o, sel.contains(o), () => setSheet(() {
                          if (sel.contains(o)) {
                            sel.remove(o);
                          } else {
                            sel.add(o);
                          }
                        })))
                    .toList(),
              );

          int previewCount() {
            var r = _inStockDesigns;
            if (_selectedQualities.isNotEmpty) {
              r = r.where((d) => _selectedQualities.contains(d.quality)).toList();
            }
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              r = r.where((d) => d.name.toLowerCase().contains(q)).toList();
            }
            if (localSizes.isNotEmpty) r = r.where((d) => localSizes.contains(d.size)).toList();
            if (localSurfaces.isNotEmpty) r = r.where((d) => localSurfaces.contains(d.surfaceType)).toList();
            if (localColours.isNotEmpty) r = r.where((d) => localColours.contains(d.colour)).toList();
            if (localTypes.isNotEmpty) r = r.where((d) => localTypes.contains(d.tileType)).toList();
            if (localThickness.isNotEmpty) {
              r = r.where((d) => localThickness.contains(thicknessBandOf(d))).toList();
            }
            if (localStockTypes.isNotEmpty) {
              r = r.where((d) => localStockTypes.contains(d.stockType)).toList();
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
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
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
                  hintText: 'Max', isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
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
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
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
                          localColours.clear();
                          localTypes.clear();
                          localThickness.clear();
                          localStockTypes.clear();
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      if (sizes.isNotEmpty)
                        FilterSection(
                          title: 'Size',
                          summary: filterSummary(localSizes),
                          child: chipWrap(sizes, localSizes),
                        ),
                      if (surfaces.isNotEmpty)
                        FilterSection(
                          title: 'Finish',
                          summary: filterSummary(localSurfaces),
                          child: chipWrap(surfaces, localSurfaces),
                        ),
                      if (types.isNotEmpty)
                        FilterSection(
                          title: 'Tile Type',
                          summary: filterSummary(localTypes),
                          child: chipWrap(types, localTypes),
                        ),
                      if (thicknessBands.isNotEmpty)
                        FilterSection(
                          title: 'Thickness (approx)',
                          summary: filterSummary(localThickness),
                          child: chipWrap(thicknessBands, localThickness),
                        ),
                      if (colours.isNotEmpty)
                        FilterSection(
                          title: 'Colour',
                          summary: filterSummary(localColours),
                          child: chipWrap(colours, localColours),
                        ),
                      FilterSection(
                        title: 'Stock Type',
                        summary: localStockTypes.isEmpty ? 'All' : localStockTypes.join(', '),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _filterStockTypes
                              .map((t) => chip(t, localStockTypes.contains(t),
                                  () => setSheet(() => localStockTypes.contains(t)
                                      ? localStockTypes.remove(t)
                                      : localStockTypes.add(t))))
                              .toList(),
                        ),
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
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1B4F72),
                            foregroundColor: Colors.white),
                        child: Text('Show ${previewCount()} designs'),
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
      // Apply on any close (Apply button, swipe-down, or tap-outside). Qty
      // fields edit the live controllers, so they're already current.
      setState(() {
        _selectedSizes
          ..clear()
          ..addAll(localSizes);
        _selectedSurfaces
          ..clear()
          ..addAll(localSurfaces);
        _selectedColours
          ..clear()
          ..addAll(localColours);
        _selectedTypes
          ..clear()
          ..addAll(localTypes);
        _selectedThickness
          ..clear()
          ..addAll(localThickness);
        _selectedStockTypes = {...localStockTypes};
      });
    });
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Icon(Icons.sort_rounded, color: Color(0xFF1B4F72)),
                SizedBox(width: 8),
                Text('Sort By',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
          ),
          const Divider(height: 1),
          ..._sortOptions.map((opt) => ListTile(
                title: Text(opt.label),
                trailing: _sortBy == opt.value
                    ? const Icon(Icons.check_rounded,
                        color: Color(0xFF1B4F72))
                    : null,
                onTap: () {
                  setState(() => _sortBy = opt.value);
                  Navigator.pop(context);
                },
              )),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

}

// Fixed-height pinned sliver header (search bar + count line) that stays at the
// top while rows 1 & 2 scroll away beneath the app bar.
class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  _PinnedHeaderDelegate({required this.child, required this.height});

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox.expand(child: child);

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _PinnedHeaderDelegate old) =>
      old.height != height || old.child != child;
}
