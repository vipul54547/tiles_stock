import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../services/data_service.dart';
import '../../widgets/tile_card.dart';

class StockistPortfolioScreen extends StatefulWidget {
  final String stockistId;
  final String? initialDesignId;
  const StockistPortfolioScreen({super.key, required this.stockistId, this.initialDesignId});
  @override State<StockistPortfolioScreen> createState() => _State();
}

const _qualities = ['Premium', 'Standard'];

const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
};

const _filterSizes     = ['600x600 mm', '800x800 mm', '300x600 mm', '1200x600 mm'];
const _filterSurfaces  = ['Matt', 'Glossy', 'Satin', 'Rustic', 'Polished', 'Lappato'];
const _filterColours   = ['White', 'Beige', 'Grey', 'Black', 'Cream'];
const _filterStockTypes = ['One Time', 'Regular', 'Both'];

class _State extends State<StockistPortfolioScreen> {
  final DataService _service = MockDataService();
  List<TileDesign> _designs = [];
  bool _loading = true;
  bool _inquirySent = false;
  final Set<String> _selectedQualities = {};
  final Set<String> _selectedDesignIds = {};

  // Additional filters
  Set<String> _selectedSizes = {};
  Set<String> _selectedSurfaces = {};
  Set<String> _selectedColours = {};
  String _stockType = 'Both';
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();

  int get _filterCount {
    int n = 0;
    if (_selectedSizes.isNotEmpty) n++;
    if (_selectedSurfaces.isNotEmpty) n++;
    if (_selectedColours.isNotEmpty) n++;
    if (_stockType != 'Both') n++;
    if (_minQtyCtrl.text.trim().isNotEmpty || _maxQtyCtrl.text.trim().isNotEmpty) n++;
    return n;
  }

  List<TileDesign> get _filtered {
    var result = _selectedQualities.isEmpty
        ? _designs
        : _designs.where((d) => _selectedQualities.contains(d.quality)).toList();
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

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await _service.getDesignsByStockist(widget.stockistId);
    setState(() {
      _designs = data;
      _loading = false;
    });
  }

  // ── Quality filter (compact) ──────────────────────────────────────────────

