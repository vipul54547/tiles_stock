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
import '../../widgets/family_correction_sheet.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/powered_by_tiles_stock.dart';
import '../../widgets/notification_bell.dart';
import '../../widgets/smart_search_toggle.dart';
import '../../models/choice_state.dart';
import '../../models/dna.dart';
import 'dna_editor_sheet.dart';
import 'stock_control_screen.dart';
import 'stock_lists_screen.dart';
import 'book_order_screen.dart';
import 'stockist_add_order_screen.dart';
import 'customer_history_screen.dart';
import 'stockist_profile_screen.dart';
import 'stockist_my_videos_screen.dart';
import '../../utils/tile_types.dart';

class StockistDashboardScreen extends StatefulWidget {
  const StockistDashboardScreen({super.key});
  @override
  State<StockistDashboardScreen> createState() => _State();
}

const _qualities = ['Premium', 'Standard'];

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
  // Count of NEW orders awaiting action (status 'sent') — app AND web/walk-in —
  // drives the Inquiry pill badge. (my_design_inquiries only sees app baskets, so
  // a web order wouldn't otherwise show a number.)
  int _newOrders = 0;
  // Design DNA completeness per design: designId → fraction (0..1) of the
  // fillable DNA attributes that are tagged. Drives the corner indicator.
  Map<String, double> _dnaFill = {};
  // Boxes the stockist added that are held for admin approval (big-stock rule).
  int _pendingBoxes = 0;
  bool _loading = true;
  String get _myStockistId => currentStockistUUID;

  // 🧱 LOT L4 — a holding's batch/location breakdown, for HIS card only (never
  // buyer-facing: these tiles are the stockist dashboard's own, and the RPC is
  // stockist-authed). holding id → its lots; which cards have the strip expanded.
  Map<String, List<Map<String, dynamic>>> _stockLots = {};
  final Set<String> _lotsOpen = {};
  bool get _lotsTracked =>
      currentStockistTrackBatches || currentStockistTrackLocations;

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
  // Punch/Look/Colour/… chips alongside the structured facets. (project_design_dna_engine)
  List<DnaAttribute> _dnaAttrs = [];           // catalog, for facet chips
  Map<String, Set<String>> _dnaValues = {};    // designId → canonical value ids
  final Set<String> _selectedDna = {};         // selected canonical value ids
  // This stockist's own words per canonical DNA value ("My Words"), used to
  // label tags in this stockist's own wording and to widen search matching.
  Map<String, List<String>> _myWords = {};
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Count of active facets. Quality is counted here now that it lives inside the
  // filter rather than as its own header chips. (project_dashboard_ia)
  int get _filterCount =>
      _selectedSizes.length +
      _selectedQualities.length +
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
    // "Surface" has its own dedicated surface filter (folds attribute + in_name),
    // so exclude it here to avoid a second surface facet.
    return _dnaAttrs
        .where((a) =>
            a.name.toLowerCase() != 'surface' &&
            a.values.any((v) => inUse.contains(v.id)))
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
    // Delete every selected design even if one fails, then report the first
    // failure — a half-finished loop must still leave the list consistent.
    Object? failure;
    for (final id in List<String>.from(_selectedIds)) {
      try {
        await _service.deleteDesign(id);
      } catch (e) {
        failure ??= e;
      }
    }
    _selectMode = false;
    _selectedIds.clear();
    await _load();
    if (!mounted || failure == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Some designs could not be deleted: $failure'),
        backgroundColor: Colors.red.shade700));
  }

  Future<void> _load() async {
    final data = await _service.getDesignsByStockist(_myStockistId);
    final inquiries = await _service.getMyDesignInquiries();
    final orders = await _service.getMyInquiries();
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
    // 🧱 The batch/location lots behind each holding (stockist-only). Only when he
    // tracks batch or location; otherwise there's nothing to break down.
    final stockLots =
        _lotsTracked ? await _service.myStockLots() : <String, List<Map<String, dynamic>>>{};
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
      _stockLots = stockLots;
      _forkLabels = thicknessForkLabels(enriched);
      _inquiries = inquiries;
      _newOrders = orders.where((o) => o.status == 'sent').length;
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

  /// 🎁 **THE WORD ON THE DEFAULT BRAND'S BOX** for this design — `HG ALASKA BLACK`, not the
  /// artwork's own name `ALASKA BLACK`.
  ///
  /// 🔑 The card is a thing he SELLS, and what he sells is a BOX with a word printed on it. The
  /// artwork name is the name of the picture; it is his private word for the design and it is not
  /// what the customer asks for. Falls back to the artwork name only when the default brand has no
  /// word for this design yet — honest blank, never invented.
  String _defaultCoverWord(String libraryId, String fallback) {
    final lib = _libById[libraryId];
    if (lib == null) return fallback;
    final def = _brands.where((b) => b.isDefault).firstOrNull;
    final w = def == null ? null : lib.aliases[def.id];
    return (w != null && w.trim().isNotEmpty) ? w.trim() : fallback;
  }

  /// The word a given brand prints for this design, or '' when it has none.
  String _coverWordOf(String libraryId, String? brandId) {
    if (brandId == null) return '';
    return (_libById[libraryId]?.aliases[brandId] ?? '').trim();
  }

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
  /// library_id -> "11.5–12.0 mm", for products FORKED off a print by a genuinely different
  /// thickness. Without it, the fork and its original are two identical rows on this screen.
  Map<String, String> _forkLabels = const {};

  String _designDisplayName(TileDesign d) {
    final base = _brandFilter == 'all'
        ? d.name
        : (() {
            final alias = _libById[d.libraryId]?.aliases[_brandFilter];
            return (alias != null && alias.isNotEmpty) ? alias : d.name;
          })();
    final fork = _forkLabels[d.libraryId];
    return fork == null ? base : '$base ($fork)';
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
  // ── Concept-family bands ────────────────────────────────────────────────────
  // Designs sharing (size + familyKey) are variants of one concept (1801-A /
  // 1801-B / …). Standalone cards flow in the normal 2-col masonry; each family
  // (>=2 members) is pulled out into one full-width band ringed by a thin colour
  // so the eye reads them as a set — cards stay separate inside. (design family P2)
  static const List<Color> _familyColors = [
    Color(0xFF1B9E77), Color(0xFFD95F02), Color(0xFF7570B3),
    Color(0xFFE7298A), Color(0xFF66A61E), Color(0xFFE6AB02),
    Color(0xFFA6761D), Color(0xFF1F78B4),
  ];
  Color _famColorFor(String gk) =>
      _familyColors[gk.hashCode.abs() % _familyColors.length];

  List<Widget> _gridSlivers(List<TileDesign> designs) {
    final bool masterMode = _brandFilter == 'all' && _isM;
    // A "unit" = one card. In master mode a card is a per-master group; else a
    // single holding. gk (size|familyKey) ties same-size family members together;
    // libId (the master) tells same-design quality/brand splits apart.
    final List<({String gk, String libId, Widget child})> units = [];
    if (masterMode) {
      for (final g in _groupByMaster(designs)) {
        final f = g.first;
        units.add((
          gk: f.familyKey.isEmpty ? '' : '${f.size}|${f.familyKey}',
          libId: f.libraryId.isNotEmpty ? f.libraryId : f.id,
          child: _masterGroupTile(g),
        ));
      }
    } else {
      // Single brand: merge each master's Premium + Standard holdings into one
      // card (group by master, like All-brands but per-quality). (per-brand P2)
      for (final g in _groupByMaster(designs)) {
        final f = g.first;
        units.add((
          gk: f.familyKey.isEmpty ? '' : '${f.size}|${f.familyKey}',
          libId: f.libraryId.isNotEmpty ? f.libraryId : f.id,
          child: _brandDesignTile(g),
        ));
      }
    }
    // A real family needs >=2 DISTINCT masters. The same design split into
    // Premium + Standard (or across brands) shares one library_id, so it must
    // NOT be ringed as a family of itself. (design family P2)
    final famMasters = <String, Set<String>>{};
    for (final u in units) {
      if (u.gk.isNotEmpty) (famMasters[u.gk] ??= <String>{}).add(u.libId);
    }
    // Build a flat list of blocks (standalone-card runs + family bands), then put
    // them ALL inside ONE SliverToBoxAdapter. Deliberate: a SliverMasonryGrid
    // mis-reports its scroll extent whenever another sliver follows it (→ endless
    // scroll), so we avoid sliver grids and lay everything out with non-scrolling
    // StaggeredGrids in a single box. (design family P2)
    final blocks = <Widget>[];
    final emitted = <String>{};
    var run = <Widget>[];
    void flushRun() {
      if (run.isEmpty) return;
      final items = run;
      run = [];
      blocks.add(_staggeredRun(items));
    }

    for (final u in units) {
      final isFamily = u.gk.isNotEmpty && (famMasters[u.gk]?.length ?? 0) >= 2;
      if (!isFamily) {
        run.add(u.child);
        continue;
      }
      if (emitted.contains(u.gk)) continue; // later member — already banded
      emitted.add(u.gk);
      flushRun();
      final members = [for (final x in units) if (x.gk == u.gk) x.child];
      blocks.add(_familyBand(u.gk, members));
    }
    flushRun();

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(
              top: 12, bottom: MediaQuery.viewPaddingOf(context).bottom + 12),
          child: Column(
            children: [
              for (var i = 0; i < blocks.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                blocks[i],
              ],
            ],
          ),
        ),
      ),
    ];
  }

  // Columns for the stock grid, computed from the grid's ACTUAL width (robust to
  // Windows display scaling / the sidebar width). Phone stays 2; desktop fills
  // the space with ~180px tiles (≈6 on a normal desktop, up to 8 on wide ones).
  int _colsForWidth(double w) {
    if (MediaQuery.sizeOf(context).width < 700) return 2; // phone
    return (w / 180).floor().clamp(3, 8);
  }

  // A run of standalone cards → a non-scrolling masonry (StaggeredGrid).
  Widget _staggeredRun(List<Widget> items) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: LayoutBuilder(
          builder: (context, c) => StaggeredGrid.count(
            crossAxisCount: _colsForWidth(c.maxWidth),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final w in items)
                StaggeredGridTile.fit(crossAxisCellCount: 1, child: w),
            ],
          ),
        ),
      );

  // One family: a thin coloured rounded ring around the member cards. Each card
  // stays a normal separate card; the ring just encircles the concept group.
  Widget _familyBand(String gk, List<Widget> members) {
    final color = _famColorFor(gk);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.4),
          borderRadius: BorderRadius.circular(14),
          color: color.withValues(alpha: 0.04),
        ),
        padding: const EdgeInsets.all(8),
        // StaggeredGrid is a NON-scrolling widget (unlike MasonryGridView), so it
        // never nests a scrollable inside the outer CustomScrollView. .fit tiles
        // size to their own height → masonry look without a scroll-extent fight.
        child: LayoutBuilder(
          builder: (context, c) => StaggeredGrid.count(
            crossAxisCount: _colsForWidth(c.maxWidth),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              for (final m in members)
                StaggeredGridTile.fit(crossAxisCellCount: 1, child: m),
            ],
          ),
        ),
      ),
    );
  }

  List<List<TileDesign>> _groupByMaster(List<TileDesign> list) {
    final map = <String, List<TileDesign>>{};
    final order = <String>[];
    for (final d in list) {
      // A card merges a print's Premium + Standard holdings. The SURFACE no longer
      // needs to key the group: it is now part of the product's identity, so each
      // surface is already its OWN library row. library_id alone says which product
      // this is, surface included.
      //
      // It used to append surfaceType|surfaceLabel. That broke the rule CLAUDE.md
      // states outright — "surface_label is display-only, NOT part of the key" — and it
      // split one design into two cards the moment two holdings of the same product
      // disagreed about the word (one 'MATT', one empty). Never key on the word.
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

  // Quality fonts on the All-brands card: premium = amber, standard = blue
  // (same colours as the quality filter buttons / _qualityMeta).
  static const _premColor = Color(0xFFF9A825);
  static const _stdColor = Color(0xFF1565C0);

  // "All Brands" card: one per master. Header = name + size·grand-total; then one
  // row PER BRAND showing that brand's P & F split into premium (amber) + standard
  // (blue); surface alias badge over the image. Tapping a brand row edits the
  // holding (or asks Premium/Standard when the brand has both). (per-brand + quality)
  Widget _masterGroupTile(List<TileDesign> group) {
    final first = group.first;
    final ratio = aspectRatioFromSize(first.size);
    final img = first.faceImageUrls.isNotEmpty ? first.faceImageUrls.first : '';
    // Total boxes across all this master's brands + qualities (full P_Stock).
    final totalP = group.fold<int>(0, (s, d) => s + d.boxQuantity);
    final surface = first.surfaceCardLabel;
    final showSurface = surface.isNotEmpty && surface.toLowerCase() != 'none';

    // Sub-group the holdings by brand (keeping first-seen order); within a brand
    // the Premium/Standard holdings are shown inline on one row.
    final byBrand = <String?, List<TileDesign>>{};
    final brandOrder = <String?>[];
    for (final d in group) {
      final bId = (d.brandId != null && d.brandId!.isNotEmpty)
          ? d.brandId
          : _libById[d.libraryId]?.brandId;
      final list = byBrand[bId];
      if (list == null) {
        byBrand[bId] = [d];
        brandOrder.add(bId);
      } else {
        list.add(d);
      }
    }

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
          Stack(
            children: [
              AspectRatio(
                aspectRatio: ratio,
                child:
                    TileImage(url: img, tileAspectRatio: ratio, thumbWidth: 600),
              ),
              if (showSurface)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      first.finishLabel != null && first.finishLabel!.isNotEmpty
                          ? '$surface · ${first.finishLabel}'
                          : surface,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              // Top-left: round DNA button (same affordance as the 1-brand card).
              Positioned(top: 6, left: 6, child: _dnaButton(first)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 🎁 The word on the DEFAULT brand's box — what he actually sells and what a
                // customer asks for. NOT the artwork's own name, which is his private word for
                // the picture. (Falls back to it only when the default brand has no word yet.)
                Text(_defaultCoverWord(first.libraryId, first.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                // Size on the left, grand total on the right (dark gray).
                Row(
                  children: [
                    Expanded(
                      child: Text(first.size.replaceAll(' mm', ''),
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.grey.shade600)),
                    ),
                    Text('$totalP boxes',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700)),
                  ],
                ),
                const SizedBox(height: 6),
                // One row per brand: chip + P(prem+std) + F(prem+std=total).
                ...brandOrder.map((bId) =>
                    _brandStockRow(bId, byBrand[bId]!, first.libraryId)),
                const SizedBox(height: 4),
                _familyChip(first.libraryId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // One brand's row on the All-brands card. Premium + Standard holdings of that
  // brand are shown inline (amber + blue). Tap → edit; if both qualities exist,
  // ask which one first. (per-brand + quality)
  Widget _brandStockRow(String? bId, List<TileDesign> holds, String libraryId) {
    // Resolve the brand label. A brand-agnostic holding (no brand_id at all) is an
    // M "shared box" → label it with the main (default) brand rather than blank.
    final resolved = _brandNm(bId);
    final String name;
    if (resolved.isNotEmpty) {
      name = resolved;
    } else if (bId == null) {
      final def = _brands.where((b) => b.isDefault).toList();
      name = def.isNotEmpty ? def.first.name : '—';
    } else {
      name = '—';
    }
    TileDesign? prem, std;
    for (final d in holds) {
      if (d.quality == 'Premium') {
        prem = d;
      } else if (d.quality == 'Standard') {
        std = d;
      } else {
        prem ??= d; // any other quality shares the premium slot
      }
    }
    final both = prem != null && std != null;
    return InkWell(
      onTap: () {
        if (both) {
          _showQualityChooser(prem!, std!);
        } else {
          final d = prem ?? std!;
          context.push('/stockist/stock/edit/${d.id}').then((_) => _load());
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Brand name on its own row (full width) so it never truncates.
            Row(
              children: [
                Flexible(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                        color: const Color(0xFF1B4F72),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
                _coverWordMark(libraryId, bId),
              ],
            ),
            const SizedBox(height: 3),
            // P & F values on the next row.
            Row(
              children: [
                _pfCluster('P', prem?.boxQuantity, std?.boxQuantity),
                const SizedBox(width: 12),
                _pfCluster('F', prem?.fStock, std?.fStock, showTotal: true),
              ],
            ),
            _lotSection(prem, std),
            // Control (hidden) + Held (booked) — shown only when there's something
            // to show, so plain in-stock tiles stay clean. (desktop detail set)
            if (((prem?.controlQuantity ?? 0) + (std?.controlQuantity ?? 0) +
                    (prem?.heldQuantity ?? 0) + (std?.heldQuantity ?? 0)) >
                0) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  _chCluster('Ctrl', prem?.controlQuantity, std?.controlQuantity,
                      Colors.grey.shade600),
                  const SizedBox(width: 12),
                  _chCluster('Held', prem?.heldQuantity, std?.heldQuantity,
                      const Color(0xFF6A1B9A)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 🏷️ **Does this brand print its OWN word, or the default brand's?**
  ///
  /// The card title already shows the DEFAULT brand's word. For every other brand there are only
  /// two interesting answers, and he must be able to tell them apart at a glance without the card
  /// growing a second column of names:
  ///
  ///   • **`(default)`** — this brand prints the same word. Nothing to look up. Grey, quiet.
  ///   • **🏷️ tag** — this brand has a word of its OWN. Tap it and the word appears.
  ///
  /// The default brand itself gets no mark — its word IS the title.
  Widget _coverWordMark(String libraryId, String? brandId) {
    if (brandId == null) return const SizedBox.shrink();
    final def = _brands.where((b) => b.isDefault).firstOrNull;
    if (def != null && brandId == def.id) return const SizedBox.shrink();

    final mine = _coverWordOf(libraryId, brandId);
    if (mine.isEmpty) return const SizedBox.shrink(); // no word of its own — say nothing

    final defWord = def == null ? '' : _coverWordOf(libraryId, def.id);
    final same = defWord.isNotEmpty &&
        mine.toLowerCase() == defWord.toLowerCase();

    if (same) {
      return Padding(
        padding: const EdgeInsets.only(left: 5),
        child: Text('(default)',
            style: TextStyle(fontSize: 9.5, color: Colors.grey.shade500)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: () {
          final brand = _brandNm(brandId);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 4),
            backgroundColor: const Color(0xFF1B4F72),
            content: Text('$brand prints:  $mine',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ));
        },
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(Icons.sell_outlined,
              size: 13, color: Colors.orange.shade800),
        ),
      ),
    );
  }

  // Secondary figures (Control / Held) — one muted colour, premium+standard summed
  // (these rarely split and don't need the amber/blue coding P/F carry).
  Widget _chCluster(String label, int? prem, int? std, Color color) {
    final total = (prem ?? 0) + (std ?? 0);
    final gray = TextStyle(fontSize: 10, color: Colors.grey.shade500);
    return Text.rich(TextSpan(children: [
      TextSpan(text: '$label ', style: gray),
      TextSpan(
          text: '$total',
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.bold, color: color)),
    ]));
  }

  // "P(8+2)" / "F(6+2=8)" — premium amber, standard blue; frame + total in gray.
  // A single quality shows just its own coloured number, no "+".
  /// 🧱 LOT L4 — the batch/location breakdown for a card's holding(s), as an
  /// expandable strip. Shown only when he tracks batch/location AND there's more
  /// than one real lot to see. This lives on HIS dashboard tiles alone; buyers
  /// never see it. Combines the Premium and Standard holdings of the card.
  Widget _lotSection(TileDesign? prem, TileDesign? std) {
    if (!_lotsTracked) return const SizedBox.shrink();
    final lots = <Map<String, dynamic>>[];
    for (final id in [prem?.id, std?.id]) {
      if (id != null) lots.addAll(_stockLots[id] ?? const []);
    }
    final real = lots
        .where((l) =>
            (l['batch'] ?? '').toString().isNotEmpty ||
            (l['location'] ?? '').toString().isNotEmpty)
        .toList();
    if (real.length < 2) return const SizedBox.shrink();
    final key = prem?.id ?? std?.id ?? '';
    final open = _lotsOpen.contains(key);
    const navy = Color(0xFF1B4F72);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(
                () => open ? _lotsOpen.remove(key) : _lotsOpen.add(key)),
            borderRadius: BorderRadius.circular(4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.inventory_2_outlined, size: 12, color: navy),
              const SizedBox(width: 3),
              Text('${real.length} batches',
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700, color: navy)),
              Icon(open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 16, color: navy),
            ]),
          ),
          if (open)
            for (final l in real) _lotLine(l),
        ],
      ),
    );
  }

  Widget _lotLine(Map<String, dynamic> l) {
    final batch = (l['batch'] ?? '').toString();
    final loc = (l['location'] ?? '').toString();
    final n = (l['box_quantity'] as num?)?.toInt() ?? 0;
    final label = [
      if (batch.isNotEmpty) 'Batch $batch',
      if (loc.isNotEmpty) '📍 $loc',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Row(children: [
        Expanded(
          child: Text(label.isEmpty ? 'No batch' : label,
              style: const TextStyle(fontSize: 10.5)),
        ),
        Text('$n',
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Color(0xFFC62828))),
      ]),
    );
  }

  Widget _pfCluster(String label, int? prem, int? std, {bool showTotal = false}) {
    final gray = TextStyle(fontSize: 10.5, color: Colors.grey.shade600);
    final spans = <InlineSpan>[TextSpan(text: '$label(', style: gray)];
    var first = true;
    if (prem != null) {
      spans.add(TextSpan(
          text: '$prem',
          style: const TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.bold, color: _premColor)));
      first = false;
    }
    if (std != null) {
      if (!first) spans.add(TextSpan(text: '+', style: gray));
      spans.add(TextSpan(
          text: '$std',
          style: const TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.bold, color: _stdColor)));
    }
    if (showTotal && prem != null && std != null) {
      spans.add(TextSpan(
          text: '=${prem + std}',
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800)));
    }
    spans.add(TextSpan(text: ')', style: gray));
    return Text.rich(TextSpan(children: spans));
  }

  // Both Premium and Standard exist for this brand — ask which one to edit.
  void _showQualityChooser(TileDesign prem, TileDesign std) {
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
                child: Text('Edit which quality?',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.star_rounded, color: _premColor),
              title: const Text('Premium'),
              trailing: Text('P ${prem.boxQuantity} · F ${prem.fStock}'),
              onTap: () {
                Navigator.pop(ctx);
                context
                    .push('/stockist/stock/edit/${prem.id}')
                    .then((_) => _load());
              },
            ),
            ListTile(
              leading: const Icon(Icons.verified_outlined, color: _stdColor),
              title: const Text('Standard'),
              trailing: Text('P ${std.boxQuantity} · F ${std.fStock}'),
              onTap: () {
                Navigator.pop(ctx);
                context
                    .push('/stockist/stock/edit/${std.id}')
                    .then((_) => _load());
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Stock-list helpers. The active lists in the current brand view drive the
  // dashboard's "filter by list" row.
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
      // Stockist side: filter by THEIR OWN word (surface_label), not admin.
      result =
          result.where((d) => _selectedSurfaces.contains(d.surfaceWord)).toList();
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
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    // Desktop/web: the persistent sidebar comes from StockistShell; this page
    // renders only its own content. Phone: the full mobile Scaffold.
    if (wide) {
      return _loading
          ? const Center(child: CircularProgressIndicator())
          : _desktopContent();
    }
    return _mobileScaffold();
  }

  Widget _mobileScaffold() {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
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
                // On desktop these live in the left sidebar, so drop them here.
                if (!wide) ...[
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
                // Stock Lists used to hide behind an unlabelled share icon here.
                // It's the labelled "Lists" pill now. (project_dashboard_ia)
                ],
                const NotificationBell(),
                PopupMenuButton<String>(
                  tooltip: 'Account',
                  onSelected: (v) async {
                    if (v == 'production') {
                      await context.push('/stockist/production');
                      if (mounted) _load();
                    } else if (v == 'runs') {
                      await context.push('/stockist/production/runs');
                      if (mounted) _load();
                    } else if (v == 'profile') {
                      await Navigator.of(context).push<bool>(MaterialPageRoute(
                          builder: (_) => const StockistProfileScreen()));
                      if (mounted) _load();
                    } else if (v == 'customers') {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const CustomerListScreen()));
                    } else if (v == 'videos') {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const StockistMyVideosScreen()));
                    } else if (v == 'logout') {
                      await SupabaseAuthService().logout();
                      if (!context.mounted) return;
                      context.go('/login');
                    }
                  },
                  itemBuilder: (_) => [
                    // 🏭 The factory side lives here (not in the Orders sheet),
                    // gated on the same admin opt-in as the desktop sidebar.
                    if (currentStockistBookOrders) ...[
                      const PopupMenuItem(
                          value: 'production',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.precision_manufacturing_outlined),
                            title: Text('Production'),
                          )),
                      const PopupMenuItem(
                          value: 'runs',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.history),
                            title: Text('Runs & history'),
                          )),
                    ],
                    // Opt-in: only stockists the admin switched on ("save
                    // customers on dispatch") get the directory + per-customer
                    // dispatch history. (project_customer_history)
                    if (currentStockistCustomersEnabled)
                      const PopupMenuItem(
                          value: 'customers',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.people_alt_outlined),
                            title: Text('Customers'),
                          )),
                    const PopupMenuItem(
                        value: 'videos',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.play_circle_outline),
                          title: Text('My Videos'),
                        )),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'profile',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.person_outline),
                          title: Text('Edit profile'),
                        )),
                    const PopupMenuItem(
                        value: 'logout',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.logout),
                          title: Text('Logout'),
                        )),
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

  // Desktop content that matches the layout proposal: a toolbar (title + primary
  // actions), a KPI strip, then the search/filter bar and the card grid. Reuses
  // the existing filter/search/grid logic + data (nothing forked). (Phase 3)
  Widget _desktopContent() {
    final designs = _filteredAndSorted;
    return Column(
      children: [
        _selectMode ? _desktopSelectBar() : _desktopToolbar(),
        const Divider(height: 1),
        if (_brands.length > 1) _buildBrandFilterRow(),
        Expanded(
          child: CustomScrollView(
            slivers: [
              // Stat row scrolls away → maximum designs once you start scrolling.
              if (!_selectMode)
                SliverToBoxAdapter(child: _desktopKpiStrip()),
              SliverPersistentHeader(
                pinned: true,
                delegate: _PinnedHeaderDelegate(
                  height: 86,
                  child: Material(
                    color: const Color(0xFFF7F9FA),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [_buildSearchFilterRow(), _buildCountLine()],
                    ),
                  ),
                ),
              ),
              if (_pendingBoxes > 0)
                SliverToBoxAdapter(child: _buildPendingBanner()),
              if (designs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                      child: Text('No designs found',
                          style: TextStyle(color: Colors.grey))),
                )
              else
                ..._gridSlivers(designs),
            ],
          ),
        ),
      ],
    );
  }

  // Toolbar for the My Stock page. Uses the same navy as every other page's app
  // bar so the top strip is ONE colour across the whole app (no colour "blink"
  // when switching pages). (desktop)
  Widget _desktopToolbar() {
    final empty = _isLibraryEmpty;
    ButtonStyle filled(Color c) => ElevatedButton.styleFrom(
        backgroundColor: c,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600));
    return Container(
      color: const Color(0xFF1B4F72),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          const Text('My Stock',
              style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.bold, color: Colors.white)),
          const Spacer(),
          // Desktop mirrors the phone's intent grouping. Records and Lists are
          // already in the left sidebar, so the toolbar carries only the two
          // menus + Add Design. (project_dashboard_ia)
          ElevatedButton.icon(
            onPressed: empty ? _showLibraryActivation : _showStockSheet,
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            label: const Text('Stock'),
            style: filled(const Color(0xFF2E7D32)),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: empty ? null : _showOrdersSheet,
            icon: const Icon(Icons.receipt_long_outlined, size: 17),
            label: Text(
                interestCount > 0 ? 'Orders ($interestCount)' : 'Orders'),
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                minimumSize: const Size(0, 38),
                textStyle:
                    const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () async {
              await context.push('/stockist/library');
              _load();
            },
            icon: const Icon(Icons.add, size: 17),
            label: const Text('Add Design'),
            style: filled(const Color(0xFF2F78A8)),
          ),
          const SizedBox(width: 10),
          Theme(
            data: Theme.of(context).copyWith(
                iconTheme: const IconThemeData(color: Colors.white)),
            child: const NotificationBell(),
          ),
        ],
      ),
    );
  }

  Widget _desktopSelectBar() {
    return Container(
      color: const Color(0xFF1B4F72),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => setState(() {
              _selectMode = false;
              _selectedIds.clear();
            }),
          ),
          Text(
              _selectedIds.isEmpty
                  ? 'Select designs'
                  : '${_selectedIds.length} selected',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          if (_selectedIds.length < _filteredAndSorted.length)
            TextButton(
              onPressed: () => setState(() =>
                  _selectedIds.addAll(_filteredAndSorted.map((d) => d.id))),
              child: const Text('All', style: TextStyle(color: Colors.white)),
            ),
          IconButton(
            icon: Icon(Icons.delete_outline, color: Colors.red.shade200),
            onPressed: _selectedIds.isEmpty ? null : _confirmDeleteSelected,
          ),
        ],
      ),
    );
  }

  String _fmtNum(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  // Stat bar: four equal square-cornered boxes filling the width (accent stripe +
  // value + label). Scrolls away with the page so designs get the full screen.
  Widget _desktopKpiStrip() {
    final inStock = _inStockDesigns;
    final totalP = inStock.fold<int>(0, (s, d) => s + d.boxQuantity);
    final totalF = inStock.fold<int>(0, (s, d) => s + d.fStock);
    final held = inStock.fold<int>(0, (s, d) => s + d.heldQuantity);
    final low = inStock.where((d) => d.boxQuantity > 0 && d.boxQuantity < 25).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          _statBox(const Color(0xFF1B4F72), '${inStock.length}', 'In stock'),
          const SizedBox(width: 10),
          _statBox(const Color(0xFFB26206), _fmtNum(totalP), 'P Stock',
              sub: '${_fmtNum(totalF)} free'),
          const SizedBox(width: 10),
          _statBox(const Color(0xFFC62828), '$low', 'Low stock'),
          const SizedBox(width: 10),
          _statBox(const Color(0xFF6A1B9A), _fmtNum(held), 'Held',
              sub: '$_newOrders order${_newOrders == 1 ? '' : 's'}'),
        ],
      ),
    );
  }

  Widget _statBox(Color c, String value, String label, {String? sub}) =>
      Expanded(
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: Colors.grey.shade300),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              Container(width: 4, color: c),
              const SizedBox(width: 11),
              Text(value,
                  style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.bold, color: c)),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800)),
                    if (sub != null)
                      Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      );

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
  /// Badge = new orders awaiting action (includes web orders my_design_inquiries
  /// can't see); falls back to buyer-interest designs if there are no new orders.
  /// A getter, not a local: it now feeds the Orders pill and the desktop toolbar
  /// as well as this row. (project_dashboard_ia)
  int get interestCount =>
      _newOrders > 0 ? _newOrders : _buyerInterestDesigns.length;

  Widget _buildChipRow() {
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
            // These two say WHAT YOU'RE LOOKING AT. Doing-something lives in the
            // action pills below; Inquiries moved under Orders, taking its
            // unread badge with it. (project_dashboard_ia)
            _tabPill('My Stock', Icons.inventory_2_outlined, true, () {}),
            const SizedBox(width: 6),
            _tabPill('Catalogue', Icons.collections_bookmark_outlined, false,
                () => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(
                      content: Text('Catalogue is coming soon.'))),
                soon: true),
            Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(left: 9, right: 8),
                color: Colors.grey.shade300),
            // Records is history, not an action — it sits at the end of this row
            // rather than among the do-something pills. Quality moved into the
            // Filter sheet, below Size. (project_dashboard_ia)
            _tabPill('Records', Icons.history, false, () async {
              if (_isLibraryEmpty) return;
              await context.push('/stockist/dispatches');
              if (mounted) _load();
            }),
          ],
        ),
      ),
    );
  }

  /// [soon] renders the pill visibly unbuilt — muted, with a "Soon" tag — so it
  /// reads as a promise rather than a broken button.
  Widget _tabPill(String label, IconData icon, bool active, VoidCallback onTap,
      {int badge = 0, bool soon = false}) {
    final fg = active ? Colors.white : Colors.grey.shade600;
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
              Icon(icon, size: 15, color: soon ? Colors.grey.shade400 : fg),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: soon ? Colors.grey.shade400 : fg)),
              if (soon) ...[
                const SizedBox(width: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(3)),
                  child: Text('Soon',
                      style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade700)),
                ),
              ],
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
          ..._gridSlivers(designs),
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
    // Diffusing colour by how tagged the DNA is: red → amber → green (complete).
    final Color c = fill >= 1.0
        ? const Color(0xFF2E7D32)
        : Color.lerp(const Color(0xFFD32F2F), const Color(0xFFF9A825), fill)!;
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
    final String? libId;
    try {
      libId = await _service.libraryEnsureForDesign(d.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open Design DNA: $e'),
          backgroundColor: Colors.red.shade700));
      return;
    }
    if (!mounted) return;
    if (libId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open Design DNA for this design.')));
      return;
    }
    await showDnaEditor(context, libraryId: libId, designName: d.name);
    if (mounted) _load();
  }

  // Round DNA "diffusing" button — the single DNA affordance on stockist cards.
  // Colour reflects how tagged the design is; tap → the DNA editor. (design DNA)
  Widget _dnaButton(TileDesign d) => GestureDetector(
        onTap: () => _openDnaForDesign(d),
        child: _dnaDot(_dnaFill[d.id] ?? 0.0),
      );

  // Small "Family" chip — opens the shared add/remove-from-family sheet.
  Widget _familyChip(String libraryId) => InkWell(
        onTap: () => _openFamilySheet(libraryId),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: const Color(0xFF1B4F72).withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 12, color: Colors.grey.shade700),
              const SizedBox(width: 3),
              Text('Family',
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700)),
            ],
          ),
        ),
      );

  Future<void> _openFamilySheet(String libraryId) async {
    final keep = _libById[libraryId];
    if (keep == null) return;
    await showFamilyCorrectionSheet(context,
        data: _service, keep: keep, allEntries: _library);
    if (mounted) _load();
  }

  // Single-brand card: a design's Premium + Standard holdings MERGED into one
  // card. Size row shows F(prem+std=total); the figures row shows P·C·H split
  // premium(amber)+standard(blue), no F. Top-left DNA button, bottom Family chip.
  // Tap → edit (or asks which quality when both exist). (per-brand + quality)
  Widget _brandDesignTile(List<TileDesign> group) {
    final first = group.first;
    final ratio = aspectRatioFromSize(first.size);
    final img = first.faceImageUrls.isNotEmpty ? first.faceImageUrls.first : '';
    final surface = first.surfaceCardLabel;
    final showSurface = surface.isNotEmpty && surface.toLowerCase() != 'none';

    TileDesign? prem, std;
    for (final d in group) {
      if (d.quality == 'Premium') {
        prem = d;
      } else if (d.quality == 'Standard') {
        std = d;
      } else {
        prem ??= d;
      }
    }
    final totalP = group.fold<int>(0, (s, d) => s + d.boxQuantity);
    final outOfStock = totalP == 0;
    final both = prem != null && std != null;
    final ids = group.map((d) => d.id).toList();
    final anySelected = ids.any(_selectedIds.contains);

    void openEdit() {
      if (both) {
        _showQualityChooser(prem!, std!);
      } else {
        final d = prem ?? std!;
        context.push('/stockist/stock/edit/${d.id}').then((_) => _load());
      }
    }

    return GestureDetector(
      onLongPress: () => setState(() {
        _selectMode = true;
        _selectedIds.addAll(ids);
      }),
      onTap: _selectMode
          ? () => setState(() {
                if (anySelected) {
                  _selectedIds.removeAll(ids);
                } else {
                  _selectedIds.addAll(ids);
                }
              })
          : null,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: ratio,
                      child: TileImage(
                          url: img, tileAspectRatio: ratio, thumbWidth: 600),
                    ),
                    if (showSurface)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            first.finishLabel != null &&
                                    first.finishLabel!.isNotEmpty
                                ? '$surface · ${first.finishLabel}'
                                : surface,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: _selectMode ? null : openEdit,
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_designDisplayName(first),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 13)),
                            // Size on the left, grand total on the right (dark
                            // gray) — same as the All-brands card.
                            Row(
                              children: [
                                Expanded(
                                  child: Text(first.size.replaceAll(' mm', ''),
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: Colors.grey.shade600)),
                                ),
                                Text('$totalP boxes',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey.shade700)),
                              ],
                            ),
                            const SizedBox(height: 5),
                            // P · C · H, each split premium(amber)+standard(blue).
                            Wrap(
                              spacing: 12,
                              runSpacing: 2,
                              children: [
                                _pfCluster('P', prem?.boxQuantity,
                                    std?.boxQuantity),
                                _pfCluster('C', prem?.controlQuantity,
                                    std?.controlQuantity),
                                _pfCluster('H', prem?.heldQuantity,
                                    std?.heldQuantity),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Family chip on the left, F(prem+std=total) on the right.
                      Row(
                        children: [
                          _familyChip(first.libraryId),
                          const Spacer(),
                          _pfCluster('F', prem?.fStock, std?.fStock,
                              showTotal: true),
                        ],
                      ),
                      _lotSection(prem, std),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Top-left: round DNA button + out-of-stock badge.
          Positioned(
            top: 6,
            left: 6,
            child: Row(
              children: [
                _dnaButton(first),
                if (outOfStock) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(6)),
                    child: const Text('Out of Stock',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold)),
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
                  color: anySelected
                      ? const Color(0xFF1B4F72)
                      : Colors.white.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1B4F72), width: 2),
                ),
                child: anySelected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
        ],
      ),
    );
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

  // "+ Add" splits the two real intents BEFORE anything else, so the stockist
  // never lands on a screen that conflates them: STOCK = how many boxes (qty);
  // DESIGN = the tile's identity (name, brands, photo) in the Library.
  static const _sheetShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)));

  Widget _sheetTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(t,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  ListTile _sheetItem(BuildContext ctx, IconData icon, Color color, String title,
          String subtitle, Future<void> Function() go) =>
      ListTile(
        leading: Icon(icon, color: color, size: 28),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(subtitle),
        onTap: () async {
          Navigator.pop(ctx);
          await go();
          if (mounted) _load();
        },
      );

  // "Stock" — everything that moves boxes in or out, plus how they're counted.
  // Add Design is NOT here: it lives inside Add Stock ("+ New design") and the
  // Design Library. Import Supplier PDF is NOT here either — its home is the
  // Design Library, and it is deliberately unpromoted. (project_dashboard_ia)
  void _showStockSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: _sheetShape,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sheetTitle('Stock'),
            _sheetItem(ctx, Icons.add_circle_outline, const Color(0xFF2E7D32),
                'Add Stock', 'Add boxes in — many designs at once', () async {
              await context.push('/stockist/stock/add', extra: {
                'brandId': _brandFilter == 'all' ? null : _brandFilter,
              });
            }),
            const Divider(height: 1),
            _sheetItem(ctx, Icons.remove_circle_outline, const Color(0xFFC62828),
                'Dispatch', 'Send boxes out — order optional', () async {
              await context.push('/stockist/dispatch/manual');
            }),
            const Divider(height: 1),
            _sheetItem(ctx, Icons.table_view_rounded, const Color(0xFF2F78A8),
                'Import from Excel', 'Add or update quantities from a sheet',
                () async {
              final brandId =
                  _brands.any((b) => b.id == _brandFilter) ? _brandFilter : null;
              await context.push('/stockist/stock/import-excel', extra: brandId);
            }),
            const Divider(height: 1),
            _sheetItem(ctx, Icons.tune, const Color(0xFF00838F), 'Control Stock',
                'Block quantity you don\'t want to show to dealers', () async {
              await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const StockControlScreen()));
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // "Orders" — the order lifecycle. Dispatching AGAINST an order is reached by
  // opening the order in Inquiries, which launches the same dispatch screen with
  // the order pre-attached. (project_unified_dispatch_customers)
  void _showOrdersSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: _sheetShape,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sheetTitle('Orders'),
            _sheetItem(
                ctx,
                Icons.receipt_long_outlined,
                const Color(0xFF1B4F72),
                'Inq/Ready Order',
                interestCount > 0
                    ? '$interestCount new — orders placed with you'
                    : 'Orders placed with you', () async {
              await context.push('/stockist/inquiries');
            }),
            const Divider(height: 1),
            // 📋 Prepare a truck's pull sheet (batch + location) before dispatch.
            _sheetItem(ctx, Icons.playlist_add_check_outlined,
                const Color(0xFF1B4F72), 'Loading Lists',
                'Prepare a truck before dispatch', () async {
              await context.push('/stockist/loading-lists');
            }),
            const Divider(height: 1),
            _sheetItem(ctx, Icons.post_add_outlined, const Color(0xFF2E7D32),
                'Add Order from Stock', 'Create an order yourself', () async {
              // The order screen pops its `{id, token, connection_code}` map on
              // save — NOT a bool. Pushing as <bool> threw a cast error the
              // moment it popped. (inquiries_screen pushes it as <Map> already.)
              await Navigator.of(context).push<Map<String, dynamic>>(
                  MaterialPageRoute(
                      builder: (_) => const StockistAddOrderScreen()));
            }),
            // 📕 The other kind of order: for tiles he has NOT made. Gated on the
            // admin opt-in, because only a real made-to-order manufacturer takes
            // them. (docs/BOOK_ORDER_PLAN.md)
            if (currentStockistBookOrders) ...[
              const Divider(height: 1),
              _sheetItem(ctx, Icons.menu_book_outlined, const Color(0xFF6A1B9A),
                  'Book Order', 'Order a design you have not made yet',
                  () async {
                await Navigator.of(context).push<Map<String, dynamic>>(
                    MaterialPageRoute(builder: (_) => const BookOrderScreen()));
              }),
            ],
            // Customers is NOT here — it's a directory, not an order action, so
            // it lives in the account menu under "Edit profile" (gated on
            // customers_enabled). (project_customer_history)
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Row 3 — the DO-SOMETHING row, grouped by intent not mechanism: Stock (what
  // moves in and out), Orders (the order lifecycle), Lists (what I share).
  // Records is history, so it lives on the "My Stock" row above.
  // (project_dashboard_ia)
  Widget _buildActionButtonRow() {
    final empty = _isLibraryEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: Row(
        children: [
          // A brand-new stockist has nothing to add stock to — send them to
          // library activation first, as the old "+/− Manually" button did.
          _actionBtn('Stock', Icons.inventory_2_outlined,
              const Color(0xFF2E7D32),
              empty ? _showLibraryActivation : _showStockSheet,
              menu: true),
          const SizedBox(width: 6),
          _actionBtn('Orders', Icons.receipt_long_outlined,
              const Color(0xFF1B4F72), empty ? null : _showOrdersSheet,
              menu: true, badge: interestCount),
          const SizedBox(width: 6),
          _actionBtn('Lists', Icons.link, const Color(0xFF00838F), empty
              ? null
              : () async {
                  await Navigator.of(context).push<bool>(MaterialPageRoute(
                      builder: (_) => const StockListsScreen()));
                  _load();
                }),
        ],
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

  /// A compact outlined action pill — icon + label on ONE line, colour carried
  /// by the icon and the border rather than a filled pastel block. Matches the
  /// brand/list filter pills above it, so the header reads as one system, and
  /// costs about half the height of the old stacked cards.
  ///
  /// [menu] shows a ▾ caret: this pill opens a sheet rather than navigating.
  /// [badge] surfaces the unread-inquiry count, which used to live on the
  /// Inquiry tab before Inquiries moved under Orders.
  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback? onTap,
      {bool menu = false, int badge = 0}) {
    final enabled = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.45)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 15, color: color),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ),
                    if (menu)
                      Icon(Icons.arrow_drop_down,
                          size: 16, color: color.withValues(alpha: 0.8)),
                  ],
                ),
              ),
              if (badge > 0)
                Positioned(
                  top: -5,
                  right: -3,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                        color: const Color(0xFFC62828),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Colors.white, width: 1.5)),
                    child: Text('$badge',
                        style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                  ),
                ),
            ],
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
    // Surface chips = the stockist's OWN words present in stock (surface_label).
    final surfaces = <String>{
      for (final d in inStock)
        if (d.surfaceWord.isNotEmpty && d.surfaceWord.toLowerCase() != 'none')
          d.surfaceWord,
    }.toList()
      ..sort();
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
    var localQualities = Set<String>.from(_selectedQualities);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localColours   = Set<String>.from(_selectedColours);
    var localTypes     = Set<String>.from(_selectedTypes);
    var localThickness = Set<String>.from(_selectedThickness);
    final localStockTypes = {..._selectedStockTypes};
    final localDna = {..._selectedDna};
    var showMore = false; // reveal advanced facets (Tile Type, Thickness, Colour, DNA)
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
            if (localQualities.isNotEmpty) r = r.where((d) => localQualities.contains(d.quality)).toList();
            if (localSurfaces.isNotEmpty) r = r.where((d) => localSurfaces.contains(d.surfaceWord)).toList();
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
                          localQualities.clear();
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
                      // Essentials — always visible.
                      if (sizes.isNotEmpty)
                        FilterSection(
                          title: 'Size',
                          summary: filterSummary(localSizes),
                          child: chipWrap(sizes, localSizes),
                        ),
                      // Quality moved off the header chip row into the filter,
                      // directly below Size. (project_dashboard_ia)
                      FilterSection(
                        title: 'Quality',
                        summary: filterSummary(localQualities),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _qualities
                              .map((q) => chip(q, localQualities.contains(q),
                                  () => setSheet(() => localQualities.contains(q)
                                      ? localQualities.remove(q)
                                      : localQualities.add(q))))
                              .toList(),
                        ),
                      ),
                      if (surfaces.isNotEmpty)
                        FilterSection(
                          title: 'Finish',
                          summary: filterSummary(localSurfaces),
                          child: chipWrap(surfaces, localSurfaces),
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
                      // Advanced — behind the "More filters" toggle.
                      MoreFiltersToggle(
                        expanded: showMore,
                        activeHidden: (localTypes.isNotEmpty ? 1 : 0) +
                            (localThickness.isNotEmpty ? 1 : 0) +
                            (localColours.isNotEmpty ? 1 : 0) +
                            dnaFacets
                                .where((a) => a.values
                                    .any((v) => localDna.contains(v.id)))
                                .length,
                        onToggle: () => setSheet(() => showMore = !showMore),
                      ),
                      if (showMore) ...[
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
                        // ── Design DNA "special search" facets ────────────────
                        // One section per admin attribute (Punch/Look/Colour/…),
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
        _selectedQualities
          ..clear()
          ..addAll(localQualities);
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
