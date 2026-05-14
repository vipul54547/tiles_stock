import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../models/stockist.dart';
import '../models/tile_design.dart';
import '../services/data_service.dart';
import 'end_user/stockist_group_screen.dart' show stockistGroups;

const _qualities = ['Premium', 'Standard'];
const _groupColors = [Color(0xFF1B4F72), Color(0xFF2E7D32), Color(0xFF6A1B9A)];
const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
};

class _StockistData {
  final Stockist stockist;
  final int totalBoxes;
  final Map<String, Map<String, int>> sizeTable;
  final Set<String> qualities;
  final List<TileDesign> designs;

  _StockistData({
    required this.stockist,
    required this.totalBoxes,
    required this.sizeTable,
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
  final DataService _service = MockDataService();
  List<_StockistData> _allData = [];
  List<String> _allSizes = [];
  List<String> _allSurfaces = [];
  bool _loading = true;

  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _searchActive = false;

  // Mock notification count
  int _notificationCount = 3;

  // Quality filter
  final Set<String> _selectedQualities = {};

  // Size / Finish filter
  final Set<String> _selectedSizes = {};
  final Set<String> _selectedSurfaces = {};

  int get _activeFilterCount => _selectedSizes.length + _selectedSurfaces.length;

  // Group filter
  int _activeGroupIndex = -1;

  // Platform-level benchmarks — computed as getters so they always
  // reflect the active filters (size, surface, quality).
  List<TileDesign> get _platformFilteredDesigns {
    var all = _allData.expand((d) => d.designs).toList();
    if (_selectedQualities.isNotEmpty) {
      all = all.where((t) => _selectedQualities.contains(t.quality)).toList();
    }
    if (_selectedSizes.isNotEmpty) {
      all = all.where((t) => _selectedSizes.contains(t.size)).toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      all = all.where((t) => _selectedSurfaces.contains(t.surfaceType)).toList();
    }
    return all;
  }

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
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _dismissKeyboard();
    _searchCtrl.clear();
    setState(() {
      _searchQuery = '';
      _searchActive = false;
    });
  }

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait([
      _service.getAllStockists(),
      _service.getAllDesigns(),
    ]);

    final stockists = results[0] as List<Stockist>;
    final designs = results[1] as List<TileDesign>;

    final sizes = designs.map((d) => d.size).toSet().toList()..sort();
    final surfaces = designs.map((d) => d.surfaceType).toSet().toList()..sort();

    final data = stockists.asMap().entries.map((e) {
      final s = e.value;
      final myDesigns = designs.where((d) => d.stockistId == s.id).toList();
      final totalBoxes = myDesigns.fold(0, (sum, d) => sum + d.boxQuantity);
      final quals = myDesigns.map((d) => d.quality).toSet();

      final sizeTable = <String, Map<String, int>>{};
      for (final size in sizes) {
        sizeTable[size] = {};
        for (final surface in surfaces) {
          final matches =
              myDesigns.where((d) => d.size == size && d.surfaceType == surface);
          sizeTable[size]![surface] =
              matches.isEmpty ? 0 : matches.first.boxQuantity;
        }
      }

      return _StockistData(
        stockist: s,
        totalBoxes: totalBoxes,
        sizeTable: sizeTable,
        qualities: quals,
        designs: myDesigns,
      );
    }).toList();

    setState(() {
      _allData = data;
      _allSizes = sizes;
      _allSurfaces = surfaces;
      _loading = false;
    });
  }

  List<TileDesign> _filteredDesigns(_StockistData d) {
    var designs = d.designs;
    if (_selectedQualities.isNotEmpty) {
      designs = designs.where((t) => _selectedQualities.contains(t.quality)).toList();
    }
    if (_selectedSizes.isNotEmpty) {
      designs = designs.where((t) => _selectedSizes.contains(t.size)).toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      designs = designs.where((t) => _selectedSurfaces.contains(t.surfaceType)).toList();
    }
    return designs;
  }

  int _filteredBoxCount(_StockistData d) {
    final designs = _filteredDesigns(d);
    return designs.fold(0, (sum, t) => sum + t.boxQuantity);
  }

