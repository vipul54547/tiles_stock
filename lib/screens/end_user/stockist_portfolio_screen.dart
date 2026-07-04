import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tile_design.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/merged_family_grid.dart';
import '../../widgets/quality_choice_sheet.dart';
import '../../utils/quality_merge.dart';
import '../../utils/order_message.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/smart_search_toggle.dart';
import '../../models/choice_state.dart';
import '../../utils/finishes.dart';
import '../../utils/guest_gate.dart';
import '../../utils/my_choice.dart';
import '../../utils/tile_types.dart';
import '../../widgets/filter_section.dart';

class StockistPortfolioScreen extends StatefulWidget {
  final String stockistId;
  final String? initialDesignId;
  const StockistPortfolioScreen(
      {super.key, required this.stockistId, this.initialDesignId});
  @override
  State<StockistPortfolioScreen> createState() => _State();
}

const _qualities = ['Premium', 'Standard'];

const _qualityMeta = {
  'Premium':  (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
};

const _filterSizes      = ['600x600 mm', '800x800 mm', '300x600 mm', '1200x600 mm'];
const _filterStockTypes = ['One Time', 'Continuous', 'Uncertain'];

class _State extends State<StockistPortfolioScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs  = [];
  Stockist?        _stockist;
  // Finish + size options for the filter, in the admin's master order.
  List<String>     _surfaceOpts = kFinishes;
  List<String>     _sizeOpts = _filterSizes;
  bool             _loading  = true;

  final Set<String> _selectedQualities = {};
  Set<String> _selectedSizes    = {};
  Set<String> _selectedSurfaces = {};
  Set<String> _selectedTypes    = {};
  Set<String> _selectedThickness = {};
  Set<String> _selectedStockTypes = {};
  final _minQtyCtrl  = TextEditingController();
  final _maxQtyCtrl  = TextEditingController();
  final _searchCtrl  = TextEditingController();
  final _searchFocus = FocusNode();
  bool   _searchActive = false;
  String _searchQuery  = '';

  int get _filterCount {
    int n = 0;
    if (_selectedSizes.isNotEmpty)    n++;
    if (_selectedSurfaces.isNotEmpty) n++;
    if (_selectedTypes.isNotEmpty)    n++;
    if (_selectedThickness.isNotEmpty) n++;
    if (_selectedStockTypes.isNotEmpty) n++;
    if (_minQtyCtrl.text.trim().isNotEmpty || _maxQtyCtrl.text.trim().isNotEmpty) n++;
    return n;
  }

  List<TileDesign> get _filtered {
    var result = _selectedQualities.isEmpty
        ? _designs
        : _designs.where((d) => _selectedQualities.contains(d.quality)).toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
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
    final minQty = int.tryParse(_minQtyCtrl.text.trim());
    final maxQty = int.tryParse(_maxQtyCtrl.text.trim());
    if (minQty != null) result = result.where((d) => d.boxQuantity >= minQty).toList();
    if (maxQty != null) result = result.where((d) => d.boxQuantity <= maxQty).toList();
    return result;
  }

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
        _minQtyCtrl.clear();
        _maxQtyCtrl.clear();
      });

  List<TileDesign> get _chosenFromThisStockist =>
      _designs.where((d) => myChoiceQuantities.containsKey(d.id)).toList();

  // Filtered holdings folded into merged (Premium+Standard) buyer cards.
  List<MergedDesign> get _mergedFiltered => mergeByQuality(_filtered);

  @override
  void initState() {
    super.initState();
    _load();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus && mounted) {
        setState(() {
          _searchActive = false;
          _searchQuery  = '';
          _searchCtrl.clear();
        });
      }
    });
  }

  @override
  void dispose() {
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _service.getDesignsByStockistSeqId(widget.stockistId),
      _service.getMarketStockists(),
      _service.getMyPrivateDesigns(),
    ]);
    if (!mounted) return;
    final publicDesigns = results[0] as List<TileDesign>;
    final stockists = results[1] as List<Stockist>;
    // getDesignsByStockistSeqId reads the public market view (empty when the public
    // market is off), so a private (claimed) supplier would show a blank portfolio.
    // Merge in this stockist's private designs so the portfolio is never empty.
    final privForStockist = (results[2] as List<TileDesign>)
        .where((d) => d.stockistId == widget.stockistId);
    final seen = <String>{};
    final designs = <TileDesign>[];
    for (final d in [...publicDesigns, ...privForStockist]) {
      if (seen.add(d.id)) designs.add(d);
    }
    Stockist? stockist;
    try {
      stockist = stockists.firstWhere((s) => s.id == widget.stockistId);
    } catch (_) {}
    final finishes = await _service.getActiveFinishNames();
    final sizes = await _service.getActiveSizeNames();
    if (!mounted) return;
    setState(() {
      _designs  = designs;
      _stockist = stockist;
      _surfaceOpts = finishes;
      _sizeOpts = sizes;
      _loading  = false;
    });
  }

  // ── Quality filter + search + filter button row ───────────────────────────

  Widget _buildQualityFilter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      color: Colors.white,
      child: _searchActive ? _buildSearchRow() : _buildChipsRow(),
    );
  }

  // Search mode: [TextField (expanded)] [Filter btn] [Clear filter btn?]
  Widget _buildSearchRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            autofocus: true,
            onChanged: (v) => setState(() => _searchQuery = v),
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
              suffixIcon: _searchQuery.isNotEmpty
                  ? GestureDetector(
                      onTap: () => setState(() {
                        _searchCtrl.clear();
                        _searchQuery = '';
                      }),
                      child: const Icon(Icons.close, size: 18),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SmartSearchToggle(onChanged: () => setState(() {})),
        const SizedBox(width: 6),
        _buildFilterBtn(),
        if (_filterCount > 0) ...[
          const SizedBox(width: 6),
          _buildClearFilterBtn(),
        ],
      ],
    );
  }

  // Normal mode: [Premium] [Standard] [Search icon] [Filter btn] [Clear?]
  Widget _buildChipsRow() {
    return Row(
      children: [
        ..._qualities.map((q) {
          final m        = _qualityMeta[q]!;
          final selected = _selectedQualities.contains(q);
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                if (selected) {
                  _selectedQualities.remove(q);
                } else {
                  _selectedQualities.add(q);
                }
              }),
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding:
                    const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
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
                    Icon(m.icon, size: 14,
                        color: selected ? Colors.white : m.fg),
                    const SizedBox(width: 4),
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
        // Search icon button
        GestureDetector(
          onTap: () => setState(() => _searchActive = true),
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: const Color(0xFFE3F2FD),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1565C0), width: 1),
            ),
            child: const Icon(Icons.search,
                size: 16, color: Color(0xFF1565C0)),
          ),
        ),
        const SizedBox(width: 6),
        _buildFilterBtn(),
        if (_filterCount > 0) ...[
          const SizedBox(width: 6),
          _buildClearFilterBtn(),
        ],
      ],
    );
  }

  Widget _buildFilterBtn() {
    return GestureDetector(
      onTap: _showFilterSheet,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: _filterCount > 0
                  ? const Color(0xFF1B4F72)
                  : const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _filterCount > 0
                    ? const Color(0xFF1B4F72)
                    : Colors.grey.shade400,
              ),
            ),
            child: Icon(Icons.tune_rounded,
                size: 16,
                color: _filterCount > 0
                    ? Colors.white
                    : Colors.grey.shade600),
          ),
          if (_filterCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
                child: Center(
                  child: Text('$_filterCount',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildClearFilterBtn() {
    return GestureDetector(
      onTap: () => setState(() {
        _selectedSizes.clear();
        _selectedSurfaces.clear();
        _selectedTypes.clear();
        _selectedThickness.clear();
        _selectedStockTypes.clear();
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
    );
  }

  // ── Design detail sheet ───────────────────────────────────────────────────

  void _openDesign(int startIndex) {
    // Page across the merged cards' representative holdings (matches the grid).
    final list        = _mergedFiltered.map((m) => m.rep).toList();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.75;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        int idx = startIndex;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final d = list[idx];
            final imageUrl = d.faceImageUrls.isNotEmpty
                ? d.faceImageUrls.first
                : '';
            final isFirst  = idx == 0;
            final isLast   = idx == list.length - 1;
            final isChosen = myChoiceQuantities.containsKey(d.id);

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
                  // 1. Drag handle + close button
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
                  // 2. Image (240 px, cached) → medium thumbnail
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(imageUrl, width: 800),
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: Colors.grey[200]),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[200],
                        child: const Icon(Icons.image_not_supported, size: 48),
                      ),
                    ),
                  ),
                  // 3. Prev · counter · Next (right after image)
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
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12),
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
                  // 4. Name + bookmark + boxes + chips + button
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Name row
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  d.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 17),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Bookmark toggle (same as All Design sheet)
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
                                    color: isChosen
                                        ? const Color(0xFF1B4F72)
                                        : const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: const Color(0xFF1B4F72)
                                            .withValues(alpha: 0.3)),
                                  ),
                                  child: Icon(
                                    isChosen
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_outline_rounded,
                                    size: 16,
                                    color: isChosen
                                        ? Colors.white
                                        : const Color(0xFF1B4F72),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Boxes badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1B4F72)
                                      .withValues(alpha: 0.1),
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
                          // Info chips (+ the stockist's own finish wording when
                          // it differs from the standard finish).
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
                          const SizedBox(height: 12),
                          // View Tile Details button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  if (mounted) {
                                    context.push('/design/${d.id}');
                                  }
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
        child: Text(label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF1B4F72),
              fontWeight: FontWeight.w500,
            )),
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

  // ── Send order sheet (same layout as My Choice) ───────────────────────────

  String _buildMessage(List<TileDesign> designs) => buildOrderMessage([
        for (final d in designs)
          (
            name: d.name,
            size: d.size,
            surface: d.surfaceType,
            quality: d.quality,
            qty: myChoiceQuantities[d.id] ?? d.boxQuantity,
          ),
      ]);

  void _showSendSheet() {
    if (blockIfGuest(context, feature: 'Placing orders')) return;
    final chosen = _chosenFromThisStockist;
    if (chosen.isEmpty) return;
    final message = _buildMessage(chosen);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20,
            MediaQuery.of(_).viewInsets.bottom +
                MediaQuery.of(_).viewPadding.bottom +
                24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Send Order to ${_stockist?.name ?? widget.stockistId}',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text(message,
                  style: const TextStyle(fontSize: 12, height: 1.6)),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  // Full international number (country code + phone), digits only.
                  final phone =
                      '${_stockist?.countryCode ?? '+91'}${_stockist?.phone ?? ''}'
                          .replaceAll(RegExp(r'[^0-9]'), '');
                  if ((_stockist?.phone ?? '').isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('No phone number available')),
                      );
                    }
                    return;
                  }
                  final uri = Uri.parse(
                      'https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
                  final ok = await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                  if (ok) {
                    // Auto-alert the stockist that a buyer reached out.
                    await _service.notifyStockist(widget.stockistId);
                  } else if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not open WhatsApp')),
                    );
                  }
                },
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: const Text('Send via WhatsApp'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sticky send bar ───────────────────────────────────────────────────────

  Widget? _buildSendBar() {
    final chosen = _chosenFromThisStockist;
    if (chosen.isEmpty) return null;
    final totalBoxes =
        chosen.fold(0, (sum, d) => sum + (myChoiceQuantities[d.id] ?? 0));
    return Container(
      // +nav-bar inset so the Send button clears the Android nav buttons
      // (edge-to-edge, targetSdk 36).
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2))
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${chosen.length} design${chosen.length == 1 ? '' : 's'} selected',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  '$totalBoxes boxes total',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: _showSendSheet,
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Send Order'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4F72),
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Filter sheet ──────────────────────────────────────────────────────────

  void _showFilterSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localTypes     = Set<String>.from(_selectedTypes);
    var localThickness = Set<String>.from(_selectedThickness);
    final thicknessBands = availableThicknessBands(_designs);
    final localStockTypes = {..._selectedStockTypes};
    final sheetHeight  = MediaQuery.sizeOf(context).height * 0.72;
    final bottomPad    = MediaQuery.paddingOf(context).bottom;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget chipRow(List<String> options, Set<String> selected,
              {bool stripMm = false}) {
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: options.map((opt) {
                final label  = stripMm ? opt.replaceAll(' mm', '') : opt;
                final active = selected.contains(opt);
                return GestureDetector(
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setSheet(() {
                      if (active) {
                        selected.remove(opt);
                      } else {
                        selected.add(opt);
                      }
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active
                            ? const Color(0xFF1B4F72)
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: Text(label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? Colors.white
                              : Colors.grey.shade700,
                        )),
                  ),
                );
              }).toList(),
            );
          }

          Widget stockTypeRow() {
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _filterStockTypes.map((type) {
                final active = localStockTypes.contains(type);
                return GestureDetector(
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setSheet(() => localStockTypes.contains(type)
                        ? localStockTypes.remove(type)
                        : localStockTypes.add(type));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active
                            ? const Color(0xFF1B4F72)
                            : Colors.grey.shade300,
                      ),
                    ),
                    child: Text(type,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? Colors.white
                              : Colors.grey.shade700,
                        )),
                  ),
                );
              }).toList(),
            );
          }

          int previewCount() {
            var r = _selectedQualities.isEmpty
                ? _designs
                : _designs
                    .where((d) => _selectedQualities.contains(d.quality))
                    .toList();
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              r = r.where((d) => d.matchesSearch(q, smart: smartSearch)).toList();
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
            final mn = int.tryParse(_minQtyCtrl.text.trim());
            final mx = int.tryParse(_maxQtyCtrl.text.trim());
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
                  decoration: const InputDecoration(
                    labelText: 'Min boxes',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('–',
                    style: TextStyle(color: Colors.grey, fontSize: 18)),
              ),
              Expanded(
                child: TextField(
                  controller: _maxQtyCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setSheet(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Max boxes',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          );

          void applyAndClose() {
            FocusManager.instance.primaryFocus?.unfocus();
            setState(() {
              _selectedSizes     = Set<String>.from(localSizes);
              _selectedSurfaces  = Set<String>.from(localSurfaces);
              _selectedTypes     = Set<String>.from(localTypes);
              _selectedThickness = Set<String>.from(localThickness);
              _selectedStockTypes = {...localStockTypes};
            });
            Navigator.of(ctx).pop();
          }

          return Container(
            height: sheetHeight,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
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
                          _minQtyCtrl.clear();
                          _maxQtyCtrl.clear();
                        }),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
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
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    children: [
                      FilterSection(
                        title: 'Size',
                        summary: filterSummary(localSizes),
                        child: chipRow(_sizeOpts, localSizes, stripMm: true),
                      ),
                      FilterSection(
                        title: 'Finish',
                        summary: filterSummary(localSurfaces),
                        child: chipRow(_surfaceOpts, localSurfaces),
                      ),
                      FilterSection(
                        title: 'Tile Type',
                        summary: filterSummary(localTypes),
                        child: chipRow(kTileTypes, localTypes),
                      ),
                      if (thicknessBands.isNotEmpty)
                        FilterSection(
                          title: 'Thickness (approx)',
                          summary: filterSummary(localThickness),
                          child: chipRow(thicknessBands, localThickness),
                        ),
                      FilterSection(
                        title: 'Stock Type',
                        summary: localStockTypes.isEmpty ? 'All' : localStockTypes.join(', '),
                        child: stockTypeRow(),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + bottomPad),
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: applyAndClose,
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
      // Apply on any close (Apply button, swipe-down, or tap-outside). The
      // qty fields edit the live controllers, so they're already current.
      setState(() {
        _selectedSizes     = Set<String>.from(localSizes);
        _selectedSurfaces  = Set<String>.from(localSurfaces);
        _selectedTypes     = Set<String>.from(localTypes);
        _selectedThickness = Set<String>.from(localThickness);
        _selectedStockTypes = {...localStockTypes};
      });
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_stockist?.name ?? 'Stockist #${widget.stockistId}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              _buildQualityFilter(),
              ActiveFilterBar(
                  filters: _activeFilters(), onClearAll: _clearAllFilters),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    if (_filtered.isEmpty)
                      const SliverFillRemaining(
                        child: Center(
                          child: Text('No designs for selected filters',
                              style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    else
                      _familyGridSliver(),
                  ],
                ),
              ),
            ]),
      bottomNavigationBar: _loading ? null : _buildSendBar(),
    );
  }

  // Banded, quality-merged buyer grid (shared with the discover feed). Only
  // in-stock designs reach here; Premium+Standard of a tile are folded into one
  // card, and >=2-master families are ringed. (Scenario-2 buyer merge)
  Widget _familyGridSliver() => SliverToBoxAdapter(
        child: MergedFamilyGrid(
          cards: _mergedFiltered,
          onOpenDetail: _openDesign,
          isChosen: (m) =>
              m.holdings.any((h) => myChoiceQuantities.containsKey(h.id)),
          onChoiceTap: (m) async {
            await showQualityChoiceSheet(context, m);
            if (mounted) setState(() {});
          },
        ),
      );
}
