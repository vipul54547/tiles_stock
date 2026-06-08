import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../models/stockist.dart';
import '../models/tile_design.dart';
import '../services/supabase_data_service.dart';
import '../services/supabase_auth_service.dart';
import '../widgets/tile_card.dart';
import 'end_user/stockist_group_screen.dart'
    show stockistGroups, loadStockistGroupsFromDb;
import '../models/choice_state.dart';
import '../utils/design_ranking.dart';
import '../utils/my_choice.dart';

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
  final SupabaseDataService _service = SupabaseDataService();
  List<_StockistData> _allData = [];
  List<TileDesign> _allDesigns = [];
  List<String> _allSizes = [];
  List<String> _allSurfaces = [];
  bool _loading = true;
  bool _viewDesigns = false;

  final _searchCtrl = TextEditingController();
  String _searchQuery  = '';
  bool _searchActive   = false;
  bool _searchByDesign = true; // true = design name, false = stockist

  // Mock notification count
  int _notificationCount = 3;

  // Quality filter
  final Set<String> _selectedQualities = {};

  // Stockist filter (Size + Finish)
  final Set<String> _selectedSizes = {};
  final Set<String> _selectedSurfaces = {};

  int get _activeFilterCount => _selectedSizes.length + _selectedSurfaces.length;

  // Design filter (Qty, Colour, Stock Type — in addition to shared Size/Finish/Quality)
  final Set<String> _selectedColours = {};
  String _designStockType = 'Both';
  final _minQtyCtrl = TextEditingController();
  final _maxQtyCtrl = TextEditingController();

  int get _designFilterCount {
    int c = _selectedSizes.length + _selectedSurfaces.length + _selectedColours.length;
    if (_designStockType != 'Both') c++;
    if (_minQtyCtrl.text.isNotEmpty) c++;
    if (_maxQtyCtrl.text.isNotEmpty) c++;
    return c;
  }

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
    _minQtyCtrl.dispose();
    _maxQtyCtrl.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _dismissKeyboard();
    _searchCtrl.clear();
    setState(() {
      _searchQuery    = '';
      _searchActive   = false;
      _searchByDesign = true;
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
    await loadStockistGroupsFromDb(); // the user's saved group filters
    await loadMyChoices();            // restore saved My Choice selections

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
      // Blended catalog ranking (fresh per-session seed) for the All-Design grid.
      _allDesigns =
          rankDesigns(designs, seed: DateTime.now().microsecondsSinceEpoch);
      _allSizes = sizes;
      _allSurfaces = surfaces;
      _loading = false;
    });
  }

  List<TileDesign> _stockistDesigns(_StockistData d) {
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

  List<TileDesign> get _filteredDesigns {
    var result = _allDesigns;
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      if (_searchByDesign) {
        result = result.where((d) => d.name.toLowerCase().contains(q)).toList();
      } else {
        final matchingIds = _allData
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
      result = result.where((d) => _selectedSurfaces.contains(d.surfaceType)).toList();
    }
    if (_selectedColours.isNotEmpty) {
      result = result.where((d) => _selectedColours.contains(d.colour)).toList();
    }
    if (_designStockType != 'Both') {
      result = result.where((d) => d.stockType == _designStockType).toList();
    }
    final minQty = int.tryParse(_minQtyCtrl.text);
    final maxQty = int.tryParse(_maxQtyCtrl.text);
    if (minQty != null) result = result.where((d) => d.boxQuantity >= minQty).toList();
    if (maxQty != null) result = result.where((d) => d.boxQuantity <= maxQty).toList();
    // Preserve the blended ranking order from _load (no quantity re-sort).
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

  static const _filterColours    = ['White', 'Beige', 'Grey', 'Black', 'Cream'];
  static const _filterStockTypes = ['One Time', 'Regular', 'Both'];

  void _showDesignFilterSheet() {
    _dismissKeyboard();
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.82;
    final savedMin     = _minQtyCtrl.text;
    final savedMax     = _maxQtyCtrl.text;
    var localSizes      = Set<String>.from(_selectedSizes);
    var localSurfaces   = Set<String>.from(_selectedSurfaces);
    var localColours    = Set<String>.from(_selectedColours);
    var localStockType  = _designStockType;

    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget sectionTitle(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
            child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          );

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
                          localColours.clear();
                          localStockType = 'Both';
                          _minQtyCtrl.clear();
                          _maxQtyCtrl.clear();
                        }),
                        child: const Text('Reset all',
                            style: TextStyle(color: Colors.red, fontSize: 13)),
                      ),
                      const SizedBox(width: 4),
                      ElevatedButton(
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.of(ctx).pop(true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4F72),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Apply',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      sectionTitle('Qty (boxes)'),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _minQtyCtrl,
                            keyboardType: TextInputType.number,
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
                            decoration: InputDecoration(
                              hintText: 'Max', isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ]),
                      Wrap(spacing: 8, runSpacing: 8,
                        children: _allSizes.map((s) => filterChip(s, localSizes.contains(s),
                          () => setSheet(() {
                            if (localSizes.contains(s)) {
                              localSizes.remove(s);
                            } else {
                              localSizes.add(s);
                            }
                          }))).toList()),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8,
                        children: _allSurfaces.map((s) => filterChip(s, localSurfaces.contains(s),
                          () => setSheet(() {
                            if (localSurfaces.contains(s)) {
                              localSurfaces.remove(s);
                            } else {
                              localSurfaces.add(s);
                            }
                          }))).toList()),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8,
                        children: _filterColours.map((c) => filterChip(c, localColours.contains(c),
                          () => setSheet(() {
                            if (localColours.contains(c)) {
                              localColours.remove(c);
                            } else {
                              localColours.add(c);
                            }
                          }))).toList()),
                      sectionTitle('Stock Type'),
                      Wrap(spacing: 8, runSpacing: 8,
                        children: _filterStockTypes.map((t) => filterChip(
                          t, localStockType == t,
                          () => setSheet(() => localStockType = t),
                        )).toList()),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((applied) {
      if (!mounted) return;
      if (applied == true) {
        setState(() {
          _selectedSizes      ..clear()..addAll(localSizes);
          _selectedSurfaces   ..clear()..addAll(localSurfaces);
          _selectedColours    ..clear()..addAll(localColours);
          _designStockType    = localStockType;
        });
      } else {
        _minQtyCtrl.text = savedMin;
        _maxQtyCtrl.text = savedMax;
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
                  // Big image
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
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
                          // Size / surface / quality chips
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _infoChip(d.size.replaceAll(' mm', '')),
                              _infoChip(d.surfaceType),
                              _infoChip(d.quality),
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
                                    onTap: () {
                                      if (inGroup) {
                                        stockistGroups[i].stockistIds.remove(d.stockistId);
                                      } else {
                                        stockistGroups[i].stockistIds.add(d.stockistId);
                                      }
                                      setSheet(() {});
                                      setState(() {});
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
      leading: IconButton(
        icon: const Icon(Icons.logout),
        tooltip: 'Logout',
        onPressed: () async {
          await SupabaseAuthService().logout();
          if (context.mounted) context.go('/login');
        },
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
                _viewDesigns ? () => setState(() => _viewDesigns = false) : null,
                active: !_viewDesigns,
              ),
              const SizedBox(width: 8),
              _navButton(
                'All Design',
                Icons.grid_view_rounded,
                _viewDesigns ? null : () => setState(() => _viewDesigns = true),
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

    return Scaffold(
      appBar: appBar,
      body: Column(
        children: [
          _buildQualityRow(),
          _buildGroupRow(
              _viewDesigns ? filteredDesigns.length : filteredStockists.length),
          Expanded(
            child: _viewDesigns
                ? filteredDesigns.isEmpty
                    ? const Center(
                        child: Text('No designs found',
                            style: TextStyle(color: Colors.grey)))
                    : MasonryGridView.count(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        itemCount: filteredDesigns.length,
                        itemBuilder: (_, i) => TileCard(
                          design: filteredDesigns[i],
                          onTap: () => _openDesignSheet(i, filteredDesigns),
                          isChosen: myChoiceQuantities
                              .containsKey(filteredDesigns[i].id),
                          onChoiceTap: () => setState(() {
                            final id = filteredDesigns[i].id;
                            if (myChoiceQuantities.containsKey(id)) {
                              setMyChoiceQty(id, 0);
                            } else {
                              setMyChoiceQty(id, filteredDesigns[i].boxQuantity);
                            }
                          }),
                          onStockistTap: () => context.push(
                            '/stockist/${filteredDesigns[i].stockistId}/portfolio',
                            extra: filteredDesigns[i].id,
                          ),
                        ),
                      )
                : filteredStockists.isEmpty
                    ? const Center(
                        child: Text('No stockists found',
                            style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        itemCount: filteredStockists.length,
                        itemBuilder: (_, i) => _StockistCard(
                          data: filteredStockists[i],
                          sizes: _allSizes,
                          surfaces: _allSurfaces,
                          selectedQualities: _selectedQualities,
                          selectedSizes: _selectedSizes,
                          selectedSurfaces: _selectedSurfaces,
                          onViewProfile: () async {
                            await context.push(
                                '/stockist/${filteredStockists[i].stockist.id}/portfolio');
                            if (mounted) _load();
                          },
                          onToggleGroup: (groupIndex) => setState(() {
                            final ids = stockistGroups[groupIndex].stockistIds;
                            final stockistId = filteredStockists[i].stockist.id;
                            if (ids.contains(stockistId)) {
                              ids.remove(stockistId);
                            } else {
                              ids.add(stockistId);
                            }
                          }),
                        ),
                      ),
          ),
          if (!_viewDesigns) _buildLegend(),
        ],
      ),
    );
  }

  // ── Group filter row ─────────────────────────────────────────────────────

  Widget _searchToggleChip({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B4F72) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? const Color(0xFF1B4F72) : Colors.grey.shade400,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13,
                color: active ? Colors.white : Colors.grey.shade600),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : Colors.grey.shade700,
                )),
          ],
        ),
      ),
    );
  }

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
            _viewDesigns
                ? 'Showing $count design${count == 1 ? '' : 's'}'
                : 'Showing $count stockist${count == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  // ── Quality filter row + inline search toggle ────────────────────────────

  Widget _buildQualityRow() {
    if (_searchActive) {
      final hint = !_viewDesigns || !_searchByDesign
          ? 'Search stockist name or ID...'
          : 'Search design name...';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search field row
          Padding(
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
                      hintText: hint,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
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
                    child:
                        const Icon(Icons.close, size: 20, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          // Toggle chips — only in All Design view
          if (_viewDesigns)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  _searchToggleChip(
                    label: 'Design Name',
                    icon: Icons.grid_view_rounded,
                    active: _searchByDesign,
                    onTap: () {
                      if (!_searchByDesign) {
                        _searchCtrl.clear();
                        setState(() {
                          _searchByDesign = true;
                          _searchQuery    = '';
                        });
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _searchToggleChip(
                    label: 'Stockist',
                    icon: Icons.storefront_outlined,
                    active: !_searchByDesign,
                    onTap: () {
                      if (_searchByDesign) {
                        _searchCtrl.clear();
                        setState(() {
                          _searchByDesign = false;
                          _searchQuery    = '';
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
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
            onTap: _viewDesigns ? _showDesignFilterSheet : _showFilterSheet,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: (_viewDesigns ? _designFilterCount : _activeFilterCount) > 0
                        ? const Color(0xFF1B4F72)
                        : const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_viewDesigns ? _designFilterCount : _activeFilterCount) > 0
                          ? const Color(0xFF1B4F72)
                          : Colors.grey.shade400,
                    ),
                  ),
                  child: Icon(Icons.tune_rounded,
                      size: 16,
                      color: (_viewDesigns ? _designFilterCount : _activeFilterCount) > 0
                          ? Colors.white
                          : Colors.grey.shade600),
                ),
                if ((_viewDesigns ? _designFilterCount : _activeFilterCount) > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: Center(
                        child: Text(
                            '${_viewDesigns ? _designFilterCount : _activeFilterCount}',
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
          if ((_viewDesigns ? _designFilterCount : _activeFilterCount) > 0) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => setState(() {
                if (_viewDesigns) {
                  _selectedSizes.clear();
                  _selectedSurfaces.clear();
                  _selectedColours.clear();
                  _selectedQualities.clear();
                  _designStockType = 'Both';
                  _minQtyCtrl.clear();
                  _maxQtyCtrl.clear();
                } else {
                  _selectedSizes.clear();
                  _selectedSurfaces.clear();
                }
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
