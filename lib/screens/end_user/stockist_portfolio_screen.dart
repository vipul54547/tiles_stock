import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tile_design.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/tile_card.dart';
import '../../models/choice_state.dart';
import '../../utils/finishes.dart';

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
const _filterSurfaces   = kFinishes;
const _filterColours    = ['White', 'Beige', 'Grey', 'Black', 'Cream'];
const _filterStockTypes = ['One Time', 'Regular', 'Both'];

class _State extends State<StockistPortfolioScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs  = [];
  Stockist?        _stockist;
  bool             _loading  = true;

  final Set<String> _selectedQualities = {};
  Set<String> _selectedSizes    = {};
  Set<String> _selectedSurfaces = {};
  Set<String> _selectedColours  = {};
  String      _stockType        = 'Both';
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
    if (_selectedColours.isNotEmpty)  n++;
    if (_stockType != 'Both')         n++;
    if (_minQtyCtrl.text.trim().isNotEmpty || _maxQtyCtrl.text.trim().isNotEmpty) n++;
    return n;
  }

  List<TileDesign> get _filtered {
    var result = _selectedQualities.isEmpty
        ? _designs
        : _designs.where((d) => _selectedQualities.contains(d.quality)).toList();
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((d) => d.name.toLowerCase().contains(q)).toList();
    }
    if (_selectedSizes.isNotEmpty) {
      result = result.where((d) => _selectedSizes.contains(d.size)).toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      result = result.where((d) => _selectedSurfaces.contains(d.surfaceType)).toList();
    }
    if (_selectedColours.isNotEmpty) {
      result = result.where((d) => _selectedColours.contains(d.colour)).toList();
    }
    if (_stockType != 'Both') {
      result = result.where((d) => d.stockType == _stockType).toList();
    }
    final minQty = int.tryParse(_minQtyCtrl.text.trim());
    final maxQty = int.tryParse(_maxQtyCtrl.text.trim());
    if (minQty != null) result = result.where((d) => d.boxQuantity >= minQty).toList();
    if (maxQty != null) result = result.where((d) => d.boxQuantity <= maxQty).toList();
    return result;
  }

  List<TileDesign> get _chosenFromThisStockist =>
      _designs.where((d) => myChoiceQuantities.containsKey(d.id)).toList();

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
      _service.getAllStockists(),
    ]);
    if (!mounted) return;
    final designs   = results[0] as List<TileDesign>;
    final stockists = results[1] as List<Stockist>;
    Stockist? stockist;
    try {
      stockist = stockists.firstWhere((s) => s.id == widget.stockistId);
    } catch (_) {}
    setState(() {
      _designs  = designs;
      _stockist = stockist;
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
              hintText: 'Search design name...',
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
        _selectedColours.clear();
        _stockType = 'Both';
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
    final list        = _filtered;
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
                  // 2. Image (240 px, cached)
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
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
                                    myChoiceQuantities.remove(id);
                                  } else {
                                    myChoiceQuantities[id] = d.boxQuantity;
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
                          // Info chips
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _infoChip(d.size.replaceAll(' mm', '')),
                              _infoChip(d.surfaceType),
                              _infoChip(d.quality),
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

  // ── Send order sheet (same layout as My Choice) ───────────────────────────

  String _buildMessage(List<TileDesign> designs) {
    final name   = _stockist?.name ?? 'Stockist ${widget.stockistId}';
    final buffer = StringBuffer();
    buffer.writeln('Hello $name,');
    buffer.writeln();
    buffer.writeln('Order Request:');
    int total = 0;
    for (int i = 0; i < designs.length; i++) {
      final d   = designs[i];
      final qty = myChoiceQuantities[d.id] ?? d.boxQuantity;
      total += qty;
      buffer.writeln(
          '${i + 1}. ${d.name} (${d.size.replaceAll(' mm', '')}, '
          '${d.surfaceType}, ${d.quality}) — $qty boxes');
    }
    buffer.writeln();
    buffer.writeln('Total: $total boxes');
    buffer.writeln();
    buffer.writeln('Please confirm availability.');
    return buffer.toString();
  }

  void _showSendSheet() {
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
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, MediaQuery.of(_).viewInsets.bottom + 32),
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
                  final phone = (_stockist?.phone ?? '')
                      .replaceAll(RegExp(r'[^0-9]'), '');
                  if (phone.isEmpty) {
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
                  if (!await launchUrl(uri,
                      mode: LaunchMode.externalApplication)) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Could not open WhatsApp')),
                      );
                    }
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
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Order notification sent to '
                          '${_stockist?.name ?? widget.stockistId}'),
                      backgroundColor: const Color(0xFF2E7D32),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.notifications_outlined, size: 18),
                label: const Text('Send Notification'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  side: const BorderSide(color: Color(0xFF1B4F72)),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
    var localColours   = Set<String>.from(_selectedColours);
    var localStockType = _stockType;
    final savedMin     = _minQtyCtrl.text;
    final savedMax     = _maxQtyCtrl.text;
    var applied        = false;
    final sheetHeight  = MediaQuery.sizeOf(context).height * 0.72;
    final bottomPad    = MediaQuery.paddingOf(context).bottom;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
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
                final active = localStockType == type;
                return GestureDetector(
                  onTap: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setSheet(() => localStockType = type);
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
                          localColours.clear();
                          localStockType = 'Both';
                          _minQtyCtrl.clear();
                          _maxQtyCtrl.clear();
                        }),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red),
                        child: const Text('Reset'),
                      ),
                      const SizedBox(width: 4),
                      ElevatedButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          setState(() {
                            _selectedSizes    = Set<String>.from(localSizes);
                            _selectedSurfaces = Set<String>.from(localSurfaces);
                            _selectedColours  = Set<String>.from(localColours);
                            _stockType        = localStockType;
                          });
                          applied = true;
                          Navigator.of(ctx).pop();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4F72),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Apply',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding:
                        const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _minQtyCtrl,
                                keyboardType: TextInputType.number,
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
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 18)),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _maxQtyCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Max boxes',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        chipRow(_filterSizes, localSizes, stripMm: true),
                        const Divider(height: 24),
                        chipRow(_filterSurfaces, localSurfaces),
                        const Divider(height: 24),
                        chipRow(_filterColours, localColours),
                        const Divider(height: 24),
                        stockTypeRow(),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: bottomPad),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      if (!applied && mounted) {
        _minQtyCtrl.text = savedMin;
        _maxQtyCtrl.text = savedMax;
      }
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
                      SliverPadding(
                        padding:
                            const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        sliver: SliverMasonryGrid(
                          gridDelegate:
                              const SliverSimpleGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                          ),
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final d = _filtered[i];
                              return TileCard(
                                design: d,
                                onTap: () => _openDesign(i),
                                isChosen: myChoiceQuantities
                                    .containsKey(d.id),
                                onChoiceTap: () => setState(() {
                                  final id = d.id;
                                  if (myChoiceQuantities
                                      .containsKey(id)) {
                                    myChoiceQuantities.remove(id);
                                  } else {
                                    myChoiceQuantities[id] =
                                        d.boxQuantity;
                                  }
                                }),
                              );
                            },
                            childCount: _filtered.length,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ]),
      bottomNavigationBar: _loading ? null : _buildSendBar(),
    );
  }
}
