import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../models/stockist.dart';
import '../models/tile_design.dart';
import '../services/supabase_data_service.dart';
import '../services/supabase_auth_service.dart';
import '../widgets/merged_family_grid.dart';
import '../widgets/quality_choice_sheet.dart';
import '../utils/quality_merge.dart';
import '../utils/responsive.dart';
import '../services/cloudinary_service.dart';
import 'end_user/stockist_group_screen.dart'
    show stockistGroups, loadStockistGroupsFromDb, confirmToggleStockistInGroup;
import '../models/choice_state.dart';
import '../widgets/smart_search_toggle.dart';
import '../utils/design_ranking.dart';
import '../utils/my_choice.dart';
import '../utils/tile_types.dart';
import '../widgets/filter_section.dart';
import '../widgets/learning_video_strip.dart';
import '../widgets/video_lightbox.dart';
import '../widgets/notification_bell.dart';
import '../utils/stockist_tiers.dart';
import '../utils/guest_gate.dart';
import '../utils/claimed_link_store.dart';
import '../models/claimed_catalog.dart';
import '../models/dna.dart';
import '../utils/dna_chains.dart';

const _qualities = ['Premium', 'Standard'];
// Distinct from the primary blue (0xFF1B4F72) used for stockist ID / view-profile,
// so a group's coloured circle never blends with the profile identity.
const _groupColors = [Color(0xFFEF6C00), Color(0xFF2E7D32), Color(0xFF6A1B9A)];

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
  // Buyer home opens on "All Design" (product-first) by default; the buyer can
  // switch to the per-stockist "Stock" view via the top tab.
  bool _viewDesigns = true;
  // Admin learning videos (Banner Video) shown as a strip at the top of the
  // buyer home. Empty = no strip.
  List<Map<String, dynamic>> _learnVideos = [];

  // Father & Child market context â€” a single global toggle that governs every
  // buyer tab (Group / Stock / All Design). 'Public' = the Open Market,
  // 'Private' = the buyer's claimed Closed Market, 'Both' = the two merged.
  String _market = 'Public'; // 'Public' | 'Private' | 'Both'
  // Claimed (Closed Market) designs and the per-stockist cards derived from them.
  List<TileDesign> _privateDesigns = [];
  List<_StockistData> _privateData = [];
  // The buyer's claimed-catalog summaries (for the "Manage saved" remove list).
  List<ClaimedCatalog> _claimedCatalogs = [];

  // Clipboard auto-detect: a /s/ link found on the clipboard that the buyer can
  // add to My Suppliers with one tap. Tokens already claimed or dismissed are
  // remembered in ClaimedLinkStore (persisted) so the banner never nags for a
  // link the buyer has already handled â€” even across app restarts.
  String? _clipboardToken;

  // Progressive group tip: once the buyer has a handful of suppliers and still
  // has no group, suggest grouping ONCE (then never again). Persisted so it
  // doesn't reappear. See project_buyer_onboarding_funnel Scenario 1.
  // Default 7; overridable at build time (--dart-define=GROUP_TIP_THRESHOLD=1)
  // for quick testing of the group tip without claiming many suppliers.
  static const _groupTipThreshold =
      int.fromEnvironment('GROUP_TIP_THRESHOLD', defaultValue: 7);
  bool _groupTipDismissed = false;

  // Guest-trial ~1-month convert prompt â€” shown once when an old-enough guest
  // still has suppliers and hasn't created a login. Default 30 days; lower it
  // (--dart-define=GUEST_TRIAL_DAYS=0) for testing.
  static const _trialDays =
      int.fromEnvironment('GUEST_TRIAL_DAYS', defaultValue: 30);
  bool _trialPromptShown = false;

  final _searchCtrl = TextEditingController();
  String _searchQuery  = '';
  // Search now targets the active tab: All Design â†’ design name (with smart
  // search), Stock â†’ stockist name/ID. Kept in sync by the tab handlers.
  bool _searchByDesign = true; // true = design name, false = stockist

  // Quality filter
  final Set<String> _selectedQualities = {};

  // Stockist filter (Size + Finish)
  final Set<String> _selectedSizes = {};
  final Set<String> _selectedSurfaces = {};


  // Design filter (Qty, Stock Type â€” in addition to shared Size/Finish/Quality)
  final Set<String> _selectedTypes = {};
  final Set<String> _selectedThickness = {};
  Set<String> _selectedStockTypes = {};
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();

  // Design DNA search/filter: the buyer picks canonical value ids; the design's
  // matched library determines which values it carries. Cross-stockist, so the
  // chips show the admin's canonical names (the unifying key). See
  // project_design_dna_engine.
  List<DnaAttribute> _dnaAttrs = []; // catalog (non-free-text), for facet chips
  Map<String, Set<String>> _dnaValues = {}; // designId â†’ canonical value ids
  final Set<String> _selectedDna = {}; // selected canonical value ids
  // Which card's DNA-tag â–¾ is currently expanded (only one at a time).
  String? _expandedDnaDesignId;

  // This design's DNA tags as parent â€º child breadcrumb chains grouped by the
  // root attribute, for the card's â–¾ section. (project_dna_cascade_mapping)
  Map<String, List<String>> _dnaTagsFor(String designId) {
    final vals = _dnaValues[designId];
    if (vals == null || vals.isEmpty) return const {};
    final tags = <DnaTag>[];
    for (final a in _dnaAttrs) {
      var vs = 0;
      for (final v in a.values) {
        final vs0 = vs++;
        if (v.name.toLowerCase() == 'none' || !vals.contains(v.id)) continue;
        tags.add(DnaTag(
          valueId: v.id,
          label: v.name,
          attribute: a.name,
          parentValueId: v.parentValueId,
          attrSort: a.sortOrder,
          valSort: vs0,
        ));
      }
    }
    return buildDnaChainMap(tags);
  }

  // Search match against a design's DNA tags (canonical name only â€” a buyer
  // browses across many stockists, so there's no single "own wording" to
  // resolve per design). [terms] is the (optionally smart-expanded) set of
  // words typed in the search bar.
  bool _dnaSearchMatches(TileDesign d, Set<String> terms) {
    final vals = _dnaValues[d.id];
    if (vals == null || vals.isEmpty) return false;
    for (final attr in _dnaAttrs) {
      for (final v in attr.values) {
        if (v.name.toLowerCase() == 'none' || !vals.contains(v.id)) continue;
        if (terms.any((t) => v.name.toLowerCase().contains(t))) return true;
      }
    }
    return false;
  }

  // value ids actually present in the current pool (so empty facets are hidden).
  Set<String> get _dnaValuesInUse =>
      _dnaValues.values.expand((s) => s).toSet();

  // DNA attributes that have at least one value present in the pool.
  List<DnaAttribute> get _dnaFacetAttrs {
    final inUse = _dnaValuesInUse;
    return _dnaAttrs
        .where((a) => a.values.any((v) => inUse.contains(v.id)))
        .toList();
  }

  String _dnaValueName(String valueId) {
    for (final a in _dnaAttrs) {
      for (final v in a.values) {
        if (v.id == valueId) return v.name;
      }
    }
    return '?';
  }

  // Faceted DNA match: within an attribute the picks are OR'd, across attributes
  // they're AND'd. Empty selection matches everything.
  bool _matchesDna(TileDesign t, Set<String> selected) {
    if (selected.isEmpty) return true;
    final vals = _dnaValues[t.id] ?? const <String>{};
    for (final attr in _dnaAttrs) {
      final picked =
          attr.values.map((v) => v.id).where(selected.contains).toSet();
      if (picked.isNotEmpty && picked.intersection(vals).isEmpty) return false;
    }
    return true;
  }

  int get _designFilterCount {
    int c = _selectedQualities.length +
        _selectedSizes.length +
        _selectedSurfaces.length +
        _selectedTypes.length +
        _selectedThickness.length +
        _selectedDna.length;
    if (_selectedStockTypes.isNotEmpty) c++;
    if (_minQtyCtrl.text.isNotEmpty) c++;
    if (_maxQtyCtrl.text.isNotEmpty) c++;
    return c;
  }

  // Group filter
  int _activeGroupIndex = -1;

  // Shared design-filter predicate â€” applies every active facet (quality, size,
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
    if (_selectedStockTypes.isNotEmpty &&
        !_selectedStockTypes.contains(t.stockType)) {
      return false;
    }
    final mn = int.tryParse(_minQtyCtrl.text);
    final mx = int.tryParse(_maxQtyCtrl.text);
    if (mn != null && t.boxQuantity < mn) return false;
    if (mx != null && t.boxQuantity > mx) return false;
    if (!_matchesDna(t, _selectedDna)) return false;
    return true;
  }

  // True when any design facet (beyond quality, which has its own chips) is set.
  bool get _anyDesignFilterActive =>
      _selectedQualities.isNotEmpty || _designFilterCount > 0;

  // Platform-level benchmarks â€” computed as getters so they always
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
    // Buyers land on My Suppliers (their relationships) by default. A buyer with
    // no private access starts on Discover (public) when it's live; while the
    // public market is off, everyone is on the single My Suppliers surface and
    // switches via the two-mode bottom nav once it's live. Admins/guests reuse
    // this screen as the all-stock overview, so they stay on the public list.
    // currentEndUserId is set only for a logged-in end user.
    // See project_two_mode_marketplace.
    if (currentEndUserId.isNotEmpty) {
      _market = (currentEndUserCanClaimPrivate || !publicMarketLive)
          ? 'Private'
          : 'Public';
    }
    _loadGroupTipFlag();
    _load();
  }

  Future<void> _loadGroupTipFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final group = prefs.getBool('group_tip_shown') ?? false;
    final trial = prefs.getBool('guest_trial_prompt_shown') ?? false;
    if (mounted) {
      setState(() {
        _groupTipDismissed = group;
        _trialPromptShown = trial;
      });
    }
  }

  // ~1-month guest-trial nudge: once an old-enough guest with saved suppliers
  // (who hasn't created a login) opens My Suppliers, show a one-time stronger
  // prompt to convert. The persistent guest banner stays for ongoing nudging.
  void _maybeShowTrialPrompt() {
    if (_trialPromptShown || !isGuest || _privateData.isEmpty) return;
    final age = sessionAgeDays;
    if (age == null || age < _trialDays) return;
    _trialPromptShown = true;
    SharedPreferences.getInstance()
        .then((p) => p.setBool('guest_trial_prompt_shown', true));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final n = _privateData.length;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_user_outlined,
              color: Color(0xFF1B4F72), size: 40),
          title: const Text('Keep your suppliers safe'),
          content: Text(
              "You've been using Tiles Stock for a while. Create your free "
              'login so your $n supplier${n == 1 ? '' : 's'} stay with you on '
              'any phone â€” it only takes a moment.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Later')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/create-login');
              },
              child: const Text('Create login'),
            ),
          ],
        ),
      );
    });
  }

  // One-time "group your suppliers" suggestion â€” only once the buyer has enough
  // suppliers (a flat list gets annoying), still has no group, and hasn't been
  // shown it before. Silent for the first few suppliers (frictionless).
  bool get _showGroupTip =>
      _searchQuery.isEmpty &&
      _market == 'Private' &&
      _privateData.length >= _groupTipThreshold &&
      stockistGroups.isEmpty &&
      !_groupTipDismissed;

  Future<void> _dismissGroupTip() async {
    setState(() => _groupTipDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('group_tip_shown', true);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    super.dispose();
  }

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _service.getMarketStockists(),
      _service.getAllDesigns(),
      _service.getGlobalVideos(),
    ]);

    // Link-only stockists are hidden from the public market (reachable only via
    // their share link).
    final stockists =
        (results[0] as List<Stockist>).where((s) => s.isListed).toList();
    final designs = results[1] as List<TileDesign>;
    _learnVideos = results[2] as List<Map<String, dynamic>>;
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
    // (Size/Finish filter options are derived further below from BOTH the public
    // market designs AND the buyer's private claimed designs â€” see filterPool.)

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

    // â”€â”€ Private (Closed Market) â€” the buyer's claimed catalogs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Loaded for logged-in buyers only (guests have none). Designs come back in
    // the same masked shape as the open market, so anonymity holds. We group
    // them per stockist (using the claimed-catalog summary for the masked name /
    // city) to build the same _StockistData cards the Stock view already renders.
    var privateDesigns = <TileDesign>[];
    var privateData = <_StockistData>[];
    var claimedCatalogs = <ClaimedCatalog>[];
    if (currentEndUserCanClaimPrivate) {
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

    // Filter options reflect BOTH the public market AND the buyer's private
    // (claimed) designs, so Size/Finish chips aren't empty in My-Suppliers mode
    // or when the public market is off.
    final filterPool = [...designs, ...privateDesigns];
    final sizes = filterPool.map((d) => d.size).toSet().toList()
      ..sort((a, b) {
        final r = rankIn(sizeOrder, a).compareTo(rankIn(sizeOrder, b));
        return r != 0 ? r : a.compareTo(b);
      });
    final surfaces = filterPool.map((d) => d.surfaceType).toSet().toList()
      ..sort((a, b) {
        final r = rankIn(finishOrder, a).compareTo(rankIn(finishOrder, b));
        return r != 0 ? r : a.compareTo(b);
      });

    // Design DNA: the canonical attribute/value catalog (for the facet chips) +
    // each design's canonical value ids (the search bridge), across the whole
    // visible pool (public + private). Use the BUYER catalog (not the stockist
    // dnaCatalog): it exposes free-text facet values (Series, Punch Look) from
    // every stockist, whereas dnaCatalog scopes them to the logged-in stockist
    // and so hides them from buyers on this screen.
    final dnaAttrs = await _service.publicDnaCatalogAttrs();
    final dnaIds = <String>{
      ...designs.map((d) => d.id),
      ...privateDesigns.map((d) => d.id),
    }.toList();
    final dnaValues = await _service.designsDnaValues(dnaIds);
    if (!mounted) return;

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
      _dnaAttrs =
          dnaAttrs.where((a) => !a.isFreeText || a.showInFacets).toList();
      _dnaValues = dnaValues;
      _loading = false;
    });
    // Confirm a deep-link auto-add (Scenario 1) if one just happened.
    _maybeShowSupplierAdded();
    // ~1-month guest-trial convert nudge.
    _maybeShowTrialPrompt();
    // Offer a one-tap "add" if the buyer has a supplier link on their clipboard.
    await _checkClipboardForLink();
  }

  // After a supplier's /s/ link auto-added them to My Suppliers (deep link), show
  // a one-time confirmation. The group suggestion is separate + progressive (it
  // only appears once the buyer has ~7 suppliers â€” see _maybeShowGroupTip).
  void _maybeShowSupplierAdded() {
    final name = pendingSupplierAdded;
    if (name == null) return;
    pendingSupplierAdded = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle,
              color: Color(0xFF2E7D32), size: 40),
          title: Text('"$name" added'),
          content: const Text(
              'This supplier is now in My Suppliers â€” their latest stock stays '
              'up to date here, no more PDFs.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    });
  }

  // If the buyer copied a supplier's /s/ link, surface a one-tap banner to add
  // it to My Suppliers. Only the explicit /s/ form is offered (not bare tokens)
  // to avoid false positives from ordinary copied text.
  Future<void> _checkClipboardForLink() async {
    if (!currentEndUserCanClaimPrivate) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (!text.contains('/s/')) return;
      final token = _resolveCatalogToken(text);
      if (token == null) return;
      // Already added (any path) or dismissed before â†’ don't nag (persisted).
      if (await ClaimedLinkStore.isKnown(token)) return;
      if (mounted) setState(() => _clipboardToken = token);
    } catch (_) {
      // Clipboard can throw on some platforms â€” never block the screen on it.
    }
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

  // â”€â”€ Market-aware base lists â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // Masked stockist keys the buyer has already saved into My Suppliers â€” used
  // to flag a "saved" seller while browsing Discover (the upgrade loop).
  Set<String> get _savedStockistKeys =>
      _claimedCatalogs.map((c) => c.stockistKey).toSet();

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
      // 1) membership tier (Platinum > Gold > Silver > none) â€” admin-set.
      final typeDiff = stockistTierRank(b.stockist.stockistType)
          .compareTo(stockistTierRank(a.stockist.stockistType));
      if (typeDiff != 0) return typeDiff;
      // 2) priority within the tier (higher shown first) â€” admin-set.
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
        final terms = smartSearch ? expandSearchTerms(q) : {q};
        result = result
            .where((d) =>
                d.matchesSearch(q, smart: smartSearch) ||
                _dnaSearchMatches(d, terms))
            .toList();
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
      result =
          result.where((d) => _selectedSurfaces.contains(d.surfaceType)).toList();
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
    if (_selectedDna.isNotEmpty) {
      result = result.where((d) => _matchesDna(d, _selectedDna)).toList();
    }
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
    addSet(_selectedStockTypes);
    for (final id in _selectedDna.toList()) {
      out.add(ActiveFilter(
          _dnaValueName(id), () => setState(() => _selectedDna.remove(id))));
    }
    final mn = _minQtyCtrl.text.trim();
    final mx = _maxQtyCtrl.text.trim();
    if (mn.isNotEmpty || mx.isNotEmpty) {
      out.add(ActiveFilter(
          'Qty ${mn.isEmpty ? '0' : mn}â€“${mx.isEmpty ? 'âˆž' : mx}',
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
        _selectedStockTypes.clear();
        _selectedDna.clear();
        _minQtyCtrl.clear();
        _maxQtyCtrl.clear();
      });

  static const _filterStockTypes = ['One Time', 'Continuous', 'Uncertain'];

  void _showDesignFilterSheet() {
    _dismissKeyboard();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.82;
    var localSizes      = Set<String>.from(_selectedSizes);
    final localQualities = Set<String>.from(_selectedQualities);
    var localSurfaces   = Set<String>.from(_selectedSurfaces);
    var localTypes      = Set<String>.from(_selectedTypes);
    var localThickness  = Set<String>.from(_selectedThickness);
    final thicknessBands = availableThicknessBands(_allDesigns);
    final localStockTypes = {..._selectedStockTypes};
    final localDna = {..._selectedDna};
    final dnaFacets = _dnaFacetAttrs;
    final dnaInUse = _dnaValuesInUse;
    var showMore = false; // reveal advanced facets (Tile Type, Thickness, DNA)

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
                final terms = smartSearch ? expandSearchTerms(q) : {q};
                r = r
                    .where((d) =>
                        d.matchesSearch(q, smart: smartSearch) ||
                        _dnaSearchMatches(d, terms))
                    .toList();
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
            if (localQualities.isNotEmpty) {
              r = r.where((d) => localQualities.contains(d.quality)).toList();
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
            final mn = int.tryParse(_minQtyCtrl.text);
            final mx = int.tryParse(_maxQtyCtrl.text);
            if (mn != null) r = r.where((d) => d.boxQuantity >= mn).toList();
            if (mx != null) r = r.where((d) => d.boxQuantity <= mx).toList();
            if (localDna.isNotEmpty) {
              r = r.where((d) => _matchesDna(d, localDna)).toList();
            }
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
                // Pinned Quantity â€” always visible at the top.
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
                      // Essentials â€” always visible.
                      FilterSection(
                        title: 'Size',
                        summary: filterSummary(localSizes),
                        child: chipWrap(_allSizes, localSizes),
                      ),
                      FilterSection(
                        title: 'Quality',
                        summary: localQualities.isEmpty
                            ? 'All'
                            : localQualities.join(', '),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _qualities
                              .map((q) => filterChip(
                                    q,
                                    localQualities.contains(q),
                                    () => setSheet(() =>
                                        localQualities.contains(q)
                                            ? localQualities.remove(q)
                                            : localQualities.add(q)),
                                  ))
                              .toList(),
                        ),
                      ),
                      FilterSection(
                        title: 'Finish',
                        summary: filterSummary(localSurfaces),
                        child: chipWrap(_allSurfaces, localSurfaces),
                      ),
                      FilterSection(
                        title: 'Stock Type',
                        summary: localStockTypes.isEmpty ? 'All' : localStockTypes.join(', '),
                        child: Wrap(spacing: 8, runSpacing: 8,
                          children: _filterStockTypes.map((t) => filterChip(
                            t, localStockTypes.contains(t),
                            () => setSheet(() => localStockTypes.contains(t)
                                ? localStockTypes.remove(t)
                                : localStockTypes.add(t)),
                          )).toList()),
                      ),
                      // Advanced â€” behind the "More filters" toggle.
                      MoreFiltersToggle(
                        expanded: showMore,
                        activeHidden: (localTypes.isNotEmpty ? 1 : 0) +
                            (localThickness.isNotEmpty ? 1 : 0) +
                            dnaFacets
                                .where((a) => a.values
                                    .any((v) => localDna.contains(v.id)))
                                .length,
                        onToggle: () => setSheet(() => showMore = !showMore),
                      ),
                      if (showMore) ...[
                        FilterSection(
                          title: 'Tile Type',
                          summary: filterSummary(localTypes),
                          child: chipWrap(tileTypeNames, localTypes),
                        ),
                        if (thicknessBands.isNotEmpty)
                          FilterSection(
                            title: 'Thickness (approx)',
                            summary: filterSummary(localThickness),
                            child: chipWrap(thicknessBands, localThickness),
                          ),
                        // â”€â”€ Design DNA facets (only attributes with tagged values
                        // present in the current pool are shown) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
                                  .map((v) => filterChip(
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
        _selectedQualities  ..clear()..addAll(localQualities);
        _selectedSurfaces   ..clear()..addAll(localSurfaces);
        _selectedTypes      ..clear()..addAll(localTypes);
        _selectedThickness  ..clear()..addAll(localThickness);
        _selectedStockTypes = {...localStockTypes};
        _selectedDna        ..clear()..addAll(localDna);
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
                  // Big image (bottom-sheet preview â†’ medium thumbnail)
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
                              if (d.hasSurface) _infoChip(d.surfaceCardLabel),
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
      // a Back button; when it's the buyer's home root, no leading (Logout now
      // lives in the â‹® account menu).
      leading: Navigator.canPop(context) ? const BackButton() : null,
      title: Text(currentEndUserId.isNotEmpty
          ? (_market == 'Private' ? 'My Suppliers' : 'Discover')
          : 'Tiles Stock'),
      actions: [
        // "Add supplier" lives as a labeled button in the body now (retired the
        // hidden link icon â€” see project_two_mode_marketplace Phase 1.2).
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _load,
        ),
        const NotificationBell(),
        // Account menu â€” profile (with Delete account inside), stock lists, and
        // Logout. Only on the buyer's own home root, not an admin-pushed view.
        if (!Navigator.canPop(context))
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: (v) async {
              if (v == 'profile') {
                await context.push<bool>('/my-profile');
                if (mounted) _load();
              } else if (v == 'orders') {
                await context.push('/my-orders');
                if (mounted) _load();
              } else if (v == 'dispatch') {
                await context.push('/my-dispatch');
              } else if (v == 'lists') {
                // Manage claimed stock lists; refresh home on return so any
                // removals reflect immediately (system-back may not carry a
                // result, so refresh unconditionally).
                await context.push<bool>('/my-stock-lists');
                if (mounted) _load();
              } else if (v == 'logout') {
                // Guest with saved suppliers â†’ double-confirm (logout is
                // permanent for them) with a Create-login / Help rescue.
                final ok = await confirmGuestLogout(context,
                    supplierCount: _privateData.length);
                if (!ok) return;
                await SupabaseAuthService().logout();
                if (context.mounted) context.go('/login');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'profile',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.person_outline),
                    title: Text('My Profile'),
                  )),
              PopupMenuItem(
                  value: 'orders',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.receipt_long_outlined),
                    title: Text('My Orders'),
                  )),
              PopupMenuItem(
                  value: 'dispatch',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.local_shipping_outlined),
                    title: Text('My Dispatch'),
                  )),
              PopupMenuItem(
                  value: 'lists',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.playlist_add_check),
                    title: Text('My Stock Lists'),
                  )),
              PopupMenuDivider(),
              PopupMenuItem(
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
                _viewDesigns
                    ? () => setState(() {
                          _viewDesigns = false;
                          _searchByDesign = false;
                        })
                    : null,
                active: !_viewDesigns,
              ),
              const SizedBox(width: 8),
              _navButton(
                'All Design',
                Icons.grid_view_rounded,
                _viewDesigns
                    ? null
                    : () => setState(() {
                          _viewDesigns = true;
                          _searchByDesign = true;
                        }),
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
    // Fold each tile's Premium+Standard holdings into one merged card (same
    // brand+surface). (Scenario-2 buyer merge)
    final mergedDesigns = mergeByQuality(filteredDesigns);
    final mergedReps = [for (final m in mergedDesigns) m.rep];
    // System navigation-bar height â€” added to the grid's bottom padding so the
    // last row isn't clipped by the Android nav bar (edge-to-edge).
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      appBar: appBar,
      // Collapse-on-scroll: the header rows (add-supplier, glow video bar,
      // group chips, active filters, legend) scroll away, while the search +
      // filter row stays PINNED under the tabs as the grid scrolls beneath it.
      body: NestedScrollView(
        headerSliverBuilder: (context, innerScrolled) => [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Guest-trial: nudge guests to create a permanent login.
                if (isGuest && _market == 'Private') _buildGuestBanner(),
                // One-tap "add" if a supplier link is on the clipboard.
                if (currentEndUserCanClaimPrivate && _clipboardToken != null)
                  _buildClipboardBanner(),
                // "Add supplier" â€” the primary manual entry on My Suppliers.
                if (currentEndUserCanClaimPrivate && _market == 'Private')
                  _buildAddSupplierBar(),
                // One-time "group your suppliers" suggestion.
                if (_showGroupTip) _buildGroupTip(),
                // Admin learning videos (Banner Video) glow bar. Empty = no-op.
                LearningVideoStrip(
                  videos: _learnVideos,
                  onPlay: (v) => showVideoLightbox(context, v),
                ),
                _buildGroupRow(_viewDesigns
                    ? mergedDesigns.length
                    : filteredStockists.length),
                if (_viewDesigns)
                  ActiveFilterBar(
                      filters: _activeDesignFilters(),
                      onClearAll: _clearAllDesignFilters),
                if (!_viewDesigns) _buildLegend(),
              ],
            ),
          ),
          // Pinned search + filter row (freezes while the grid scrolls).
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedSearchHeader(child: _buildSearchRow()),
          ),
        ],
        body: _viewDesigns
            ? (mergedDesigns.isEmpty
                ? _marketEmpty(designs: true)
                : SingleChildScrollView(
                    child: MergedFamilyGrid(
                      cards: mergedDesigns,
                      columns: gridColumnsFor(MediaQuery.sizeOf(context).width),
                      padding:
                          EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomInset),
                      onOpenDetail: (i) => _openDesignSheet(i, mergedReps),
                      isChosen: (m) => m.holdings.any(
                          (h) => myChoiceQuantities.containsKey(h.id)),
                      onChoiceTap: (m) async {
                        await showQualityChoiceSheet(context, m);
                        if (mounted) setState(() {});
                      },
                      onStockistTap: (m) => context.push(
                        '/stockist/${m.rep.stockistId}/portfolio',
                        extra: m.rep.id,
                      ),
                      dnaTagsFor: (id) => _dnaTagsFor(id),
                      expandedDnaId: _expandedDnaDesignId,
                      onToggleDnaExpand: (id) => setState(() =>
                          _expandedDnaDesignId =
                              _expandedDnaDesignId == id ? null : id),
                    ),
                  ))
            : (filteredStockists.isEmpty
                ? _marketEmpty(designs: false)
                : ListView.builder(
                    padding:
                        EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomInset),
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
                      // Per-card Remove only on My Suppliers (claimed) cards.
                      onRemove: (currentEndUserCanClaimPrivate &&
                              _market == 'Private')
                          ? () => _removeSupplier(filteredStockists[i])
                          : null,
                      // Closes the discoverâ†’save loop: flag a seller already
                      // saved into My Suppliers.
                      alreadySaved: _market != 'Private' &&
                          _savedStockistKeys
                              .contains(filteredStockists[i].stockist.id),
                    ),
                  )),
      ),
      bottomNavigationBar: _buildModeNav(),
    );
  }

  // Two-mode bottom nav â€” My Suppliers Â· Discover â€” shown to a permitted buyer
  // once the public market is live. While it's off (private-first) there's only
  // one surface, so no nav. Switching to Discover is product-first (the design
  // grid). Killed the old "Both". project_two_mode_marketplace Phase 2 #9.
  Widget? _buildModeNav() {
    if (!publicMarketLive || !currentEndUserCanClaimPrivate) {
      return null;
    }
    return NavigationBar(
      height: 60,
      selectedIndex: _market == 'Private' ? 0 : 1,
      onDestinationSelected: (i) {
        _dismissKeyboard();
        setState(() {
          if (i == 0) {
            _market = 'Private'; // My Suppliers
          } else {
            _market = 'Public'; // Discover
            _viewDesigns = true; // product-first
          }
        });
      },
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.storefront_outlined),
          selectedIcon: const Icon(Icons.storefront),
          label: _privateDesigns.isEmpty
              ? 'My Suppliers'
              : 'My Suppliers (${_privateData.length})',
        ),
        const NavigationDestination(
          icon: Icon(Icons.travel_explore_outlined),
          selectedIcon: Icon(Icons.travel_explore),
          label: 'Discover',
        ),
      ],
    );
  }

  // â”€â”€ Group filter row â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  // Persistent search + filter bar â€” pinned under the tabs (see the
  // NestedScrollView header). Search targets the active tab: All Design = design
  // name (smart search), Stock = stockist name/ID. Quality now lives inside the
  // filter sheet (below Size).
  Widget _buildSearchRow() {
    final hint = _viewDesigns
        ? (smartSearch
            ? 'Smart search: white = bianco, carraraâ€¦'
            : 'Search design nameâ€¦')
        : 'Search stockist name or IDâ€¦';
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle:
                    TextStyle(fontSize: 13, color: Colors.grey.shade500),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Clear',
                        onPressed: () {
                          _searchCtrl.clear();
                          _dismissKeyboard();
                          setState(() => _searchQuery = '');
                        },
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          // Smart-search toggle â€” only when searching designs by name.
          if (_viewDesigns) ...[
            const SizedBox(width: 8),
            SmartSearchToggle(onChanged: () => setState(() {})),
          ],
          const SizedBox(width: 8),
          // Filter button, with an active-facet count badge.
          GestureDetector(
            onTap: _showDesignFilterSheet,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: _designFilterCount > 0
                        ? const Color(0xFF1B4F72)
                        : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _designFilterCount > 0
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade400,
                    ),
                  ),
                  child: Icon(Icons.tune_rounded,
                      size: 18,
                      color: _designFilterCount > 0
                          ? Colors.white
                          : Colors.grey.shade600),
                ),
                if (_designFilterCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Center(
                        child: Text('$_designFilterCount',
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
        ],
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
              // Same coloured numbered circle shown on the tile cards â€” the legend
              // that ties a group's name to its â‘  circle.
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
                  // Group name only â€” the supplier count moves next to the
                  // "Showing N designs" line when this group is selected.
                  stockistGroups[i].name,
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
              // Compact people-icon action (not a chip) â€” opens Manage Groups.
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
          child: Row(
            children: [
              Text(
                _viewDesigns
                    ? 'Showing $count design${count == 1 ? '' : 's'}'
                    : 'Showing $count stockist${count == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              // When a group is selected, its supplier count shows here instead
              // of on the chip, with the group's colour dot for the legend.
              if (_activeGroupIndex >= 0 &&
                  _activeGroupIndex < stockistGroups.length) ...[
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color:
                        _groupColors[_activeGroupIndex % _groupColors.length],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '${stockistGroups[_activeGroupIndex].name} Â· '
                    '${stockistGroups[_activeGroupIndex].stockistIds.length} '
                    'supplier${stockistGroups[_activeGroupIndex].stockistIds.length == 1 ? '' : 's'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _groupColors[
                          _activeGroupIndex % _groupColors.length],
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // One-time, dismissible suggestion to organise suppliers into groups. Reuses
  // the existing buyer-group screen (where they name + fill the group).
  Widget _buildGroupTip() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline,
                  color: Color(0xFFF57F17), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('You have ${_privateData.length} suppliers',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    const Text(
                        'Group them to compare stock from many suppliers in one view.',
                        style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: _dismissGroupTip,
                  child: const Text('Maybe later')),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: () async {
                  await context.push('/stockist-groups');
                  await _dismissGroupTip();
                  if (mounted) _load();
                },
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                child: const Text('Create a group'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Guest-trial banner: a guest can save suppliers freely, but is nudged to
  // create a permanent phone login so they keep them on any phone.
  Widget _buildGuestBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F0FE),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: const Color(0xFF1B4F72).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined,
              color: Color(0xFF1B4F72), size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
                "You're on a free guest account. Create a login to keep your "
                "suppliers on any phone.",
                style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: () => context.push('/create-login'),
            style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: const Color(0xFF1B4F72)),
            child: const Text('Create login'),
          ),
        ],
      ),
    );
  }

  // Labeled "Add supplier" button â€” the primary manual way to add a supplier's
  // shared link to My Suppliers.
  Widget _buildAddSupplierBar() {
    const brand = Color(0xFF1B4F72);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _showAddCatalogDialog,
          icon: const Icon(Icons.add_link, size: 18),
          label: const Text('Add supplier WhatsApp link to see live stock',
              textAlign: TextAlign.center),
          style: OutlinedButton.styleFrom(
            foregroundColor: brand,
            side: BorderSide(color: brand.withValues(alpha: 0.5)),
          ),
        ),
      ),
    );
  }

  // Clipboard nudge: the buyer copied a supplier's /s/ link â†’ offer a one-tap
  // add, with a dismiss that stops re-prompting for that link.
  Widget _buildClipboardBanner() {
    const brand = Color(0xFF1B4F72);
    return Container(
      color: const Color(0xFFE3F2FD),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.content_paste_go, color: brand, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('You copied a supplier link. Add it to My Suppliers?',
                style: TextStyle(fontSize: 12.5)),
          ),
          TextButton(
            onPressed: () => _claimToken(_clipboardToken!),
            child: const Text('Add'),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () {
              ClaimedLinkStore.addDismissed(_clipboardToken!);
              setState(() => _clipboardToken = null);
            },
          ),
        ],
      ),
    );
  }

  // Per-card Remove: drop a supplier from My Suppliers. Un-claims every catalog
  // saved from that stockist (matched by masked stockist key), then refreshes.
  Future<void> _removeSupplier(_StockistData data) async {
    final key = data.stockist.id;
    final cats =
        _claimedCatalogs.where((c) => c.stockistKey == key).toList();
    if (cats.isEmpty) return;
    final name = data.stockist.name;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Remove supplier?'),
        content: Text(
            'Remove "$name" from My Suppliers? You will stop seeing their '
            'stock. You can add them again with their link.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Remove',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (yes != true) return;
    try {
      for (final c in cats) {
        await _service.unclaimCatalog(c.catalogId);
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Removed "$name" from My Suppliers')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red));
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
              Icon(Icons.storefront_outlined,
                  size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              const Text('No suppliers yet',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                  'When a supplier shares their catalog link with you, tap '
                  '"Add supplier" to save them here.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _showAddCatalogDialog,
                icon: const Icon(Icons.add_link, size: 18),
                label: const Text('Add supplier'),
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
  // (e.g. a random URL with no /s/â€¦ path), so we can reject it before it ever
  // reaches the server.
  static String? _resolveCatalogToken(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    final m = RegExp(r'/s/([A-Za-z0-9]+)').firstMatch(t);
    if (m != null) return m.group(1);
    if (RegExp(r'^[A-Za-z0-9]+$').hasMatch(t)) return t; // a bare token
    return null;
  }

  // Paste a share link â†’ claim the stock catalog â†’ it lands in the Private
  // market. The input is validated locally first (must contain a /s/ token or
  // be a bare token) so foreign/garbage URLs are rejected with a friendly
  // message instead of being sent to the server.
  Future<void> _showAddCatalogDialog() async {
    // Guests CAN save suppliers (the trial value) â€” no block here. Inquiring/
    // ordering is what triggers the convert prompt (guest-trial scope).
    final ctrl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setDialog) => AlertDialog(
            title: const Text('Add a supplier'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Paste the link your supplier shared with you. '
                    "They'll be saved to My Suppliers.",
                    style: TextStyle(fontSize: 12.5)),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  onChanged: (_) {
                    if (error != null) setDialog(() => error = null);
                  },
                  decoration: InputDecoration(
                    hintText: 'https://tilesdesign.in/s/â€¦',
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
                          "That doesn't look like a supplier link. "
                          'Paste the full link your supplier shared (it '
                          'contains /s/â€¦).');
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
    await _claimToken(token);
  }

  // Claim a supplier link by token â†’ it lands in My Suppliers. Shared by the
  // paste dialog and the clipboard "Add" banner.
  Future<void> _claimToken(String token) async {
    try {
      final res = await _service.claimCatalog(token);
      final name = (res['catalog_name'] ?? 'Supplier').toString();
      await ClaimedLinkStore.addClaimed(token); // don't re-prompt for what we just added
      if (!mounted) return;
      await _load(); // refresh My Suppliers + cards
      if (!mounted) return;
      setState(() {
        _market = 'Private'; // jump to what they just added
        _clipboardToken = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Added "$name" to My Suppliers'),
          backgroundColor: Colors.green));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }


  // â”€â”€ Legend â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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

// â”€â”€ Pinned search-bar header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Fixed-height pinned header hosting the persistent search + filter row. Stays
/// frozen under the tabs while the header rows above it (and the grid below)
/// scroll.
class _PinnedSearchHeader extends SliverPersistentHeaderDelegate {
  _PinnedSearchHeader({required this.child});

  final Widget child;
  static const double _height = 62;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Material(
      elevation: overlaps ? 2 : 0,
      color: Colors.white,
      child: SizedBox(height: _height, child: child),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedSearchHeader old) => true;
}

// â”€â”€ Stockist card â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
  /// Non-null only for My Suppliers (claimed) cards â†’ shows a Remove action.
  final VoidCallback? onRemove;
  /// True in Discover when this seller is already saved in My Suppliers.
  final bool alreadySaved;

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
    this.onRemove,
    this.alreadySaved = false,
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 15)),
                          ),
                          if (alreadySaved) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check_circle,
                                      size: 11, color: Color(0xFF2E7D32)),
                                  SizedBox(width: 2),
                                  Text('In My Suppliers',
                                      style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF2E7D32))),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text('ID: ${s.id}',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                // Stock summary: boxes on top, designs beneath (stacked, not one
                // line) so it stays narrow and doesn't crowd the company name.
                // The remove (â‹®) action moved to the card's bottom corner.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('$displayBoxes boxes',
                              style: const TextStyle(
                                  color: Color(0xFF1B4F72),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  height: 1.1)),
                          Text(
                              '$displayDesigns design${displayDesigns == 1 ? '' : 's'}',
                              style: const TextStyle(
                                  color: Color(0xFF1B4F72),
                                  fontSize: 11,
                                  height: 1.1)),
                        ],
                      ),
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
                  // Cycle the palette (modulo) â€” a 4th+ group must not RangeError
                  // and blank the whole card. Matches the chip/badge colour logic.
                  final color = _groupColors[i % _groupColors.length];
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
            // Remove supplier (â‹® â†’ horizontal) tucked in the bottom corner â€”
            // out of the way so it isn't tapped by mistake, and off the company
            // name's space up top. My Suppliers cards only.
            if (onRemove != null)
              Align(
                alignment: Alignment.centerRight,
                child: PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz,
                      size: 20, color: Colors.grey.shade500),
                  padding: EdgeInsets.zero,
                  splashRadius: 18,
                  tooltip: 'Supplier options',
                  onSelected: (v) {
                    if (v == 'remove') onRemove!();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline,
                              size: 18, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Remove supplier',
                              style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
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
