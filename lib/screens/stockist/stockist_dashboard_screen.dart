import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../config/app_config.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/tile_card.dart';
import '../../widgets/filter_section.dart';
import '../../widgets/notification_bell.dart';
import '../../models/choice_state.dart';
import '../../models/share_link.dart';
import '../../utils/tile_types.dart';

class StockistDashboardScreen extends StatefulWidget {
  const StockistDashboardScreen({super.key});
  @override
  State<StockistDashboardScreen> createState() => _State();
}

const _qualities = ['Premium', 'Standard'];
const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
};

const _sortOptions = [
  (label: 'Default',          value: 'default'),
  (label: 'Name A → Z',      value: 'name_asc'),
  (label: 'Boxes: High → Low', value: 'boxes_high'),
  (label: 'Boxes: Low → High', value: 'boxes_low'),
  (label: 'Quality',           value: 'quality'),
];

const int _lowStockThreshold = 10;

// Stock-type options for the filter (matches the buyer "All Designs" filter).
const _filterStockTypes = ['One Time', 'Regular', 'Both'];

class _State extends State<StockistDashboardScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs = [];
  // Buyer My-Choice interest in this stockist's designs: designId → (buyers, boxes).
  Map<String, ({int buyers, int boxes})> _inquiries = {};
  // Boxes the stockist added that are held for admin approval (big-stock rule).
  int _pendingBoxes = 0;
  bool _loading = true;
  String get _myStockistId => currentStockistUUID;

  // Tab
  int _activeTab = 0; // 0 = My Stock, 1 = Buyer Interest

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
  String _stockType = 'Both';
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
      (_stockType != 'Both' ? 1 : 0) +
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
    if (!mounted) return;
    setState(() {
      _designs = data;
      _inquiries = inquiries;
      _pendingBoxes = pending;
      _loading = false;
    });
  }

  void _showShareSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _ShareLinksSheet(service: _service),
    );
  }

  // ── Computed ──────────────────────────────────────────────────────────────

  // Out-of-stock (0-box) designs are hidden from the dashboard's stock list,
  // its counts and filters. They still surface in the Inquiry tab if a buyer
  // wants them, so the stockist knows what to restock.
  List<TileDesign> get _inStockDesigns =>
      _designs.where((d) => d.boxQuantity > 0).toList();

  List<TileDesign> get _filteredAndSorted {
    final base = _inStockDesigns;
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
    if (_stockType != 'Both') {
      result = result
          .where((d) => d.stockType == _stockType || d.stockType == 'Both')
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

  double get _estimatedOrderValue => _buyerInterestDesigns.fold(
      0.0, (sum, d) => sum + d.boxPrice * (_inquiries[d.id]?.boxes ?? 0));

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
              title: const Text('Stock Dashboard'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share my catalog',
                  onPressed: _showShareSheet,
                ),
                IconButton(
                  icon: const Icon(Icons.move_to_inbox_outlined),
                  tooltip: 'Received inquiries',
                  onPressed: () => context.push('/stockist/inquiries'),
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
              ],
            ),
      // Action buttons moved into the collapsing header (Dispatch / Upload /
      // Add Design row) — no floating buttons.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildStatsBar(),  // pinned, slim
                if (_pendingBoxes > 0) _buildPendingBanner(),
                _buildChipRow(),   // pinned: tabs + quality chips
                Expanded(
                  child: _activeTab == 0
                      ? _buildMyStockScroll() // buttons + search/filter collapse
                      : _buildBuyerInterestTab(),
                ),
              ],
            ),
    );
  }

  // ── Stats bar ─────────────────────────────────────────────────────────────

  Widget _buildStatsBar() {
    final estValue = _estimatedOrderValue;
    // Counts reflect in-stock designs only (out-of-stock are hidden here).
    // Inquiry count already lives on the Inquiry tab badge, so the stats bar
    // shows total boxes in stock instead (a number not surfaced elsewhere).
    final inStock = _inStockDesigns;
    final totalBoxes = inStock.fold(0, (s, d) => s + d.boxQuantity);
    return Container(
      color: const Color(0xFF1B4F72).withValues(alpha: 0.05),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statItem('${inStock.length}', 'Designs',
              Icons.grid_view_rounded, const Color(0xFF1B4F72)),
          _divider(),
          _statItem('$totalBoxes', 'Boxes',
              Icons.inventory_2_rounded, const Color(0xFF2E7D32)),
          _divider(),
          _statItem(
              '₹${estValue >= 1000 ? '${(estValue / 1000).toStringAsFixed(1)}k' : estValue.toStringAsFixed(0)}',
              'Est. Value',
              Icons.currency_rupee_rounded,
              const Color(0xFF6A1B9A)),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 22, color: Colors.grey.shade300);

  // Banner shown when some of the stockist's added stock is held for admin
  // approval (big-stock rule: 10,000+ boxes in a day). It's not live yet.
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
                '$_pendingBoxes boxes awaiting admin approval — not live yet.',
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
  Widget _statItem(
      String value, String label, IconData icon, Color color) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

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
            _tabPill('Stock', Icons.inventory_2_outlined, _activeTab == 0,
                () => setState(() => _activeTab = 0)),
            const SizedBox(width: 6),
            _tabPill('Inquiry', Icons.bookmark_outlined, _activeTab == 1,
                () => setState(() => _activeTab = 1), badge: interestCount),
            // Wider gap so the Inquiry badge doesn't crowd the divider.
            Container(
                width: 1,
                height: 22,
                margin: const EdgeInsets.only(left: 14, right: 10),
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
                        horizontal: 10, vertical: 7),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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

  // My Stock: collapsing header (action buttons + search/filter) over the grid.
  Widget _buildMyStockScroll() {
    final designs = _filteredAndSorted;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              _buildActionButtonRow(),
              _buildSearchFilterRow(),
            ],
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
            padding: const EdgeInsets.all(12),
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

  // The Upload button offers two stock sources: a PDF stock report (parsed,
  // with images) or a plain Excel stock list (quantities only, photos reused).
  void _showUploadSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Color(0xFF1B4F72)),
              title: const Text('Upload PDF stock report'),
              subtitle: const Text('Parses designs + tile photos'),
              onTap: () async {
                Navigator.pop(ctx);
                await context.push('/stockist/stock/upload');
                _load();
              },
            ),
            ListTile(
              leading: const Icon(Icons.table_view_rounded, color: Color(0xFF2E7D32)),
              title: const Text('Import Excel stock list'),
              subtitle: const Text('Design, size, quality, boxes — photos reused'),
              onTap: () async {
                Navigator.pop(ctx);
                await context.push('/stockist/stock/import-excel');
                _load();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
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
            await context.push('/stockist/stock/add');
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
    var localStockType = _stockType;
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
                        summary: localStockType,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _filterStockTypes
                              .map((t) => chip(t, localStockType == t,
                                  () => setSheet(() => localStockType = t)))
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
        _stockType = localStockType;
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

  // ── Buyer Interest tab ────────────────────────────────────────────────────

  Widget _buildBuyerInterestTab() {
    final interests = _buyerInterestDesigns;

    if (interests.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bookmark_outline_rounded,
                size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('No inquiries yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            Text(
              'When buyers bookmark your designs,\nthey will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: Colors.grey.shade400),
            ),
          ],
        ),
      );
    }

    final totalBuyerBoxes = interests.fold(
        0, (sum, d) => sum + (_inquiries[d.id]?.boxes ?? 0));

    return Column(
      children: [
        // Summary strip
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF2E7D32).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: const Color(0xFF2E7D32).withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _interestStat('${interests.length}', 'Designs'),
              Container(
                  width: 1,
                  height: 28,
                  color: Colors.grey.shade300),
              _interestStat('$totalBuyerBoxes', 'Boxes Wanted'),
              Container(
                  width: 1,
                  height: 28,
                  color: Colors.grey.shade300),
              _interestStat(
                  '₹${_estimatedOrderValue >= 1000 ? '${(_estimatedOrderValue / 1000).toStringAsFixed(1)}k' : _estimatedOrderValue.toStringAsFixed(0)}',
                  'Est. Value'),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            itemCount: interests.length,
            itemBuilder: (_, i) => _buildInterestCard(interests[i]),
          ),
        ),
      ],
    );
  }

  Widget _interestStat(String value, String label) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Color(0xFF2E7D32))),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: Colors.grey)),
        ],
      );

  Widget _buildInterestCard(TileDesign d) {
    final inq = _inquiries[d.id];
    final buyerQty = inq?.boxes ?? 0;
    final buyers = inq?.buyers ?? 0;
    final available = d.boxQuantity;
    final canFulfill = available >= buyerQty;
    final imageUrl = d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6)
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: imageUrl.isEmpty
                ? Container(
                    width: 68, height: 68,
                    color: Colors.grey.shade100,
                    child: Icon(Icons.add_photo_alternate_outlined,
                        size: 28, color: Colors.grey.shade400),
                  )
                : CachedNetworkImage(
                    imageUrl: imageUrl,
                    width: 68,
                    height: 68,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.image_not_supported,
                            size: 28)),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                    '${d.size.replaceAll(' mm', '')} · ${d.surfaceType} · ${d.quality}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _badge('$buyers buyer${buyers == 1 ? '' : 's'}',
                        const Color(0xFF6A1B9A),
                        const Color(0xFFF3E5F5)),
                    _badge('Wants: $buyerQty boxes',
                        const Color(0xFF1565C0),
                        const Color(0xFFE3F2FD)),
                    _badge(
                        'Available: $available',
                        canFulfill
                            ? const Color(0xFF2E7D32)
                            : Colors.red.shade700,
                        canFulfill
                            ? const Color(0xFFE8F5E9)
                            : const Color(0xFFFFEBEE)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _interestAction('Buyers', Icons.people_alt_outlined,
                  const Color(0xFF6A1B9A), () => _showBuyersSheet(d)),
              const SizedBox(height: 6),
              _interestAction(
                  'Dispatch', Icons.local_shipping_outlined, Colors.red.shade700,
                  () async {
                await context.push('/stockist/stock/dispatch', extra: d.id);
                _load();
              }),
              const SizedBox(height: 6),
              _interestAction('Reject', Icons.block_outlined,
                  Colors.grey.shade700, () => _confirmRejectAll(d)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _interestAction(
          String label, IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 78,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(height: 1),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
      );

  // Bottom sheet: which companies want this design and how many boxes, with a
  // per-buyer Reject that removes that buyer's inquiry (My Choice).
  void _showBuyersSheet(TileDesign d) async {
    final fetched = await _service.getDesignBuyers(d.id);
    if (!mounted) return;
    if (fetched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No buyers for this design')));
      return;
    }
    final buyers = List<Map<String, dynamic>>.from(fetched);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          maxChildSize: 0.85,
          builder: (ctx, scrollCtrl) => Column(
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.people_alt_outlined,
                        color: Color(0xFF6A1B9A), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Buyers for ${d.name}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: buyers.isEmpty
                    ? const Center(
                        child: Text('All inquiries rejected',
                            style: TextStyle(color: Colors.grey)))
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.all(12),
                        itemCount: buyers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, i) {
                          final b = buyers[i];
                          final contact = (b['contact'] ?? '').toString();
                          final phone = (b['phone'] ?? '').toString();
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text((b['company'] ?? '').toString(),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14)),
                                      if (contact.isNotEmpty || phone.isNotEmpty)
                                        Text(
                                            [contact, phone]
                                                .where((x) => x.isNotEmpty)
                                                .join('  ·  '),
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey.shade600)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1565C0)
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text('${b['boxes']} boxes',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF1565C0))),
                                ),
                                IconButton(
                                  icon: Icon(Icons.block_outlined,
                                      size: 20, color: Colors.red.shade400),
                                  tooltip: 'Reject this inquiry',
                                  onPressed: () async {
                                    final ok = await _confirmRejectBuyer(d, b);
                                    if (ok) setSheet(() => buyers.removeAt(i));
                                  },
                                ),
                              ],
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
    _load(); // refresh dashboard inquiry counts after the sheet closes
  }

  // Confirms + rejects one buyer's inquiry; returns true if it was rejected.
  Future<bool> _confirmRejectBuyer(
      TileDesign d, Map<String, dynamic> b) async {
    final company = (b['company'] ?? 'this buyer').toString();
    final endUserId = (b['end_user_id'] ?? '').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reject inquiry'),
        content: Text(
            'Reject $company\'s request for "${d.name}"? '
            'This removes their inquiry.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reject',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return false;
    await _service.rejectInquiry(d.id, endUserId);
    return true;
  }

  // Confirms + rejects every buyer's inquiry for a design, then refreshes.
  Future<void> _confirmRejectAll(TileDesign d) async {
    final inq = _inquiries[d.id];
    final buyers = inq?.buyers ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reject all inquiries'),
        content: Text(
            'Reject all $buyers buyer${buyers == 1 ? '' : 's'} for "${d.name}"? '
            'This removes every inquiry for this design.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reject all',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _service.rejectDesignInquiries(d.id);
    await _load();
  }

  Widget _badge(String label, Color fg, Color bg) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                color: fg,
                fontWeight: FontWeight.w600)),
      );
}