  double _filteredPerDesignAvg(_StockistData d) {
    final designs = _filteredDesigns(d);
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

  List<_StockistData> get _filteredData {
    var result = _allData;
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
    if (_selectedQualities.isNotEmpty) {
      result = result
          .where((d) => d.designs.any((t) => _selectedQualities.contains(t.quality)))
          .toList();
    }
    if (_selectedSizes.isNotEmpty) {
      result = result
          .where((d) => d.designs.any((t) => _selectedSizes.contains(t.size)))
          .toList();
    }
    if (_selectedSurfaces.isNotEmpty) {
      result = result
          .where((d) =>
              d.designs.any((t) => _selectedSurfaces.contains(t.surfaceType)))
          .toList();
    }
    result.sort((a, b) {
      final tierDiff = _tier(a).compareTo(_tier(b));
      if (tierDiff != 0) return tierDiff;
      return _filteredPerDesignAvg(b).compareTo(_filteredPerDesignAvg(a));
    });
    return result;
  }

  void _showFilterSheet() {
    _dismissKeyboard();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.6;
    var localSizes     = Set<String>.from(_selectedSizes);
    var localSurfaces  = Set<String>.from(_selectedSurfaces);

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (_, setSheet) {
          Widget chipRow(Set<String> set, List<String> options) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options.map((v) {
                  final sel = set.contains(v);
                  return GestureDetector(
                    onTap: () => setSheet(() {
                      if (set.contains(v)) { set.remove(v); } else { set.add(v); }
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: sel ? const Color(0xFF1B4F72) : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: sel ? const Color(0xFF1B4F72) : Colors.grey.shade400,
                        ),
                      ),
                      child: Text(
                        v,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );

          return SizedBox(
            height: sheetHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.tune_rounded, color: Color(0xFF1B4F72)),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Filter',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: Color(0xFF1B4F72))),
                      ),
                      TextButton(
                        onPressed: () => setSheet(() {
                          localSizes.clear();
                          localSurfaces.clear();
                        }),
                        child: const Text('Reset All',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text('Size',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1B4F72))),
                      const SizedBox(height: 10),
                      chipRow(localSizes, _allSizes),
                      const SizedBox(height: 20),
                      const Text('Finish',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF1B4F72))),
                      const SizedBox(height: 10),
                      chipRow(localSurfaces, _allSurfaces),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      if (mounted) {
        setState(() {
          _selectedSizes
            ..clear()
            ..addAll(localSizes);
          _selectedSurfaces
            ..clear()
            ..addAll(localSurfaces);
        });
      }
    });
  }

  void _showNotifications() {
    setState(() => _notificationCount = 0);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Icon(Icons.notifications_outlined, color: Color(0xFF1B4F72)),
                SizedBox(width: 8),
                Text('Notifications',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFF1B4F72))),
              ],
            ),
          ),
          const Divider(height: 1),
          _notifTile(Icons.inventory_2_outlined, 'Stockist A updated stock',
              '50 boxes of Marble Elite added', '2 min ago'),
          _notifTile(Icons.storefront_outlined, 'New stockist registered',
              'Sunshine Tiles joined the platform', '1 hour ago'),
          _notifTile(Icons.send_outlined, 'Inquiry received',
              'A buyer inquired about 600x600 Glossy', '3 hours ago'),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _notifTile(IconData icon, String title, String subtitle, String time) =>
      ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF1B4F72).withValues(alpha: 0.1),
          child: Icon(icon, color: const Color(0xFF1B4F72), size: 20),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        trailing: Text(time,
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
      );

  Widget _navButton(String label, IconData icon, VoidCallback? onTap,
      {bool active = false}) {
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      leading: IconButton(
        icon: const Icon(Icons.logout),
        tooltip: 'Logout',
        onPressed: () => context.go('/login'),
      ),
      title: const Text('Tiles Stock'),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _load,
        ),
        // Bell icon with badge
        Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: _showNotifications,
            ),
            if (_notificationCount > 0)
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
                  child: Center(
                    child: Text(
                      '$_notificationCount',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
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
                'Manage Group',
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
                null,
                active: true,
              ),
              const SizedBox(width: 8),
              _navButton(
                'All Design',
                Icons.grid_view_rounded,
                () => context.go('/all-designs'),
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

    final filtered = _filteredData;

    return Scaffold(
      appBar: appBar,
      body: Column(
        children: [
          _buildQualityRow(),
          _buildGroupRow(filtered.length),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text('No stockists found',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) => _StockistCard(
                      data: filtered[i],
                      sizes: _allSizes,
                      surfaces: _allSurfaces,
                      selectedQualities: _selectedQualities,
                      selectedSizes: _selectedSizes,
                      selectedSurfaces: _selectedSurfaces,
                      onViewProfile: () async {
                        await context.push(
                            '/stockist/${filtered[i].stockist.id}/portfolio');
                        if (mounted) _load();
                      },
                      onToggleGroup: (groupIndex) => setState(() {
                        final ids = stockistGroups[groupIndex].stockistIds;
                        final stockistId = filtered[i].stockist.id;
                        if (ids.contains(stockistId)) {
                          ids.remove(stockistId);
                        } else {
                          ids.add(stockistId);
                        }
                      }),
                    ),
                  ),
          ),
          _buildLegend(),
        ],
      ),
    );
  }

  // ── Group filter row ─────────────────────────────────────────────────────

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
                  stockistGroups[i].stockistIds.isEmpty
                      ? stockistGroups[i].name
                      : '${stockistGroups[i].name} (${stockistGroups[i].stockistIds.length})',
                  _activeGroupIndex == i,
                  stockistGroups[i].stockistIds.isEmpty
                      ? null
                      : () {
                          _dismissKeyboard();
                          setState(() => _activeGroupIndex = i);
                        },
                ),
                const SizedBox(width: 6),
              ],
              OutlinedButton.icon(
                onPressed: () async {
                  _dismissKeyboard();
                  await context.push('/stockist-groups');
                  if (mounted) {
                    setState(() {
                      if (_activeGroupIndex >= 0 &&
                          stockistGroups[_activeGroupIndex].stockistIds.isEmpty) {
                        _activeGroupIndex = -1;
                      }
                    });
                  }
                },
                icon: const Icon(Icons.tune_rounded, size: 14),
                label: const Text('Manage', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  side: const BorderSide(color: Color(0xFF1B4F72)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          child: Text(
            'Showing $count stockist${count == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  // ── Quality filter row + inline search toggle ────────────────────────────

  Widget _buildQualityRow() {
    if (_searchActive) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                onChanged: (v) => setState(() => _searchQuery = v),
                onSubmitted: (_) => _closeSearch(),
                decoration: InputDecoration(
                  hintText: 'Search stockist name or ID...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _closeSearch,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.close, size: 20, color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          ..._qualities.map((q) {
            final m = _qualityMeta[q]!;
            final selected = _selectedQualities.contains(q);
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  _dismissKeyboard();
                  setState(() {
                    if (selected) { _selectedQualities.remove(q); } else { _selectedQualities.add(q); }
                  });
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
                      Icon(m.icon, size: 12, color: selected ? Colors.white : m.fg),
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
          }),
          GestureDetector(
            onTap: () => setState(() => _searchActive = true),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2FD),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1565C0), width: 1),
              ),
              child: const Icon(Icons.search, size: 16, color: Color(0xFF1565C0)),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _showFilterSheet,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _activeFilterCount > 0
                        ? const Color(0xFF1B4F72)
                        : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _activeFilterCount > 0
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade400,
                    ),
                  ),
                  child: Icon(Icons.tune_rounded,
                      size: 16,
                      color: _activeFilterCount > 0
                          ? Colors.white
                          : Colors.grey.shade600),
                ),
                if (_activeFilterCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Center(
                        child: Text('$_activeFilterCount',
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
          if (_activeFilterCount > 0) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => setState(() {
                _selectedSizes.clear();
                _selectedSurfaces.clear();
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
            ),
          ],
        ],
      ),
    );
  }

  // ── Legend ────────────────────────────────────────────────────────────────

  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

