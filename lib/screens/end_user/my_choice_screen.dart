import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tile_design.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../models/choice_state.dart';
import '../../models/inquiry_order.dart';
import '../../utils/guest_gate.dart';
import '../../utils/my_choice.dart';
import '../../utils/order_message.dart';

class MyChoiceScreen extends StatefulWidget {
  const MyChoiceScreen({super.key});
  @override
  State<MyChoiceScreen> createState() => _MyChoiceScreenState();
}

class _MyChoiceScreenState extends State<MyChoiceScreen> {
  final SupabaseDataService _service = SupabaseDataService();
  List<TileDesign> _allDesigns = [];
  List<Stockist> _allStockists = [];
  List<InquiryOrder> _orders = []; // one tokenised order per stockist
  bool _loading = true;
  String? _filterStockistId;

  /// designId → what the basket asks for vs what is FREE right now
  /// (`wanted`, `available`, `status` = ok | reduced | out).
  ///
  /// A basket can sit for weeks and the stock moves underneath it. Two traps this
  /// closes: (1) the buyer sends an inquiry for boxes that are no longer there;
  /// (2) a design whose free stock hit ZERO drops out of `market_designs`
  /// altogether, so its row vanished from this screen — while `my_choices` still
  /// held it and `send_order_to_stockist` still sent it. Reading availability
  /// straight from `designs` keeps those lines visible and honest.
  /// (docs/BUYER_ORDER_AVAILABILITY_PLAN.md)
  Map<String, Map<String, dynamic>> _avail = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _service.getAllDesigns(),
      _service.getMarketStockists(),
      _service.getMyPrivateDesigns(),
    ]);
    await loadMyChoices(); // restore saved selections
    final orders = await _service.getMyOrders();
    final avail = await _service.choicesAvailability();
    if (!mounted) return;
    // Choices can be saved from PRIVATE (My-Suppliers) stock too, so the design
    // pool must include private (claimed) designs — getAllDesigns() is the public
    // market only (empty when the public market is off), which otherwise hides
    // those choices entirely.
    final seen = <String>{};
    final combined = <TileDesign>[];
    for (final d in [
      ...(results[0] as List<TileDesign>),
      ...(results[2] as List<TileDesign>),
    ]) {
      if (seen.add(d.id)) combined.add(d);
    }
    setState(() {
      _allDesigns = combined;
      _allStockists = results[1] as List<Stockist>;
      _orders = orders;
      _avail = {for (final r in avail) (r['design_id'] ?? '').toString(): r};
      _loading = false;
    });
  }

  int _availableOf(String designId) =>
      (_avail[designId]?['available'] as num?)?.toInt() ?? 0;

  /// Basket lines whose design is no longer in the browsable pool — free stock
  /// ran to 0, so it is gone from `market_designs`. Without this they would be
  /// invisible here yet still ride along on Send.
  List<Map<String, dynamic>> get _orphanRows {
    final known = _allDesigns.map((d) => d.id).toSet();
    return _avail.values
        .where((r) =>
            myChoiceQuantities.containsKey((r['design_id'] ?? '').toString()) &&
            !known.contains((r['design_id'] ?? '').toString()))
        .toList();
  }

  List<Map<String, dynamic>> _orphansFor(String stockistKey) => _orphanRows
      .where((r) => (r['stockist_key'] ?? '').toString() == stockistKey)
      .toList();

  /// "You want 50 · Only 20 left" — the whole warning in one line.
  Widget _shortBadge(int wanted, int available) {
    final out = available <= 0;
    final c = out ? Colors.red.shade700 : Colors.orange.shade800;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(
        out
            ? 'You want $wanted · out of stock'
            : 'You want $wanted · only $available left',
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: c),
      ),
    );
  }

  /// Re-check the basket against live stock and, if any line no longer fits, put
  /// the plain facts in front of the buyer BEFORE the order goes out.
  /// Returns true = go ahead and send.
  ///
  /// Deliberately does NOT decide for them (user, 2026-07-11 — this replaced an
  /// earlier "Use available / Remove / Adjust all" sheet). It shows three numbers
  /// per line — what you chose, what is free, and a box holding your number — and
  /// lets the buyer type whatever they want. Pre-filled with their existing
  /// quantity, so a line they are happy with needs no typing at all and the box
  /// is never ambiguously blank. **0 = remove the line.**
  ///
  /// Asking for MORE than is free stays allowed: an inquiry is a request, not a
  /// reservation, and the supplier confirms what they can give. So over-asking
  /// costs exactly one warning, not a wall.
  /// (docs/BUYER_ORDER_AVAILABILITY_PLAN.md)
  Future<bool> _reviewAvailability(Stockist stockist) async {
    final rows = await _service.choicesAvailability(stockistKey: stockist.id);
    if (!mounted) return false;
    // Refresh what the screen shows either way — the numbers just came back.
    setState(() {
      for (final r in rows) {
        _avail[(r['design_id'] ?? '').toString()] = r;
      }
    });

    // Only lines whose number no longer fits. Everything else is left alone and
    // the buyer never sees this sheet at all.
    final problems = rows.where((r) {
      final id = (r['design_id'] ?? '').toString();
      if (!myChoiceQuantities.containsKey(id)) return false;
      final want = myChoiceQuantities[id] ?? 0;
      final avail = (r['available'] as num?)?.toInt() ?? 0;
      return want > avail;
    }).toList();
    if (problems.isEmpty) return true; // nothing changed — send straight through

    final ctrls = <String, TextEditingController>{
      for (final r in problems)
        (r['design_id'] ?? '').toString(): TextEditingController(
            text: '${myChoiceQuantities[(r['design_id'] ?? '').toString()] ?? 0}'),
    };

    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Stock has changed',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                const SizedBox(height: 6),
                Text(
                    'These designs have less stock now than when you chose them. '
                    'Set the quantity you want. Enter 0 to remove a line.',
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final r in problems)
                          _reviewLine(r, ctrls[(r['design_id'] ?? '').toString()]!),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13)),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _applyAndSend(ctx, ctrls),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text('Send choice'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );

    for (final c in ctrls.values) {
      c.dispose();
    }
    return go == true;
  }

  /// Write the buyer's numbers back to the basket, then — only if something is
  /// still above what the supplier has free — ask once. Their call either way.
  Future<void> _applyAndSend(
      BuildContext sheetCtx, Map<String, TextEditingController> ctrls) async {
    var over = 0;
    ctrls.forEach((id, c) {
      final v = int.tryParse(c.text.trim()) ?? 0;
      setMyChoiceQty(id, v); // 0 removes the line
      if (v <= 0) {
        _avail.remove(id);
      } else if (v > _availableOf(id)) {
        over++;
      }
    });
    setState(() {}); // the basket behind the sheet now shows the new numbers

    if (over > 0) {
      final ok = await showDialog<bool>(
        context: sheetCtx,
        builder: (dctx) => AlertDialog(
          title: const Text('More than available'),
          content: Text(
              '$over line${over == 1 ? '' : 's'} ask for more boxes than the '
              'supplier has free right now.\n\n'
              'You can still send it — they will confirm what they can give.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('Send anyway')),
          ],
        ),
      );
      if (ok != true) return; // stay on the sheet so they can change the numbers
    }
    if (sheetCtx.mounted) Navigator.pop(sheetCtx, true);
  }

  /// One line that no longer fits: the two numbers, and a box holding THEIR
  /// number — pre-filled, so a line they are happy with needs no typing.
  Widget _reviewLine(Map<String, dynamic> r, TextEditingController ctrl) {
    final avail = (r['available'] as num?)?.toInt() ?? 0;
    final chose = myChoiceQuantities[(r['design_id'] ?? '').toString()] ?? 0;
    final sub = [
      (r['size'] ?? '').toString().replaceAll(' mm', ''),
      (r['surface_label'] ?? '').toString(),
      (r['quality'] ?? '').toString(),
    ].where((x) => x.isNotEmpty && x.toLowerCase() != 'none').join(' · ');

    Widget figure(String label, String value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            Text(value,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: color ?? Colors.black87)),
          ],
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((r['name'] ?? '').toString(),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (sub.isNotEmpty)
            Text(sub, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              figure('You chose', '$chose'),
              const SizedBox(width: 22),
              figure('Available', '$avail',
                  color: avail == 0 ? Colors.grey : Colors.black87),
              const Spacer(),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'Qty',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // The order (token) for a stockist group. Designs are grouped by the stockist
  // display key (sequential id / masked code), which is the order's stockist_key.
  InquiryOrder? _orderFor(String stockistDisplayId) {
    for (final o in _orders) {
      if (o.stockistKey == stockistDisplayId) return o;
    }
    return null;
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDateTime(DateTime d) {
    final l = d.toLocal();
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final m = l.minute.toString().padLeft(2, '0');
    final ap = l.hour < 12 ? 'AM' : 'PM';
    return '${l.day} ${_months[l.month - 1]} ${l.year}, $h:$m $ap';
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
    final order = designs.isEmpty ? null : _orderFor(designs.first.stockistId);
    return buildOrderMessage([
      for (final d in designs)
        (
          name: d.name,
          size: d.size,
          surface: d.surfaceType,
          quality: d.quality,
          qty: myChoiceQuantities[d.id] ?? d.boxQuantity,
        ),
    ], orderNo: order?.token, connectionCode: order?.connectionCode);
  }

  Future<void> _showSendSheet(
      Stockist stockist, List<TileDesign> designs) async {
    if (blockIfGuest(context, feature: 'Placing orders')) return;

    // The basket may have sat here for weeks while the supplier's stock moved.
    // send_order_to_stockist copies it into the order with no stock check, so
    // this is the last place to catch it. Back = stay on the basket, unchanged.
    if (!await _reviewAvailability(stockist)) return;
    if (!mounted) return;

    // The review can trim or drop lines, so rebuild from what is in the basket
    // NOW — not from the list this was called with.
    final live =
        designs.where((d) => myChoiceQuantities.containsKey(d.id)).toList();
    if (live.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing left to send for this supplier.')));
      return;
    }
    designs = live;

    final message = _buildMessage(stockist, designs);
    if (!mounted) return;
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
            const SizedBox(height: 12),
            // Profile-score note: encourages serious inquiries.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFE082)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Please inquire seriously. We compare your inquiries with '
                      'how many boxes are actually dispatched, and that affects '
                      'your profile score.',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  // Send it as an ORDER (server-side, robust): freezes the lines,
                  // marks it sent (notifies the stockist), and clears these
                  // designs out of My Choice — independent of WhatsApp. The order
                  // now lives in My Orders.
                  try {
                    await _service.sendOrderToStockist(stockist.id);
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('$e'), backgroundColor: Colors.red));
                    }
                    return;
                  }
                  if (mounted) _load();
                  // WhatsApp needs the full international number (country code +
                  // phone), digits only — no '+'.
                  final phone = '${stockist.countryCode}${stockist.phone}'
                      .replaceAll(RegExp(r'[^0-9]'), '');
                  final uri = Uri.parse(
                      'https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
                  final ok = await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? 'Order sent — track it in My Orders.'
                            : 'Order sent — couldn\'t open WhatsApp; message the supplier manually. Track it in My Orders.'),
                        backgroundColor: const Color(0xFF2E7D32)));
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
          // Dispatch history moved to the ⋮ account menu as "My Dispatch".
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
    // Sold-out lines are no longer in the browsable pool, so they have no
    // TileDesign and would otherwise render nowhere — while still being sent.
    // Fold their stockists back in so every basket line has a home.
    final orphanKeys =
        _orphanRows.map((r) => (r['stockist_key'] ?? '').toString()).toSet();
    for (final k in orphanKeys) {
      if (!allStockistIds.contains(k)) allStockistIds.add(k);
    }
    final visibleIds = <String>{
      ...grouped.keys,
      ...orphanKeys.where(
          (k) => _filterStockistId == null || k == _filterStockistId),
    }.toList();

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
                      visibleIds[i], grouped[visibleIds[i]] ?? const []),
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
    final orphans = _orphansFor(stockistId);
    final sectionBoxes = designs.fold(
        0, (sum, d) => sum + (myChoiceQuantities[d.id] ?? 0));
    final lineCount = designs.length + orphans.length;
    final order = _orderFor(stockistId);
    final editable = order?.buyerEditable ?? true;

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
                        '$lineCount design${lineCount == 1 ? '' : 's'} · $sectionBoxes boxes',
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
        // My Choice is now a pure pre-send basket (sent orders leave for My
        // Orders), so only ever holds drafts — no order strip needed here.
        if (order != null && !order.isDraft) _buildOrderStrip(order),
        ...designs.map((d) => _buildDesignRow(d, editable)),
        ...orphans.map(_buildSoldOutRow),
        Divider(color: Colors.grey.shade200, height: 20),
      ],
    );
  }

  /// A basket line whose stock ran out while it sat here. It is NOT in the
  /// browsable pool any more, so there is no TileDesign to render — but it is
  /// still in `my_choices`, and Send would still carry it to the supplier. Show
  /// it, plainly, with a way out.
  Widget _buildSoldOutRow(Map<String, dynamic> r) {
    final id = (r['design_id'] ?? '').toString();
    final name = (r['name'] ?? '').toString();
    final img = (r['image_url'] ?? '').toString();
    final surface = (r['surface_label'] ?? r['surface_type'] ?? '').toString();
    final sub = [
      (r['size'] ?? '').toString().replaceAll(' mm', ''),
      if (surface.isNotEmpty && surface.toLowerCase() != 'none') surface,
      (r['quality'] ?? '').toString(),
    ].where((x) => x.isNotEmpty).join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 64,
              height: 64,
              child: img.isEmpty
                  ? Container(
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported, size: 24))
                  : ColorFiltered(
                      colorFilter: const ColorFilter.matrix(<double>[
                        0.2126, 0.7152, 0.0722, 0, 0,
                        0.2126, 0.7152, 0.0722, 0, 0,
                        0.2126, 0.7152, 0.0722, 0, 0,
                        0, 0, 0, 1, 0,
                      ]),
                      child: CachedNetworkImage(
                        imageUrl: CloudinaryService.thumbUrl(img, width: 300),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade200),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade200),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(sub,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.remove_shopping_cart_outlined,
                        size: 13, color: Colors.red.shade700),
                    const SizedBox(width: 4),
                    Text('Out of stock now',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.red.shade700)),
                  ],
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => setState(() {
                    removeMyChoice(id);
                    _avail.remove(id);
                  }),
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
          Text('${r['wanted'] ?? 0}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade500,
                  decoration: TextDecoration.lineThrough)),
        ],
      ),
    );
  }

  // Token + lifecycle status + Generated/Modified times for a stockist's order.
  // Read-only: the buyer "sends" the inquiry via WhatsApp; the supplier confirms.
  Widget _buildOrderStrip(InquiryOrder o) {
    final (Color fg, Color bg) = switch (o.status) {
      'sent'        => (const Color(0xFF1565C0), const Color(0xFFE3F2FD)),
      'locked'      => (const Color(0xFF6A1B9A), const Color(0xFFF3E5F5)),
      'dispatching' => (const Color(0xFFE65100), const Color(0xFFFFF3E0)),
      'completed'   => (const Color(0xFF2E7D32), const Color(0xFFE8F5E9)),
      'rejected'    => (Colors.red.shade700, const Color(0xFFFFEBEE)),
      _             => (Colors.grey.shade700, const Color(0xFFF5F5F5)),
    };
    final modified = o.updatedAt.difference(o.createdAt).inSeconds.abs() > 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 15, color: Color(0xFF1B4F72)),
              const SizedBox(width: 6),
              Text(o.token,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: bg, borderRadius: BorderRadius.circular(20)),
                child: Text(o.statusLabel,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: fg)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Generated: ${_fmtDateTime(o.createdAt)}'
            '${modified ? '   ·   Modified: ${_fmtDateTime(o.updatedAt)}' : ''}',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
          ),
          if (!o.buyerEditable)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                o.isLocked || o.isDispatching
                    ? 'Confirmed by the supplier — this order can no longer be changed.'
                    : 'This order is ${o.statusLabel.toLowerCase()}.',
                style: TextStyle(
                    fontSize: 10.5,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey.shade600),
              ),
            ),
          // Once the supplier starts shipping, let the buyer see what went out.
          if (o.isDispatching || o.isCompleted)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    context.push('/my-dispatches?token=${o.token}'),
                icon: const Icon(Icons.local_shipping_outlined, size: 15),
                label: const Text('View dispatches',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1B4F72),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDesignRow(TileDesign d, [bool editable = true]) {
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
                    [
                      d.size.replaceAll(' mm', ''),
                      if (d.hasSurface) d.surfaceCardLabel,
                      d.quality,
                    ].join(' · '),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
                // The supplier's stock moves while the basket sits here. Say so
                // on the line itself — a surprise at Send is worse than a warning
                // now. Silent when there is enough (the common case).
                //
                // Compare the LIVE quantity against what is free. Never the
                // status the server stamped on the row: the moment the buyer
                // trims the line (or "Adjust all" does), that snapshot is stale
                // and the badge would keep crying "only 85 left" at a line now
                // asking for exactly 85.
                if (_avail.containsKey(d.id) && qty > _availableOf(d.id)) ...[
                  const SizedBox(height: 5),
                  _shortBadge(qty, _availableOf(d.id)),
                ],
                const SizedBox(height: 4),
                if (editable)
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
              if (!editable)
                Container(
                  constraints: const BoxConstraints(minWidth: 44),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color.withValues(alpha: 0.2)),
                  ),
                  child: Text('$qty',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                )
              else
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
