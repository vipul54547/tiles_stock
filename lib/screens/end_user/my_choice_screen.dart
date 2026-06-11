import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tile_design.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../utils/guest_gate.dart';
import '../../utils/my_choice.dart';

class MyChoiceScreen extends StatefulWidget {
  const MyChoiceScreen({super.key});
  @override
  State<MyChoiceScreen> createState() => _MyChoiceScreenState();
}

class _MyChoiceScreenState extends State<MyChoiceScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _allDesigns = [];
  List<Stockist> _allStockists = [];
  bool _loading = true;
  String? _filterStockistId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _service.getAllDesigns(),
      _service.getAllStockists(),
    ]);
    await loadMyChoices(); // restore saved selections
    if (!mounted) return;
    setState(() {
      _allDesigns = results[0] as List<TileDesign>;
      _allStockists = results[1] as List<Stockist>;
      _loading = false;
    });
  }

  List<TileDesign> get _chosenDesigns =>
      _allDesigns.where((d) => myChoiceQuantities.containsKey(d.id)).toList();

  Map<String, List<TileDesign>> get _groupedByStockist {
    final filtered = _filterStockistId == null
        ? _chosenDesigns
        : _chosenDesigns.where((d) => d.stockistId == _filterStockistId).toList();
    final map = <String, List<TileDesign>>{};
    for (final d in filtered) {
      map.putIfAbsent(d.stockistId, () => []).add(d);
    }
    return map;
  }

  Stockist? _stockistById(String id) {
    try {
      return _allStockists.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  String _buildMessage(Stockist stockist, List<TileDesign> designs) {
    final buffer = StringBuffer();
    buffer.writeln('Hello ${stockist.name},');
    buffer.writeln();
    buffer.writeln('Order Request:');
    int total = 0;
    for (int i = 0; i < designs.length; i++) {
      final d = designs[i];
      final qty = myChoiceQuantities[d.id] ?? d.boxQuantity;
      total += qty;
      buffer.writeln(
          '${i + 1}. ${d.name} (${d.size.replaceAll(' mm', '')}, ${d.surfaceType}, ${d.quality}) — $qty boxes');
    }
    buffer.writeln();
    buffer.writeln('Total: $total boxes');
    buffer.writeln();
    buffer.writeln('Please confirm availability.');
    return buffer.toString();
  }

  void _showSendSheet(Stockist stockist, List<TileDesign> designs) {
    if (blockIfGuest(context, feature: 'Placing orders')) return;
    final message = _buildMessage(stockist, designs);
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
            Text('Send Order to ${stockist.name}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
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
                  // WhatsApp needs the full international number (country code +
                  // phone), digits only — no '+'.
                  final phone = '${stockist.countryCode}${stockist.phone}'
                      .replaceAll(RegExp(r'[^0-9]'), '');
                  final uri = Uri.parse(
                      'https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
                  final ok = await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                  if (ok) {
                    // Auto-alert the stockist that a buyer reached out.
                    await _service.notifyStockist(stockist.id);
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('My Choice'),
        actions: [
          if (!_loading && _chosenDesigns.isNotEmpty)
            TextButton.icon(
              onPressed: _confirmClearAll,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Clear All'),
              style:
                  TextButton.styleFrom(foregroundColor: Colors.white),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _chosenDesigns.isEmpty
              ? _buildEmptyState()
              : _buildContent(),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear All Choices'),
        content: const Text(
            'Remove all designs from My Choice?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                clearMyChoices();
                _filterStockistId = null;
              });
              Navigator.pop(context);
            },
            style:
                TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final chosen = _chosenDesigns;
    final allStockistIds =
        chosen.map((d) => d.stockistId).toSet().toList();
    final grouped = _groupedByStockist;
    final visibleIds = grouped.keys.toList();

    // Reset stale filter
    if (_filterStockistId != null &&
        !allStockistIds.contains(_filterStockistId)) {
      _filterStockistId = null;
    }

    return Column(
      children: [
        _buildSummaryBar(chosen),
        _buildFilterChips(allStockistIds),
        Expanded(
          child: visibleIds.isEmpty
              ? const Center(
                  child: Text('No designs from this stockist',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(16, 8, 16, 80),
                  itemCount: visibleIds.length,
                  itemBuilder: (_, i) => _buildStockistSection(
                      visibleIds[i], grouped[visibleIds[i]]!),
                ),
        ),
      ],
    );
  }

  Widget _buildSummaryBar(List<TileDesign> chosen) {
    final stockistCount =
        chosen.map((d) => d.stockistId).toSet().length;
    final totalBoxes = chosen.fold(
        0, (sum, d) => sum + (myChoiceQuantities[d.id] ?? 0));
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding:
          const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: const Color(0xFF1B4F72).withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _summaryItem('${chosen.length}', 'Designs'),
          Container(
              width: 1, height: 28, color: Colors.grey.shade300),
          _summaryItem('$stockistCount', 'Stockists'),
          Container(
              width: 1, height: 28, color: Colors.grey.shade300),
          _summaryItem('$totalBoxes', 'Total Boxes'),
        ],
      ),
    );
  }

  Widget _summaryItem(String value, String label) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Color(0xFF1B4F72))),
          Text(label,
              style:
                  const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      );

  Widget _buildFilterChips(List<String> stockistIds) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          _filterChip('All', _filterStockistId == null,
              () => setState(() => _filterStockistId = null)),
          const SizedBox(width: 8),
          ...stockistIds.map((id) {
            final name = _stockistById(id)?.name ?? id;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _filterChip(
                  name,
                  _filterStockistId == id,
                  () => setState(() => _filterStockistId = id)),
            );
          }),
        ],
      ),
    );
  }

  Widget _filterChip(
          String label, bool active, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color:
                active ? const Color(0xFF1B4F72) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: active
                    ? const Color(0xFF1B4F72)
                    : Colors.grey.shade400),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.grey.shade700,
              )),
        ),
      );

  Widget _buildStockistSection(
      String stockistId, List<TileDesign> designs) {
    final stockist = _stockistById(stockistId);
    final stockistName = stockist?.name ?? stockistId;
    const color = Color(0xFF1B4F72);
    final sectionBoxes = designs.fold(
        0, (sum, d) => sum + (myChoiceQuantities[d.id] ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.1),
                child: Text(
                  stockistName[0].toUpperCase(),
                  style: const TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 14),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(stockistName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    Text(
                        '${designs.length} design${designs.length == 1 ? '' : 's'} · $sectionBoxes boxes',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: stockist == null
                    ? null
                    : () => _showSendSheet(stockist, designs),
                icon: const Icon(Icons.send_rounded, size: 14),
                label: const Text('Send Order',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                ),
              ),
            ],
          ),
        ),
        ...designs.map((d) => _buildDesignRow(d)),
        Divider(color: Colors.grey.shade200, height: 20),
      ],
    );
  }

  Widget _buildDesignRow(TileDesign d) {
    final qty = myChoiceQuantities[d.id] ?? d.boxQuantity;
    const color = Color(0xFF1B4F72);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4)
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: d.faceImageUrls.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(
                        d.faceImageUrls.first, width: 300),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.image_not_supported,
                            size: 24)),
                  )
                : Container(
                    width: 64,
                    height: 64,
                    color: Colors.grey.shade100,
                    child: Icon(Icons.add_photo_alternate_outlined,
                        size: 24, color: Colors.grey.shade400),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                    '${d.size.replaceAll(' mm', '')} · ${d.surfaceType} · ${d.quality}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => setState(() => removeMyChoice(d.id)),
                  child: Text('Remove',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.red.shade400,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('Qty (boxes)',
                  style:
                      TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _qtyBtn(Icons.remove, color, () {
                    if (qty > 1) {
                      setState(() => setMyChoiceQty(d.id, qty - 1));
                    }
                  }),
                  // Tap the number to type a quantity directly — far quicker
                  // than the steppers for large box counts.
                  GestureDetector(
                    onTap: () => _editQty(d, qty),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 44),
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: color.withValues(alpha: 0.3)),
                      ),
                      child: Text('$qty',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                  ),
                  _qtyBtn(Icons.add, color, () {
                    setState(() => setMyChoiceQty(d.id, qty + 1));
                  }),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Manual quantity entry — tapping the number opens this so a buyer can type a
  // large box count directly instead of holding the +/- steppers.
  Future<void> _editQty(TileDesign d, int current) async {
    // TextFormField (not a manual TextEditingController) so the field owns and
    // disposes its own controller — disposing one by hand here crashed during
    // the dialog's close animation ('_dependents.isEmpty' assertion).
    int? entered = current;
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quantity (boxes)'),
        content: TextFormField(
          initialValue: '$current',
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Enter boxes',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => entered = int.tryParse(v.trim()),
          onFieldSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, entered),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value != null && value > 0) {
      setState(() => setMyChoiceQty(d.id, value));
    }
  }

  Widget _qtyBtn(IconData icon, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border:
                Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, size: 14, color: color),
        ),
      );

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bookmark_outline_rounded,
              size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text('No choices yet',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          Text(
            'Tap the bookmark icon on any tile design\nto add it to your choices.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.grid_view_rounded, size: 18),
            label: const Text('Browse Designs'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4F72),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );
  }
}