// ── Stockist card ─────────────────────────────────────────────────────────────

class _StockistCard extends StatelessWidget {
  final _StockistData data;
  final List<String> sizes;
  final List<String> surfaces;
  final Set<String> selectedQualities;
  final Set<String> selectedSizes;
  final Set<String> selectedSurfaces;
  final VoidCallback onViewProfile;
  final void Function(int groupIndex) onToggleGroup;

  const _StockistCard({
    required this.data,
    required this.sizes,
    required this.surfaces,
    required this.selectedQualities,
    required this.selectedSizes,
    required this.selectedSurfaces,
    required this.onViewProfile,
    required this.onToggleGroup,
  });

  (Map<String, Map<String, int>>, int) _computeDisplayData(
      List<String> dispSizes, List<String> dispSurfaces) {
    var filtered = data.designs;
    if (selectedQualities.isNotEmpty) {
      filtered = filtered.where((d) => selectedQualities.contains(d.quality)).toList();
    }
    if (selectedSizes.isNotEmpty) {
      filtered = filtered.where((d) => selectedSizes.contains(d.size)).toList();
    }
    if (selectedSurfaces.isNotEmpty) {
      filtered = filtered.where((d) => selectedSurfaces.contains(d.surfaceType)).toList();
    }

    final total = filtered.fold(0, (sum, d) => sum + d.boxQuantity);

    final table = <String, Map<String, int>>{};
    for (final size in dispSizes) {
      table[size] = {};
      for (final surface in dispSurfaces) {
        final match =
            filtered.where((d) => d.size == size && d.surfaceType == surface);
        table[size]![surface] = match.isEmpty ? 0 : match.first.boxQuantity;
      }
    }
    return (table, total);
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
    final (sizeTable, displayBoxes) = _computeDisplayData(dispSizes, dispSurfaces);
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
                      Text(s.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('ID: ${s.id}',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text('$displayBoxes boxes',
                          style: const TextStyle(
                              color: Color(0xFF1B4F72),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
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
                  final color = _groupColors[i];
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
              child: _buildTable(sizeTable, dispSizes, dispSurfaces),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(Map<String, Map<String, int>> sizeTable,
      List<String> dispSizes, List<String> dispSurfaces) {
    const firstColW = 88.0;
    const cellW = 56.0;
    const headerH = 30.0;
    const cellH = 28.0;

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
                  final boxes = sizeTable[size]?[sf] ?? 0;
                  return _boxCell(boxes, cellW, cellH);
                }),
              ],
            )),
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

  Widget _boxCell(int boxes, double w, double h) {
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
      child: Text(boxes == 0 ? '-' : '$boxes',
          style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}
