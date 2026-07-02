import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../models/stock_catalog.dart';
import '../../models/brand.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/tile_card.dart';
import '../../widgets/dna_tag_expander.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/powered_by_tiles_stock.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/smart_search_toggle.dart';
import '../../models/choice_state.dart';
import '../../models/dna.dart';
import 'dna_editor_sheet.dart';
import 'stock_control_screen.dart';
import 'stock_lists_screen.dart';
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
  // Design DNA completeness per design: designId → fraction (0..1) of the
  // fillable DNA attributes that are tagged. Drives the corner indicator.
  Map<String, double> _dnaFill = {};
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

  // Design DNA "special search" facets — admin canonical attribute/value catalog
  // (non-free-text) + each design's tagged value ids, so the filter can offer
  // Punch/Glaze/Look/… chips alongside the structured facets. (project_design_dna_engine)
  List<DnaAttribute> _dnaAttrs = [];           // catalog, for facet chips
  Map<String, Set<String>> _dnaValues = {};    // designId → canonical value ids
  final Set<String> _selectedDna = {};         // selected canonical value ids
  // Which card's DNA-tag ▾ is currently expanded (only one at a time).
  String? _expandedDnaDesignId;
  // This stockist's own words per canonical DNA value ("My Words"), used to
  // label tags in this stockist's own wording and to widen search matching.
  Map<String, List<String>> _myWords = {};
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Count of active facets (quality has its own chips, so it's excluded here).
  int get _filterCount =>
      _selectedSizes.length +
      _selectedSurfaces.length +
      _selectedColours.length +
      _selectedTypes.length +
      _selectedThickness.length +
      _selectedDna.length +
      (_selectedStockTypes.isNotEmpty ? 1 : 0) +
      (_minQtyCtrl.text.isNotEmpty ? 1 : 0) +
      (_maxQtyCtrl.text.isNotEmpty ? 1 : 0);

  // DNA value ids present in the current in-stock pool (so empty facets hide).
  Set<String> get _dnaValuesInUse {
    final inStockIds = _inStockDesigns.map((d) => d.id).toSet();
    final used = <String>{};
    for (final entry in _dnaValues.entries) {
      if (inStockIds.contains(entry.key)) used.addAll(entry.value);
    }
    return used;
  }

  // DNA attributes that have at least one value present in the pool.
  List<DnaAttribute> get _dnaFacetAttrs {
    final inUse = _dnaValuesInUse;
    return _dnaAttrs
        .where((a) => a.values.any((v) => inUse.contains(v.id)))
        .toList();
  }

  // Faceted DNA match: within an attribute picks are OR'd, across attributes
  // AND'd. Empty selection matches everything. (mirrors the market overview)
  bool _matchesDna(TileDesign d, Set<String> selected) {
    if (selected.isEmpty) return true;
    final vals = _dnaValues[d.id] ?? const <String>{};
    for (final attr in _dnaAttrs) {
      final picked =
          attr.values.map((v) => v.id).where(selected.contains).toSet();
      if (picked.isNotEmpty && picked.intersection(vals).isEmpty) return false;
    }
    return true;
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
    // Design DNA completeness: how many of the fillable DNA attributes each
    // design is tagged with (drives the corner indicator). Bridged design→master
    // server-side by designsDnaValues.
    final dnaAttrs = await _service.dnaCatalog();
    final dnaVals =
        await _service.designsDnaValues(data.map((d) => d.id).toList());
    // This stockist's own alias words per canonical value — widens both the
    // card-tag label (own wording) and search matching beyond the admin name.
    final myWords = await _service.dnaMyWords();
    if (!mounted) return;
    final dnaFill = _computeDnaFill(data, dnaAttrs, dnaVals);
    // my_stock() doesn't return image_url — fill missing images from the
    // library (already loaded above) so dashboard cards show their photos.
    final libImgMap = {
      for (final e in library)
        if (e.imageUrl.isNotEmpty) designImageKey(e.masterName, e.size): e.imageUrl,
    };
    final enriched = data.map((d) {
      if (d.faceImageUrls.isNotEmpty) return d;
      final img = libImgMap[designImageKey(d.name, d.size)];
      return (img != null && img.isNotEmpty) ? d.withFaceImage(img) : d;
    }).toList();
    setState(() {
      _designs = enriched;
      _inquiries = inquiries;
      _pendingBoxes = pending;
      _catalogs = catalogs;
      _brands = brands;
      _library = library;
      _dnaFill = dnaFill;
      // Keep the DNA catalog (facetable: non-free-text always, free-text only
      // if opted in via showInFacets, e.g. Series) + per-design tagged values
      // for the "special search" facet chips in the filter sheet.
      _dnaAttrs =
          dnaAttrs.where((a) => !a.isFreeText || a.showInFacets).toList();
      _dnaValues = dnaVals;
      _myWords = myWords;
      // Drop a stale brand filter if that brand no longer exists.
      if (_brandFilter != 'all' && !_brands.any((b) => b.id == _brandFilter)) {
        _brandFilter = 'all';
      }
      _loading = false;
    });
  }

  // Library masters by id, for alias-aware brand lookups (M boxes are
  // brand-agnostic — they belong to a brand via their per-brand aliases).
  Map<String, LibraryEntry> get _libById =>
      {for (final e in _library) e.id: e};

  // Whether a HOLDING belongs to [brandId]. Stock is per-brand now, so a holding
  // shows only under its OWN brand — NOT under every brand whose name the master
  // carries (that would show FAMOUS boxes under ANUJ). Legacy holdings with no
  // brand on the row fall back to the master's brand/aliases. (project_per_brand_stock)
  bool _designInBrand(TileDesign d, String brandId) {
    if (d.brandId != null && d.brandId!.isNotEmpty) {
      return d.brandId == brandId;
    }
    final lib = _libById[d.libraryId];
    return lib != null &&
        (lib.brandId == brandId || lib.aliases.containsKey(brandId));
  }

  // Card title for the current view: when filtered to ONE brand, show THAT brand's
  // name for the design (its alias, e.g. ANUJ's "601001") instead of the
  // brand-agnostic master name; else the master name. (M multi-brand)
  String _designDisplayName(TileDesign d) {
    if (_brandFilter == 'all') return d.name;
    final alias = _libById[d.libraryId]?.aliases[_brandFilter];
    return (alias != null && alias.isNotEmpty) ? alias : d.name;
  }

  // Search must also match a design's brand-alias names (e.g. ANUJ "601001"),
  // not only the master name. (project_per_brand_stock)
  bool _aliasMatches(TileDesign d, String q) {
    final lib = _libById[d.libraryId];
    if (lib == null) return false;
    return lib.aliases.values.any((v) => v.toLowerCase().contains(q));
  }

  bool get _isM => currentStockistBusinessType == 'M';

  String _brandNm(String? id) {
    if (id == null) return '';
    final m = _brands.where((b) => b.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  // Group holdings by their master (library) for the "All Brands" view, preserving
  // the incoming (already-sorted) order.
  List<List<TileDesign>> _groupByMaster(List<TileDesign> list) {
    final map = <String, List<TileDesign>>{};
    final order = <String>[];
    for (final d in list) {
      final k = d.libraryId.isNotEmpty ? d.libraryId : d.id;
      final bucket = map[k];
      if (bucket == null) {
        map[k] = [d];
        order.add(k);
      } else {
        bucket.add(d);
      }
    }
    return [for (final k in order) map[k]!];
  }

  // "All Brands" card: one per master, showing the master name + a per-brand box
  // breakdown. Each brand row taps through to edit that brand's holding.
  // (project_per_brand_stock)
  Widget _masterGroupTile(List<TileDesign> group) {
    final first = group.first;
    final ratio = aspectRatioFromSize(first.size);
    final img = first.faceImageUrls.isNotEmpty ? first.faceImageUrls.first : '';
    // Total boxes across all this master's brands (the stockist's full P_Stock).
    final totalP = group.fold<int>(0, (s, d) => s + d.boxQuantity);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: ratio,
            child: TileImage(url: img, tileAspectRatio: ratio, thumbWidth: 600),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(first.name, // master name
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                    '${first.size.replaceAll(' mm', '')}'
                    '  ·  $totalP boxes',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                // Per-brand breakdown — separate boxes per brand.
                ...group.map((d) => InkWell(
                      onTap: () => context
                          .push('/stockist/stock/edit/${d.id}')
                          .then((_) => _load()),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                  _brandNm(d.brandId).isNotEmpty
                                      ? _brandNm(d.brandId)
                                      : (_brandNm(_libById[d.libraryId]?.brandId)
                                              .isNotEmpty
                                          ? _brandNm(
                                              _libById[d.libraryId]?.brandId)
                                          : '—'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF1B4F72))),
                            ),
                            Text('P ${d.boxQuantity}',
                                style: TextStyle(
                                    fontSize: 10.5, color: Colors.grey.shade600)),
                            const SizedBox(width: 8),
                            Text('F ${d.fStock}',
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2E7D32))),
                          ],
                        ),
                      ),
                    )),
                // DNA tags are set once on the shared master, so every brand's
                // holding here carries the same tags — look them up via any one
                // holding (first.id) and key the shared expand-state the same way.
                DnaTagExpander(
                  tagsByAttribute: _dnaTagsFor(first.id),
                  isExpanded: _expandedDnaDesignId == first.id,
                  onToggleExpand: () => setState(() => _expandedDnaDesignId =
                      _expandedDnaDesignId == first.id ? null : first.id),
                  onCollapseIfExpanded: () {
                    if (_expandedDnaDesignId == first.id) {
                      setState(() => _expandedDnaDesignId = null);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Stock-list helpers. The active lists in the current brand view drive the
  // dashboard's "filter by list" row; the name map labels each design's card.
  Map<String, String> get _catalogName =>
      {for (final c in _catalogs) c.id: c.name};
  // A design can be published in several lists; label it with the first one that
  // matches the current brand view (else any). (stocklist-output)
  String? _designListName(TileDesign d) {
    final ids = d.catalogIds.where(_catalogName.containsKey).toList();
    if (ids.isEmpty) return null;
    final inBrand = _brandFilter == 'all'
        ? ids.first
        : ids.firstWhere(
            (id) => _catalogs.any((c) => c.id == id && c.brandId == _brandFilter),
            orElse: () => ids.first);
    return _catalogName[inBrand];
  }
  List<StockCatalog> get _filterLists {
    var cs = _catalogs.where((c) => c.isActive);
    if (_brandFilter != 'all') {
      // Brand-free lists (v2) belong to no brand, so show them under EVERY brand
      // on the stockist's own dashboard (they're never hidden by a brand pick).
      cs = cs.where(
          (c) => c.brandId == _brandFilter || (c.brandId ?? '').isEmpty);
    }
    return cs.toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  // True when the currently visible brand slice of the library has no entries.
  // M = one pool for all brands → whole library empty.
  // T/W with a specific brand selected → only that brand's slice matters.
  bool get _isLibraryEmpty {
    if (_brandFilter == 'all') return _library.isEmpty;
    // M masters are brand-agnostic (brand_id null) — count a master under a brand
    // if it carries that brand's alias. (project_fstock_model)
    return _library.every((e) =>
        e.brandId != _brandFilter && !e.aliases.containsKey(_brandFilter));
  }


  // ── Computed ──────────────────────────────────────────────────────────────

  // Out-of-stock (0-box) designs are hidden from the dashboard's stock list,
  // its counts and filters. They still surface in the Inquiry tab if a buyer
  // wants them, so the stockist knows what to restock.
  List<TileDesign> get _inStockDesigns {
    var list = _designs.where((d) => d.boxQuantity > 0);
    if (_brandFilter != 'all') {
      list = list.where((d) => _designInBrand(d, _brandFilter));
    }
    return list.toList();
  }

  List<TileDesign> get _filteredAndSorted {
    var base = _inStockDesigns;
    // Filter by stock list (catalog). 'all' shows every list. A design can be in
    // several lists, so match membership. (stocklist-output)
    if (_catalogFilter != 'all') {
      base = base.where((d) => d.catalogIds.contains(_catalogFilter)).toList();
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
    if (_selectedDna.isNotEmpty) {
      result = result.where((d) => _matchesDna(d, _selectedDna)).toList();
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
      final terms = smartSearch ? expandSearchTerms(q) : {q};
      result = result
          .where((d) =>
              d.matchesSearch(q, smart: smartSearch) ||
              _aliasMatches(d, q) ||
              _dnaSearchMatches(d, terms))
          .toList();
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
                    await Navigator.of(context).push<bool>(MaterialPageRoute(
                        builder: (_) => const StockListsScreen()));
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
          // Brand & stock-list filters are independent — each stays as set and
          // both apply together (AND). Clear just one via its own "All" chip.
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
              // Show the list row when there's more than one list to choose, OR
              // whenever a list is currently selected — so "All lists" is always
              // reachable to clear it (even if a brand pick narrowed the list set).
              if (_filterLists.length > 1 || _catalogFilter != 'all')
                _buildCatalogFilterRow(),
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
            sliver: Builder(builder: (_) {
              // "All Brands" → one card per master with a per-brand box breakdown
              // (stock is per-brand). A specific brand → normal per-holding cards
              // showing that brand's alias name. (project_per_brand_stock)
              if (_brandFilter == 'all' && _isM) {
                final groups = _groupByMaster(designs);
                return SliverMasonryGrid.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childCount: groups.length,
                  itemBuilder: (_, i) => _masterGroupTile(groups[i]),
                );
              }
              return SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childCount: designs.length,
                itemBuilder: (_, i) => _designTile(designs[i]),
              );
            }),
          ),
      ],
    );
  }

  // Per-design DNA completeness = filled fillable-attributes / total fillable
  // attributes. "Fillable" excludes attributes that have no real value yet
  // (only "None") so e.g. an unconfigured attribute can't drag everyone down.
  Map<String, double> _computeDnaFill(List<TileDesign> designs,
      List<DnaAttribute> attrs, Map<String, Set<String>> values) {
    final fillable = attrs
        .where((a) =>
            a.isFreeText ||
            a.values.any((v) => v.name.toLowerCase() != 'none'))
        .toList();
    final total = fillable.length;
    if (total == 0) return {};
    final fillableIds = fillable.map((a) => a.id).toSet();
    final valToAttr = <String, String>{
      for (final a in attrs)
        for (final v in a.values) v.id: a.id,
    };
    final out = <String, double>{};
    for (final d in designs) {
      final vals = values[d.id] ?? const <String>{};
      final tagged = <String>{};
      for (final vid in vals) {
        final aid = valToAttr[vid];
        if (aid != null && fillableIds.contains(aid)) tagged.add(aid);
      }
      out[d.id] = tagged.length / total;
    }
    return out;
  }

  // Corner DNA indicator: shown ONLY while incomplete — full red = nothing
  // tagged, fading toward amber as more gets filled. A fully-tagged design
  // shows NO dot at all (a perfect design shouldn't be cluttered — see
  // _designTile). Tooltip shows the percent.
  Widget _dnaDot(double fill) {
    final pct = (fill * 100).round();
    final Color c =
        Color.lerp(const Color(0xFFD32F2F), const Color(0xFFF9A825), fill)!;
    return Tooltip(
      message: 'Design DNA $pct% tagged',
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2,
                offset: const Offset(0, 1)),
          ],
        ),
        child: const Icon(Icons.science, size: 12, color: Colors.white),
      ),
    );
  }

  // Tapping a design's DNA dot opens the same Design-DNA editor as the Library,
  // resolving (find-or-create) its Library master first. Refreshes the dots on
  // close so the just-tagged design updates immediately.
  Future<void> _openDnaForDesign(TileDesign d) async {
    final libId = await _service.libraryEnsureForDesign(d.id);
    if (!mounted) return;
    if (libId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open Design DNA for this design.')));
      return;
    }
    await showDnaEditor(context, libraryId: libId, designName: d.name);
    if (mounted) _load();
  }

  // The label shown for a value: this stockist's own word for it (My Words)
  // if set, else the admin's canonical name — same convention as dna_editor_sheet.
  String _dnaLabel(DnaValue v) {
    final words = _myWords[v.id];
    return (words != null && words.isNotEmpty) ? words.first : v.name;
  }

  // This design's DNA tags grouped by attribute name, for the card's
  // expandable ▾ section. Reuses the already-loaded facet catalog/values —
  // no extra fetch. (project_design_dna_engine)
  Map<String, List<String>> _dnaTagsFor(String designId) {
    final vals = _dnaValues[designId];
    if (vals == null || vals.isEmpty) return const {};
    final out = <String, List<String>>{};
    for (final attr in _dnaAttrs) {
      for (final v in attr.values) {
        if (v.name.toLowerCase() != 'none' && vals.contains(v.id)) {
          (out[attr.name] ??= []).add(_dnaLabel(v));
        }
      }
    }
    return out;
  }

  // Search match against a design's DNA tags: the canonical name AND this
  // stockist's own alias words for each tagged value. [terms] is the
  // (optionally smart-expanded) set of words typed in the search bar.
  bool _dnaSearchMatches(TileDesign d, Set<String> terms) {
    final vals = _dnaValues[d.id];
    if (vals == null || vals.isEmpty) return false;
    for (final attr in _dnaAttrs) {
      for (final v in attr.values) {
        if (v.name.toLowerCase() == 'none' || !vals.contains(v.id)) continue;
        final words = <String>{v.name.toLowerCase()};
        final mine = _myWords[v.id];
        if (mine != null) words.addAll(mine.map((w) => w.toLowerCase()));
        if (terms.any((t) => words.any((w) => w.contains(t)))) return true;
      }
    }
    return false;
  }

  Widget _designTile(TileDesign d) {
    final outOfStock = d.boxQuantity == 0;
    final lowStock = !outOfStock && d.boxQuantity < _lowStockThreshold;
    final dnaFill = _dnaFill[d.id];
    // Only flag designs that still need DNA work — fully-tagged ones show no dot.
    final showDnaDot = dnaFill != null && dnaFill < 1.0;
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
            displayName: _designDisplayName(d),
            showQuality: false, // stockist has a quality filter; chip is redundant
            showControlFigures: true, // stockist sees P · C · H · F (fstock model)
            onTap: _selectMode
                ? () {}
                : () => context.push('/stockist/stock/edit/${d.id}'),
            dnaTagsByAttribute: _dnaTagsFor(d.id),
            isDnaExpanded: _expandedDnaDesignId == d.id,
            onToggleDnaExpand: () => setState(() => _expandedDnaDesignId =
                _expandedDnaDesignId == d.id ? null : d.id),
            onCollapseDnaIfExpanded: () {
              if (_expandedDnaDesignId == d.id) {
                setState(() => _expandedDnaDesignId = null);
              }
            },
          ),
          // Stock-list badge — which list this design belongs to (shown only
          // when the brand has more than one list, so it carries information).
          // Top-right (not bottom-left): that corner is now the DNA tag ▾
          // arrow's territory, which grows taller when expanded — an
          // absolutely-positioned bottom-left badge would sit on top of it.
          // Select-mode's checkmark also lives top-right, but the two never
          // show at once.
          if (!_selectMode &&
              _filterLists.length > 1 &&
              _designListName(d) != null)
            Positioned(
              top: 6,
              right: 6,
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
          // Top-left: DNA-completeness dot (only while incomplete) + the
          // out/low-stock badge beside it when relevant.
          if (showDnaDot || outOfStock || lowStock)
            Positioned(
              top: 6,
              left: 6,
              child: Row(
                children: [
                  if (showDnaDot)
                    GestureDetector(
                      // Tap the dot → open the Design-DNA editor for this design
                      // (creating its Library master first if it has none yet).
                      onTap: () => _openDnaForDesign(d),
                      child: _dnaDot(dnaFill),
                    ),
                  if (outOfStock || lowStock) ...[
                    if (showDnaDot) const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color:
                            outOfStock ? Colors.red : Colors.orange.shade700,
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
                  ],
                ],
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

  // "+ Add" splits the two real intents BEFORE anything else, so the stockist
  // never lands on a screen that conflates them: STOCK = how many boxes (qty);
  // DESIGN = the tile's identity (name, brands, photo) in the Library.
  void _showAddIntentSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('What do you want to add?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined,
                  color: Color(0xFF2E7D32), size: 28),
              title: const Text('Stock',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              subtitle: const Text('Add or update how many boxes you have'),
              onTap: () async {
                Navigator.pop(ctx);
                final lists = _filterLists;
                await context.push('/stockist/stock/add', extra: {
                  'catalogId': lists.isEmpty ? null : lists.first.id,
                  'brandId': _brandFilter == 'all' ? null : _brandFilter,
                });
                _load();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.collections_bookmark_outlined,
                  color: Color(0xFF1B4F72), size: 28),
              title: const Text('Design',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              subtitle:
                  const Text('Add or edit a design — its name, brands and photo'),
              onTap: () async {
                Navigator.pop(ctx);
                await context.push('/stockist/library');
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showStockMgmtSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Stock Management',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            // T/W: supplier PDF is their primary stock source (library + stock together).
            if (currentStockistIsImporter) ...[
              ListTile(
                leading: const Icon(Icons.picture_as_pdf,
                    color: Color(0xFF1B4F72), size: 28),
                title: const Text('Import Supplier PDF',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: const Text('Builds your library and adds stock'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final brand = _brands.isEmpty
                      ? null
                      : (_brands.any((b) => b.id == _brandFilter)
                          ? _brands.firstWhere((b) => b.id == _brandFilter)
                          : _brands.first);
                  if (brand == null) return;
                  await context.push('/stockist/stock/import-supplier-pdf',
                      extra: brand.id);
                  _load();
                },
              ),
              const Divider(height: 1),
            ],
            ListTile(
              leading: const Icon(Icons.table_view_rounded,
                  color: Color(0xFF2E7D32), size: 28),
              title: const Text('Import Stock',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              subtitle: const Text(
                  'Add or update quantities from an Excel file'),
              onTap: () async {
                Navigator.pop(ctx);
                final brandId = _brands.any((b) => b.id == _brandFilter)
                    ? _brandFilter
                    : null;
                await context.push('/stockist/stock/import-excel',
                    extra: brandId);
                _load();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.tune,
                  color: Color(0xFF00838F), size: 28),
              title: const Text('Control Stock',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              subtitle: const Text(
                  'Block quantity you don\'t want to show to dealers'),
              onTap: () async {
                Navigator.pop(ctx);
                final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                        builder: (_) => const StockControlScreen()));
                if (changed == true) _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Row 3: Dispatch · Stock Mgmt · Add · Records (compact buttons).
  // When the library slice for the current brand is empty, only Add is active —
  // the stockist must add at least one design before they can do anything else.
  Widget _buildActionButtonRow() {
    final empty = _isLibraryEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Row(
        children: [
          _actionBtn('Dispatch', Icons.remove_circle_outline, Colors.red[700]!,
              empty ? null : _showDispatchSheet),
          const SizedBox(width: 6),
          _actionBtn('Stock Mgmt', Icons.inventory_2_outlined, const Color(0xFF1B4F72),
              empty ? null : _showStockMgmtSheet),
          const SizedBox(width: 6),
          _actionBtn('Add', Icons.add, const Color(0xFF2E7D32),
              empty ? _showLibraryActivation : _showAddIntentSheet),
          const SizedBox(width: 6),
          _actionBtn('Records', Icons.receipt_long_outlined,
              const Color(0xFF6A1B9A), empty ? null : () async {
                await context.push('/stockist/dispatches');
                _load();
              }),
        ],
      ),
    );
  }

  // Dispatch hub: dispatch against a confirmed order (the orders hub) or a quick
  // walk-in dispatch (a customer with no app/web order). (project_dispatch_order_redesign)
  void _showDispatchSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Dispatch',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined,
                  color: Color(0xFF00695C)),
              title: const Text('Dispatch an order'),
              subtitle:
                  const Text('Confirmed / dispatching orders, with reserved stock'),
              onTap: () async {
                Navigator.pop(ctx);
                await context.push('/stockist/inquiries');
                _load();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.directions_walk, color: Color(0xFFC62828)),
              title: const Text('Quick walk-in dispatch'),
              subtitle: const Text('A customer with no order — pick design + qty'),
              onTap: () async {
                Navigator.pop(ctx);
                await context.push('/stockist/stock/dispatch');
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showLibraryActivation() async {
    final initialBrandId = _brandFilter != 'all'
        ? _brandFilter
        : (_brands.isNotEmpty ? _brands.first.id : null);
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _LibraryActivationScreen(
        brands: _brands,
        initialBrandId: initialBrandId,
        businessType: currentStockistBusinessType,
      ),
    ));
    if (result == true) _load();
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
          // Smart search: synonym/multi-language expansion (white = bianco…).
          SmartSearchToggle(onChanged: () => setState(() {})),
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
        ],
      ),
    );
  }

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
    // Design DNA "special search" facets — only attributes with tagged values
    // present in the in-stock pool are offered.
    final dnaFacets = _dnaFacetAttrs;
    final dnaInUse = _dnaValuesInUse;

    // Edit a working copy of the chip selections; they're committed when the
    // sheet closes (Apply button, swipe-down, or tap-outside all apply).
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localColours   = Set<String>.from(_selectedColours);
    var localTypes     = Set<String>.from(_selectedTypes);
    var localThickness = Set<String>.from(_selectedThickness);
    final localStockTypes = {..._selectedStockTypes};
    final localDna = {..._selectedDna};
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
              final terms = smartSearch ? expandSearchTerms(q) : {q};
              r = r
                  .where((d) =>
                      d.matchesSearch(q, smart: smartSearch) ||
                      _dnaSearchMatches(d, terms))
                  .toList();
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
            if (localDna.isNotEmpty) {
              r = r.where((d) => _matchesDna(d, localDna)).toList();
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
                          localDna.clear();
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
                      // ── Design DNA "special search" facets ──────────────────
                      // One section per admin attribute (Punch/Glaze/Look/…),
                      // showing only values tagged on the in-stock pool.
                      ...dnaFacets.map((attr) {
                        final vals = attr.values
                            .where((v) => dnaInUse.contains(v.id))
                            .toList();
                        final picked = vals
                            .where((v) => localDna.contains(v.id))
                            .map((v) => v.name)
                            .toList();
                        return FilterSection(
                          title: attr.name,
                          summary: picked.isEmpty ? 'All' : picked.join(', '),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: vals
                                .map((v) => chip(
                                      v.name,
                                      localDna.contains(v.id),
                                      () => setSheet(() => localDna.contains(v.id)
                                          ? localDna.remove(v.id)
                                          : localDna.add(v.id)),
                                    ))
                                .toList(),
                          ),
                        );
                      }),
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
        _selectedDna
          ..clear()
          ..addAll(localDna);
      });
    });
  }

}

