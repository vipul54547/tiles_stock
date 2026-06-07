import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/tile_design.dart';
import '../../services/supabase_data_service.dart';
import '../../services/supabase_auth_service.dart';
import '../../widgets/tile_card.dart';
import '../../models/choice_state.dart';

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

class _State extends State<StockistDashboardScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _designs = [];
  bool _loading = true;
  String get _myStockistId => currentStockistUUID;

  // Tab
  int _activeTab = 0; // 0 = My Stock, 1 = Buyer Interest

  // Multi-select / delete mode
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  // My Stock filters
  final Set<String> _selectedQualities = {};
  String _sortBy = 'default';
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
    if (!mounted) return;
    setState(() {
      _designs = data;
      _loading = false;
    });
  }

  // ── Computed ──────────────────────────────────────────────────────────────

  List<TileDesign> get _filteredAndSorted {
    var result = _selectedQualities.isEmpty
        ? List<TileDesign>.from(_designs)
        : _designs
            .where((d) => _selectedQualities.contains(d.quality))
            .toList();

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
      _designs.where((d) => myChoiceQuantities.containsKey(d.id)).toList();

  double get _estimatedOrderValue => _buyerInterestDesigns.fold(
      0.0, (sum, d) => sum + d.boxPrice * (myChoiceQuantities[d.id] ?? 0));

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
              title: const Text('My Stock Dashboard'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined),
                  onPressed: () => context.push('/stockist/inquiries'),
                ),
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
      floatingActionButton: _activeTab == 0 && !_selectMode
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'dispatch',
                  onPressed: () => context.push('/stockist/stock/dispatch'),
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('Dispatch'),
                  backgroundColor: Colors.red[700],
                  foregroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'upload',
                  onPressed: () => context.push('/stockist/stock/upload'),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload PDF'),
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'add',
                  onPressed: () async {
                    await context.push('/stockist/stock/add');
                    _load(); // refresh after adding
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Design'),
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                ),
              ],
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildStatsBar(),
                _buildTabRow(),
                Expanded(
                  child: _activeTab == 0
                      ? _buildMyStockTab()
                      : _buildBuyerInterestTab(),
                ),
              ],
            ),
    );
  }

  // ── Stats bar ─────────────────────────────────────────────────────────────

  Widget _buildStatsBar() {
    final interest = _buyerInterestDesigns.length;
    final estValue = _estimatedOrderValue;
    return Container(
      color: const Color(0xFF1B4F72).withValues(alpha: 0.05),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statItem('${_designs.length}', 'Total Designs',
              Icons.grid_view_rounded, const Color(0xFF1B4F72)),
          _divider(),
          _statItem('$interest', 'Buyer Interest',
              Icons.bookmark_rounded,
              interest > 0 ? const Color(0xFF2E7D32) : Colors.grey),
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
      Container(width: 1, height: 36, color: Colors.grey.shade300);

  Widget _statItem(
      String value, String label, IconData icon, Color color) =>
      Column(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: color)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

  // ── Tab row ───────────────────────────────────────────────────────────────

  Widget _buildTabRow() {
    final interestCount = _buyerInterestDesigns.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          _tabButton('My Stock', Icons.inventory_2_outlined, 0),
          const SizedBox(width: 8),
          _tabButtonBadge(
              'Buyer Interest', Icons.bookmark_outlined, 1, interestCount),
        ],
      ),
    );
  }

  Widget _tabButton(String label, IconData icon, int index) {
    final active = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF1B4F72)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15,
                  color: active ? Colors.white : Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color:
                          active ? Colors.white : Colors.grey.shade600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabButtonBadge(
      String label, IconData icon, int index, int badgeCount) {
    final active = _activeTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = index),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFF1B4F72)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 15,
                      color: active
                          ? Colors.white
                          : Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: active
                              ? Colors.white
                              : Colors.grey.shade600)),
                ],
              ),
            ),
            if (badgeCount > 0)
              Positioned(
                top: -6,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$badgeCount',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── My Stock tab ──────────────────────────────────────────────────────────

  Widget _buildMyStockTab() {
    final designs = _filteredAndSorted;
    return Column(
      children: [
        _buildQualityFilter(),
        _buildSearchSortRow(),
        Expanded(
          child: designs.isEmpty
              ? const Center(
                  child: Text('No designs found',
                      style: TextStyle(color: Colors.grey)))
              : MasonryGridView.count(
                  padding: const EdgeInsets.all(12),
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  itemCount: designs.length,
                  itemBuilder: (_, i) {
                    final d = designs[i];
                    final outOfStock = d.boxQuantity == 0;
                    final lowStock = !outOfStock &&
                        d.boxQuantity < _lowStockThreshold;
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
                                : () => context
                                    .push('/stockist/stock/edit/${d.id}'),
                          ),
                          if (outOfStock || lowStock)
                            Positioned(
                              top: 6,
                              left: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 3),
                                decoration: BoxDecoration(
                                  color: outOfStock
                                      ? Colors.red
                                      : Colors.orange.shade700,
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
                          // Selection checkbox overlay
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
                                  border: Border.all(
                                    color: const Color(0xFF1B4F72),
                                    width: 2,
                                  ),
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check,
                                        size: 14, color: Colors.white)
                                    : null,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildQualityFilter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        children: _qualities.map((q) {
          final m = _qualityMeta[q]!;
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
                padding: const EdgeInsets.symmetric(
                    vertical: 6, horizontal: 4),
                decoration: BoxDecoration(
                  color: selected ? m.fg : m.bg,
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: m.fg, width: selected ? 2 : 1),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: m.fg.withValues(alpha: 0.22),
                              blurRadius: 4,
                              offset: const Offset(0, 2))
                        ]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon,
                        size: 12,
                        color: selected ? Colors.white : m.fg),
                    const SizedBox(width: 3),
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

  Widget _buildSearchSortRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _showSortSheet,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _sortBy != 'default'
                    ? const Color(0xFF1B4F72)
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _sortBy != 'default'
                      ? const Color(0xFF1B4F72)
                      : Colors.grey.shade300,
                ),
              ),
              child: Icon(Icons.sort_rounded,
                  size: 20,
                  color: _sortBy != 'default'
                      ? Colors.white
                      : Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
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
            Text('No buyer interest yet',
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
        0, (sum, d) => sum + (myChoiceQuantities[d.id] ?? 0));

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
    final buyerQty = myChoiceQuantities[d.id] ?? 0;
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
          GestureDetector(
            onTap: () =>
                context.push('/stockist/stock/edit/${d.id}'),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B4F72).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: const Color(0xFF1B4F72)
                        .withValues(alpha: 0.25)),
              ),
              child: const Icon(Icons.edit_outlined,
                  size: 18, color: Color(0xFF1B4F72)),
            ),
          ),
        ],
      ),
    );
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