  Widget _buildQualityFilter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      color: Colors.white,
      child: Row(
        children: _qualities.map((q) {
          final m = _qualityMeta[q]!;
          final selected = _selectedQualities.contains(q);
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                if (selected) { _selectedQualities.remove(q); }
                else { _selectedQualities.add(q); }
              }),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                decoration: BoxDecoration(
                  color: selected ? m.fg : m.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: m.fg, width: selected ? 2 : 1),
                  boxShadow: selected
                      ? [BoxShadow(color: m.fg.withValues(alpha: 0.22), blurRadius: 4, offset: const Offset(0, 2))]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon, size: 14, color: selected ? Colors.white : m.fg),
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
        }).toList(),
      ),
    );
  }

  // ── Design preview card ───────────────────────────────────────────────────

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
                : 'https://picsum.photos/seed/${d.id}/400/400';

            return Container(
              height: sheetHeight,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
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
                  // Image
                  SizedBox(
                    height: 200,
                    width: double.infinity,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: Colors.grey[200]),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[200],
                        child: const Icon(Icons.image_not_supported, size: 48),
                      ),
                    ),
                  ),
                  // Details
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Name + counter + boxes
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
                          // Size · Surface · Quality chips
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _modalChip(d.size.replaceAll(' mm', '')),
                              _modalChip(d.surfaceType),
                              _modalChip(d.quality),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Prev / Next buttons
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
                                    foregroundColor: const Color(0xFF1B4F72),
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
                                  icon: const Icon(Icons.arrow_forward_ios,
                                      size: 14),
                                  label: const Text('Next'),
                                  iconAlignment: IconAlignment.end,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF1B4F72),
                                    side: const BorderSide(
                                        color: Color(0xFF1B4F72)),
                                  ),
                                ),
                              ),
                            ],
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
    );
  }

  Widget _modalChip(String label) => Container(
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

  // ── Filter sheet ──────────────────────────────────────────────────────────

  void _showFilterSheet() {
    FocusManager.instance.primaryFocus?.unfocus();
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);
    var localColours   = Set<String>.from(_selectedColours);
    var localStockType = _stockType;
    final localMinCtrl = TextEditingController(text: _minQtyCtrl.text);
    final localMaxCtrl = TextEditingController(text: _maxQtyCtrl.text);
    final sheetHeight  = MediaQuery.sizeOf(context).height * 0.72;
    final bottomPad    = MediaQuery.paddingOf(context).bottom;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
            // ── helpers ──────────────────────────────────────────────────
            Widget chipRow(List<String> options, Set<String> selected,
                {bool stripMm = false}) {
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: options.map((opt) {
                  final label = stripMm ? opt.replaceAll(' mm', '') : opt;
                  final active = selected.contains(opt);
                  return GestureDetector(
                    onTap: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      setSheet(() {
                        if (active) { selected.remove(opt); }
                        else { selected.add(opt); }
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

            // ── Sheet UI ─────────────────────────────────────────────────
            return Container(
              height: sheetHeight,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(16)),
              ),
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
                            localMinCtrl.clear();
                            localMaxCtrl.clear();
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
                              _minQtyCtrl.text  = localMinCtrl.text;
                              _maxQtyCtrl.text  = localMaxCtrl.text;
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              Navigator.of(ctx).pop();
                            });
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
                  // Scrollable filter content — order: Qty → Size → Finish → Colour → Stock Type
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Quantity of box between
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: localMinCtrl,
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
                                  controller: localMaxCtrl,
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
                          // Size
                          chipRow(_filterSizes, localSizes, stripMm: true),
                          const Divider(height: 24),
                          // Finish
                          chipRow(_filterSurfaces, localSurfaces),
                          const Divider(height: 24),
                          // Colour
                          chipRow(_filterColours, localColours),
                          const Divider(height: 24),
                          // Stock Type
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
      localMinCtrl.dispose();
      localMaxCtrl.dispose();
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
        title: Text('Stockist #${widget.stockistId}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (!_inquirySent)
                Container(
                  width: double.infinity,
                  color: const Color(0xFF1B4F72),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      // Send Inquiry button
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            String? preFilledMessage;
                            if (_selectedDesignIds.isNotEmpty) {
                              final selected = _designs
                                  .where((d) => _selectedDesignIds.contains(d.id))
                                  .toList();
                              final names = selected
                                  .asMap()
                                  .entries
                                  .map((e) => '${e.key + 1}. ${e.value.name}')
                                  .join('\n');
                              preFilledMessage =
                                  'I am interested in the following designs:\n$names';
                            }
                            await context.push(
                                '/inquiry/${widget.stockistId}/design_001',
                                extra: preFilledMessage);
                            setState(() {
                              _inquirySent = true;
                              _selectedDesignIds.clear();
                            });
                          },
                          icon: const Icon(Icons.send_outlined),
                          label: Text(
                            _selectedDesignIds.isEmpty
                                ? 'Send Inquiry to Stockist'
                                : 'Send Inquiry (${_selectedDesignIds.length} selected)',
                          ),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber[700]),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Filter button with active-filter badge
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ElevatedButton(
                            onPressed: _showFilterSheet,
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.18),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(13),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                    color:
                                        Colors.white.withValues(alpha: 0.35)),
                              ),
                            ),
                            child: const Icon(Icons.tune_rounded, size: 20),
                          ),
                          if (_filterCount > 0)
                            Positioned(
                              right: -4,
                              top: -4,
                              child: Container(
                                width: 17,
                                height: 17,
                                decoration: const BoxDecoration(
                                  color: Colors.amber,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Text(
                                    '$_filterCount',
                                    style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black87),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_filterCount > 0) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => setState(() {
                            _selectedSizes.clear();
                            _selectedSurfaces.clear();
                            _selectedColours.clear();
                            _stockType = 'Both';
                            _minQtyCtrl.clear();
                            _maxQtyCtrl.clear();
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.5)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.close,
                                    size: 13, color: Colors.white),
                                SizedBox(width: 4),
                                Text('Clear',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_inquirySent)
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.green[50],
                  child: const Row(children: [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 8),
                    Text('Inquiry sent for this portfolio visit'),
                  ]),
                ),
              _buildQualityFilter(),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    if (_filtered.isEmpty)
                      const SliverFillRemaining(
                        child: Center(
                          child: Text('No designs for selected quality',
                              style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
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
                              final isSelected = _selectedDesignIds.contains(d.id);
                              return Stack(
                                children: [
                                  TileCard(
                                    design: d,
                                    onTap: () => _openDesign(i),
                                  ),
                                  Positioned(
                                    top: 6,
                                    left: 6,
                                    child: GestureDetector(
                                      onTap: () => setState(() {
                                        if (isSelected) { _selectedDesignIds.remove(d.id); }
                                        else { _selectedDesignIds.add(d.id); }
                                      }),
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? const Color(0xFF1B4F72)
                                              : Colors.white.withValues(alpha: 0.92),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: isSelected
                                                ? const Color(0xFF1B4F72)
                                                : Colors.grey.shade400,
                                            width: 1.5,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(color: Colors.black26, blurRadius: 3),
                                          ],
                                        ),
                                        child: isSelected
                                            ? const Icon(Icons.check,
                                                size: 14, color: Colors.white)
                                            : null,
                                      ),
                                    ),
                                  ),
                                ],
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
    );
  }
}