// ── Share-links bottom sheet ─────────────────────────────────────────────────
// Lists the stockist's public-catalog links — the always-on Permanent one plus
// any create-on-demand links (with optional expiry) — and lets them create new
// links, copy, share to WhatsApp, or revoke a time-limited one.
class _ShareLinksSheet extends StatefulWidget {
  final SupabaseDataService service;
  const _ShareLinksSheet({required this.service});
  @override
  State<_ShareLinksSheet> createState() => _ShareLinksSheetState();
}

class _ShareLinksSheetState extends State<_ShareLinksSheet> {
  List<ShareLink> _links = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final links = await widget.service.getMyShareLinks();
    if (!mounted) return;
    setState(() {
      _links = links;
      _loading = false;
    });
  }

  // Hash-style URL so the link routes on any static host (no server rewrite).
  String _urlFor(String token) => '${AppConfig.shareBaseUrl}/#/s/$token';

  String _statusLabel(ShareLink l) {
    if (l.expiresAt == null) return 'Never expires';
    if (l.expired) return 'Expired';
    final diff = l.expiresAt!.difference(DateTime.now());
    if (diff.inDays >= 1) {
      return 'Expires in ${diff.inDays} day${diff.inDays == 1 ? '' : 's'}';
    }
    if (diff.inHours >= 1) {
      return 'Expires in ${diff.inHours} hour${diff.inHours == 1 ? '' : 's'}';
    }
    return 'Expires soon';
  }

  Future<void> _copy(String token) async {
    await Clipboard.setData(ClipboardData(text: _urlFor(token)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied.')));
    }
  }

  Future<void> _whatsapp(String token) async {
    final uri = Uri.parse(
        'https://wa.me/?text=${Uri.encodeComponent('My tile catalog: ${_urlFor(token)}')}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _create() async {
    final duration = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Create a link',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
            for (final d in kShareLinkDurations)
              ListTile(
                leading: Icon(
                    d.value == 'permanent'
                        ? Icons.all_inclusive
                        : Icons.schedule,
                    color: const Color(0xFF1B4F72)),
                title: Text(d.label),
                onTap: () => Navigator.pop(ctx, d.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (duration == null) return;
    setState(() => _busy = true);
    final ok = await widget.service.createShareLink(duration);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _reload();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create link.')));
    }
  }

  Future<void> _revoke(ShareLink l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke link?'),
        content: Text('The "${l.label}" link will stop working immediately. '
            'This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Revoke', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (yes != true || l.id == null) return;
    setState(() => _busy = true);
    final ok = await widget.service.revokeShareLink(l.id!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _reload();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not revoke link.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Share your catalog',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create link'),
                ),
              ],
            ),
            const Text(
                'Send a link to buyers you choose — they view your in-stock '
                'designs in a browser, no app or login needed. Time-limited '
                'links stop working automatically when they expire.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _links.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _linkTile(_links[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _linkTile(ShareLink l) {
    final expired = l.expired;
    final url = _urlFor(l.token);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: expired ? Colors.red.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: expired ? Colors.red.shade200 : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(l.label,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B4F72))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_statusLabel(l),
                    style: TextStyle(
                        fontSize: 11,
                        color: expired
                            ? Colors.red.shade700
                            : Colors.grey.shade600)),
              ),
              if (l.revocable)
                InkWell(
                  onTap: _busy ? null : () => _revoke(l),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.delete_outline,
                        size: 18, color: Colors.red),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF1B4F72))),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: expired ? null : () => _copy(l.token),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 6)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: expired ? null : () => _whatsapp(l.token),
                  icon: const Icon(Icons.chat_rounded, size: 16),
                  label: const Text('WhatsApp'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