// Fixed-height pinned sliver header (search bar + count line) that stays at the
// ── Library activation screen ────────────────────────────────────────────────
// Shown the very first time a stockist (or T/W for a given brand) has no
// library entries. Only asks for the three essentials: brand (if >1), name,
// size, and an optional photo. Pops true on success so the dashboard reloads.

class _LibraryActivationScreen extends StatefulWidget {
  final List<Brand> brands;
  final String? initialBrandId;
  final String businessType; // 'M' | 'T' | 'W'
  const _LibraryActivationScreen({
    required this.brands,
    required this.businessType,
    this.initialBrandId,
  });
  @override
  State<_LibraryActivationScreen> createState() =>
      _LibraryActivationScreenState();
}

class _LibraryActivationScreenState extends State<_LibraryActivationScreen> {
  static const _navy = Color(0xFF1B4F72);

  final _data = SupabaseDataService();
  final _picker = ImagePicker();
  final _nameCtrl = TextEditingController();
  // M only: optional brand-specific alias name (defaults to masterName if blank)
  final _aliasCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _brandId;
  String _size = '';
  String _imageUrl = '';
  bool _uploading = false;
  bool _saving = false;
  List<String> _sizes = [];

  bool get _isM => widget.businessType == 'M';

  String get _activeBrandName {
    if (_brandId == null) return '';
    return widget.brands
        .firstWhere((b) => b.id == _brandId,
            orElse: () => const Brand(id: '', name: ''))
        .name;
  }

  @override
  void initState() {
    super.initState();
    _brandId = widget.initialBrandId;
    _data.getActiveSizeNames().then((s) {
      if (mounted) setState(() => _sizes = s);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aliasCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x =
        await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 88);
    if (x == null) return;
    setState(() => _uploading = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _imageUrl = url ?? '';
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_size.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please select a size.')));
      return;
    }
    setState(() => _saving = true);
    final master = _nameCtrl.text.trim();
    try {
      if (_isM) {
        // M: brand-agnostic master (brandId=null); alias under the selected brand
        // is the brand-specific name, falling back to masterName if blank.
        final aliasName = _aliasCtrl.text.trim().isEmpty
            ? master
            : _aliasCtrl.text.trim();
        await _data.upsertLibraryMaster(
          size: _size,
          masterName: master,
          imageUrl: _imageUrl,
          brandId: null,
          aliases: _brandId != null ? {_brandId!: aliasName} : {},
        );
      } else {
        // T/W: master is brand-bound; alias = same as master name.
        await _data.upsertLibraryMaster(
          size: _size,
          masterName: master,
          imageUrl: _imageUrl,
          brandId: _brandId,
          aliases: _brandId != null ? {_brandId!: master} : {},
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final multiBrand = widget.brands.length > 1;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Add first design'),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: [
            // Guidance text
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Add your first design to activate your library. '
                'After this, all other options unlock.',
                style: TextStyle(fontSize: 13.5),
              ),
            ),
            const SizedBox(height: 24),

            // Brand picker — only when multiple brands exist
            if (multiBrand) ...[
              DropdownButtonFormField<String>(
                initialValue: _brandId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Brand', border: OutlineInputBorder()),
                items: widget.brands
                    .map((b) =>
                        DropdownMenuItem(value: b.id, child: Text(b.name)))
                    .toList(),
                onChanged: (v) => _brandId = v,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Select a brand' : null,
              ),
              const SizedBox(height: 16),
            ],

            // Master design name
            TextFormField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                  labelText: 'Master design name',
                  border: OutlineInputBorder()),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Enter a design name' : null,
            ),
            const SizedBox(height: 16),

            // M only: brand-specific alias name (optional — falls back to master)
            if (_isM) ...[
              TextFormField(
                controller: _aliasCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: _activeBrandName.isEmpty
                      ? 'Name under brand (optional)'
                      : 'Name under $_activeBrandName (optional)',
                  hintText: 'Leave blank to use master name',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Size
            DropdownButtonFormField<String>(
              initialValue: _size.isEmpty ? null : _size,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Size', border: OutlineInputBorder()),
              items: _sizes
                  .map((s) => DropdownMenuItem(
                      value: s, child: Text(s.replaceAll(' mm', ''))))
                  .toList(),
              onChanged: (v) => _size = v ?? '',
              validator: (v) =>
                  v == null || v.isEmpty ? 'Select a size' : null,
            ),
            const SizedBox(height: 24),

            // Image
            Center(
              child: GestureDetector(
                onTap: _uploading ? null : _pickImage,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _uploading
                      ? const Center(child: CircularProgressIndicator())
                      : _imageUrl.isEmpty
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_a_photo_outlined,
                                    color: Colors.grey.shade400, size: 30),
                                const SizedBox(height: 6),
                                Text('Add photo (optional)',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500)),
                              ],
                            )
                          : CachedNetworkImage(
                              imageUrl: CloudinaryService.thumbUrl(
                                  _imageUrl, width: 400),
                              fit: BoxFit.cover),
                ),
              ),
            ),
            if (_imageUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: _uploading ? null : _pickImage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Change photo'),
                ),
              ),
            ],
            const SizedBox(height: 32),

            // Save
            FilledButton(
              onPressed: (_saving || _uploading) ? null : _save,
              style: FilledButton.styleFrom(
                  backgroundColor: _navy,
                  minimumSize: const Size.fromHeight(48)),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save & activate library',
                      style: TextStyle(fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }
}

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
