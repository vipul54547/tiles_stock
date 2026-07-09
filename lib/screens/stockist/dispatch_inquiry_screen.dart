import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../widgets/save_bar.dart';
import '../../widgets/unsaved_changes.dart';
import 'stockist_add_order_screen.dart' show DesignPicker;

/// Dispatch a locked order by token: every line shows buyer-ordered vs your
/// stock, with an editable "Dispatch now" box per line. Dispatch is the final
/// physical truth — the stockist can add/remove designs and ship MORE than the
/// buyer ordered (they bumped the qty, or the stockist clears the last few boxes
/// rather than leave them in the godown) and MORE than current system stock. No
/// block; remaining just floors at 0 so nothing ever goes negative. Submitting
/// reduces stock, logs each dispatch, and moves the order to Dispatching /
/// Completed.
class DispatchInquiryScreen extends StatefulWidget {
  final String inquiryId;
  final String? token;
  final String? company;
  final String? phone;       // buyer phone — to send the dispatch report
  final String? countryCode; // buyer dialling code (e.g. +91)
  /// Chosen up-front by the stockist (no silent default): true = reduce from
  /// stock, false = release holding only.
  final bool? reduceStock;
  const DispatchInquiryScreen(
      {super.key,
      required this.inquiryId,
      this.token,
      this.company,
      this.phone,
      this.countryCode,
      this.reduceStock});
  @override
  State<DispatchInquiryScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

class _Line {
  final String designId, name, size, surface, image;
  final int ordered;            // buyer-requested boxes (reference)
  final int dispatchedAlready;  // already dispatched on earlier rounds
  int available;                // current system stock
  final int held;               // total boxes committed (H) across ALL orders
  final int lineHeld;           // THIS order's held boxes for the design
  final TextEditingController ctrl;
  _Line({
    required this.designId,
    required this.name,
    required this.size,
    required this.surface,
    required this.image,
    required this.ordered,
    required this.dispatchedAlready,
    required this.available,
    this.held = 0,
    this.lineHeld = 0,
    required this.ctrl,
  });
  int get remaining => (ordered - dispatchedAlready).clamp(0, 1 << 30);
  int get dispatchNow => int.tryParse(ctrl.text.trim()) ?? 0;
  // Boxes committed to OTHER orders = total H minus THIS order's own hold.
  int get otherHeld => (held - lineHeld).clamp(0, 1 << 30);
}

class _State extends State<DispatchInquiryScreen> {
  final _data = SupabaseDataService();
  final _lines = <_Line>[];
  String _token = '';
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  // Dispatch mode (asked every dispatch): true = reduce from system stock
  // (P_Stock −= dispatched); false = release the holding only, leaving P_Stock
  // for the stockist to manage in their own software.
  // (project_dispatch_order_redesign · Phase D)
  late bool _reduceStock;

  // What happens to the leftover (ordered − dispatched) after this dispatch:
  // true  = CLOSE the order, release the remaining hold → buyer re-orders the
  //         rest if they still want it.
  // false = KEEP the order open (Part-N), remaining stays reserved → buyer waits.
  // null  = not chosen yet — REQUIRED before dispatch whenever a remaining exists
  //         (no silent default). (project_order_remaining_model)
  bool? _close;

  // Boxes still un-dispatched after the quantities currently entered.
  int get _remainingAfter => _lines.fold(
      0, (s, l) => s + (l.ordered - l.dispatchedAlready - l.dispatchNow).clamp(0, 1 << 30));

  // Dispatch-note metadata (sent to the buyer in the WhatsApp report).
  final _invoiceCtrl = TextEditingController();
  final _vehicleCtrl = TextEditingController();
  final _transporterCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _token = widget.token ?? '';
    _reduceStock = widget.reduceStock ?? true; // caller chooses; default only if absent
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.ctrl.dispose();
    }
    _invoiceCtrl.dispose();
    _vehicleCtrl.dispose();
    _transporterCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    final detail = await _data.getInquiryDetail(widget.inquiryId);
    if (!mounted) return;
    final lines = (detail?['lines'] as List?) ?? const [];
    setState(() {
      _token = (detail?['token'] ?? _token).toString();
      _lines.clear();
      for (final raw in lines) {
        final l = Map<String, dynamic>.from(raw as Map);
        final ordered = (l['quantity'] as num?)?.toInt() ?? 0;
        final dispatched = (l['dispatched_qty'] as num?)?.toInt() ?? 0;
        _lines.add(_Line(
          designId: (l['design_id'] ?? '').toString(),
          name: (l['design_name'] ?? '').toString(),
          size: (l['size'] ?? '').toString(),
          surface: (l['surface'] ?? '').toString(),
          image: (l['image'] ?? '').toString(),
          ordered: ordered,
          dispatchedAlready: dispatched,
          available: (l['available'] as num?)?.toInt() ?? 0,
          held: (l['held'] as num?)?.toInt() ?? 0,
          lineHeld: (l['line_held'] as num?)?.toInt() ?? 0,
          // Default the dispatch qty to 0 — the stockist types what actually
          // ships (prevents accidental full dispatch / over-reduce).
          ctrl: TextEditingController(),
        ));
      }
      _loading = false;
    });
  }

  Future<void> _addDesign() async {
    final all = await _data.getDesignsByStockist(currentStockistUUID);
    final brands = await _data.getMyBrands();
    if (!mounted) return;
    final existing = _lines.map((l) => l.designId).toSet();
    final options = all
        .where((d) => d.boxQuantity > 0 && !existing.contains(d.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No other in-stock designs to add.')));
      return;
    }
    // Full-screen "Select designs" page (same as +Add Order) — pick one or more
    // designs (with a box qty that pre-fills the dispatch amount).
    final result = await Navigator.of(context).push<Map<String, int>>(
      MaterialPageRoute(
        builder: (_) => DesignPicker(
          stock: options,
          brandById: {for (final b in brands) b.id: b.name},
          initial: const {},
        ),
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    setState(() {
      for (final e in result.entries) {
        final matches = options.where((x) => x.id == e.key);
        if (matches.isEmpty) continue;
        final d = matches.first;
        _lines.add(_Line(
          designId: d.id,
          name: d.name,
          size: d.size,
          surface: d.surfaceCardLabel,
          image: d.faceImageUrls.isNotEmpty ? d.faceImageUrls.first : '',
          ordered: 0,
          dispatchedAlready: 0,
          available: d.boxQuantity,
          ctrl: TextEditingController(text: e.value > 0 ? '${e.value}' : ''),
        ));
      }
      _dirty = true;
    });
  }

  Future<void> _submit() async {
    // A leftover exists → the stockist MUST choose Close vs Keep-open first.
    if (_remainingAfter > 0 && _close == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '$_remainingAfter boxes will be left over — choose "Close order" '
              'or "Keep open" first.'),
          backgroundColor: const Color(0xFFE65100)));
      return;
    }
    // Over-stock + booking warnings only matter when we actually reduce system
    // stock; in "release holding only" mode P_Stock is left untouched.
    if (_reduceStock) {
    final over = _lines.where((l) => l.dispatchNow > l.available).toList();
    if (over.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Dispatch more than stock?'),
          content: Text(
              '${over.length} design${over.length == 1 ? '' : 's'} '
              'dispatch more boxes than you have in stock. This is allowed — the '
              'system stock for those will be set to 0. Continue?\n\n'
              '${over.map((l) => '• ${l.name}: ${l.dispatchNow} > ${l.available}').join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Dispatch anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }

    // Booking warning (warn-but-allow): dispatching this much would leave fewer
    // physical boxes than are committed to OTHER buyers' confirmed orders.
    final breaks = _lines
        .where((l) => l.otherHeld > 0 && (l.available - l.dispatchNow) < l.otherHeld)
        .toList();
    if (breaks.isNotEmpty) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Affects reserved orders?'),
          content: Text(
              '${breaks.length} design${breaks.length == 1 ? '' : 's'} '
              'would be left short of boxes already committed to other buyers. '
              'You can still dispatch — those commitments may need rebalancing.\n\n'
              '${breaks.map((l) => '• ${l.name}: ${(l.available - l.dispatchNow).clamp(0, 1 << 30)} left vs ${l.otherHeld} booked').join('\n')}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Dispatch anyway')),
          ],
        ),
      );
      if (ok != true) return;
    }
    } // end _reduceStock warnings

    // Final mode confirmation — a 3-second blinking notice of exactly what this
    // dispatch does to stock, so the wrong mode can't be picked by reflex.
    if (!await _confirmMode()) return;

    final payload = _lines
        .map((l) => {'design_id': l.designId, 'dispatch': l.dispatchNow})
        .toList();
    final totalNow = _lines.fold(0, (s, l) => s + l.dispatchNow);
    final dispatchedLines = _lines.where((l) => l.dispatchNow > 0).toList();

    setState(() => _saving = true);
    try {
      final res = await _data.dispatchInquiry(
        widget.inquiryId, payload,
        invoiceNo: _invoiceCtrl.text.trim(),
        vehicleNo: _vehicleCtrl.text.trim(),
        transporter: _transporterCtrl.text.trim(),
        note: _noteCtrl.text.trim(),
        date: _date,
        reduceStock: _reduceStock,
        // Full dispatch always closes; a partial uses the required choice.
        close: _remainingAfter == 0 ? true : _close!,
      );
      if (!mounted) return;
      _dirty = false;
      final status = (res['status'] ?? '').toString();
      final outstanding = (res['outstanding'] as num?)?.toInt() ?? 0;
      final dispatchNo = (res['dispatch_no'] ?? '').toString();
      if (totalNow > 0) {
        final report = _buildReport(
            dispatchNo, dispatchedLines, totalNow, outstanding, status);
        await _showReportSheet(report, status);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Order updated.'),
            backgroundColor: Color(0xFF2E7D32)));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
    }
  }

  // Final mode confirmation. Shows a 3-second countdown with the consequence in
  // BLINKING text ("Quantity is reduced from Stock" / "Release quantity from
  // Holding") so the stockist can't dispatch the wrong way by reflex. Confirm is
  // disabled until the countdown ends. Returns true to proceed.
  Future<bool> _confirmMode() async {
    final reduce = _reduceStock;
    final msg = reduce
        ? 'Quantity is reduced from Stock'
        : 'Release quantity from Holding';
    final detail = reduce
        ? 'Your system stock will drop by the dispatched boxes.'
        : 'Your system stock is NOT changed — only the held boxes are released. '
            'Update your own stock count afterwards.';
    final color = reduce ? const Color(0xFFC62828) : const Color(0xFF1565C0);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        int countdown = 3;
        bool visible = true;
        Timer? blink;
        Timer? tick;
        return StatefulBuilder(
          builder: (ctx, setD) {
            blink ??= Timer.periodic(const Duration(milliseconds: 450), (_) {
              setD(() => visible = !visible);
            });
            tick ??= Timer.periodic(const Duration(seconds: 1), (t) {
              if (countdown <= 1) {
                t.cancel();
                setD(() => countdown = 0);
              } else {
                setD(() => countdown--);
              }
            });
            void cleanup() {
              blink?.cancel();
              tick?.cancel();
            }

            return AlertDialog(
              title: const Text('Confirm dispatch'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedOpacity(
                    opacity: visible ? 1 : 0.15,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: color),
                      ),
                      child: Text(
                        msg,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: color),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(detail,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade700)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cleanup();
                    Navigator.pop(ctx, false);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: countdown > 0
                      ? null
                      : () {
                          cleanup();
                          Navigator.pop(ctx, true);
                        },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: color, foregroundColor: Colors.white),
                  child: Text(countdown > 0 ? 'Confirm ($countdown)' : 'Confirm'),
                ),
              ],
            );
          },
        );
      },
    );
    return ok == true;
  }

  // Builds the WhatsApp dispatch-report text (no rates, by design).
  String _buildReport(String dispatchNo, List<_Line> lines, int total,
      int outstanding, String status) {
    final b = StringBuffer();
    b.writeln('Dispatch update — Order $_token');
    if (dispatchNo.isNotEmpty) b.writeln('Dispatch No: $dispatchNo');
    b.writeln('Date: ${_fmtDate(_date)}');
    if (_invoiceCtrl.text.trim().isNotEmpty) {
      b.writeln('Invoice No: ${_invoiceCtrl.text.trim()}');
    }
    if (_vehicleCtrl.text.trim().isNotEmpty) {
      b.writeln('Vehicle No: ${_vehicleCtrl.text.trim()}');
    }
    if (_transporterCtrl.text.trim().isNotEmpty) {
      b.writeln('Transporter: ${_transporterCtrl.text.trim()}');
    }
    b.writeln();
    b.writeln('Dispatched now:');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      b.writeln(
          '${i + 1}. ${l.name} (${l.size.replaceAll(' mm', '')}) — ${l.dispatchNow} boxes');
    }
    b.writeln('Total dispatched: $total boxes');
    if (outstanding > 0) {
      // Closed short vs kept open — say what the leftover actually means.
      b.writeln(status == 'completed'
          ? 'Remaining $outstanding boxes: not included — please place a new '
              'order if you still need them.'
          : 'Balance $outstanding boxes: reserved for you, coming in a later '
              'dispatch.');
    }
    if (_noteCtrl.text.trim().isNotEmpty) {
      b.writeln();
      b.writeln('Note: ${_noteCtrl.text.trim()}');
    }
    return b.toString();
  }

  // Post-dispatch: preview the report and let the stockist send it to the buyer.
  Future<void> _showReportSheet(String report, String status) async {
    // WhatsApp only when there's a REAL phone (not just a '+91' country code).
    final hasPhone = (widget.phone ?? '').trim().isNotEmpty;
    final digits = '${widget.countryCode ?? ''}${widget.phone ?? ''}'
        .replaceAll(RegExp(r'[^0-9]'), '');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              Text(
                  status == 'completed'
                      ? 'Order completed'
                      : 'Dispatch recorded',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ]),
            const SizedBox(height: 10),
            const Text('Dispatch report for the buyer:',
                style: TextStyle(fontSize: 12.5)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: SingleChildScrollView(
                child: Text(report,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
              ),
            ),
            const SizedBox(height: 14),
            // Copy is always available (works for web/no-phone orders too); send
            // straight to WhatsApp only when we have the customer's number.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: report));
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Report copied — paste it into your chat.'),
                            backgroundColor: Color(0xFF2E7D32)));
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy report'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13)),
                  ),
                ),
                if (hasPhone) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse(
                            'https://wa.me/$digits?text=${Uri.encodeComponent(report)}');
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.chat_rounded, size: 18),
                      label: const Text('WhatsApp'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF25D366),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
          ],
        ),
      ),
    );
  }

  void _dispatchAllRemaining() {
    setState(() {
      for (final l in _lines) {
        l.ctrl.text = l.remaining > 0 ? '${l.remaining}' : '';
      }
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalNow = _lines.fold(0, (s, l) => s + l.dispatchNow);
    return Scaffold(
      appBar: AppBar(
        title: Text(_token.isEmpty ? 'Dispatch order' : 'Dispatch $_token'),
      ),
      bottomNavigationBar: SaveBar(
        label: 'Record Dispatch ($totalNow boxes)',
        icon: Icons.local_shipping_outlined,
        color: Colors.red[700],
        onPressed: _submit,
        saving: _saving,
        dirty: _dirty || totalNow > 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : UnsavedChangesGuard(
              isDirty: _dirty,
              child: Column(
                children: [
                  if (widget.company != null && widget.company!.isNotEmpty)
                    Container(
                      width: double.infinity,
                      color: _navy.withValues(alpha: 0.05),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('Buyer: ${widget.company}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, color: _navy)),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      children: [
                        _modeSelector(),
                        const SizedBox(height: 12),
                        _closeSelector(),
                        _metaSection(),
                        const SizedBox(height: 12),
                        if (_lines.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: Text('No items on this order',
                                    style: TextStyle(color: Colors.grey))),
                          )
                        else
                          ..._lines.map(_lineCard),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          onPressed: _addDesign,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add a design'),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: _navy,
                              minimumSize: const Size.fromHeight(44)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // How this dispatch affects stock — asked every time. Reduce from Stock (we
  // manage stock) vs Release Holding only (stockist manages stock elsewhere).
  Widget _modeSelector() {
    final color = _reduceStock ? const Color(0xFFC62828) : const Color(0xFF1565C0);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('How does this dispatch affect your stock?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle:
                    WidgetStateProperty.all(const TextStyle(fontSize: 11.5)),
              ),
              segments: const [
                ButtonSegment(
                    value: true,
                    label: Text('Reduce from Stock'),
                    icon: Icon(Icons.inventory_2_outlined, size: 15)),
                ButtonSegment(
                    value: false,
                    label: Text('Release Holding only'),
                    icon: Icon(Icons.lock_open_outlined, size: 15)),
              ],
              selected: {_reduceStock},
              onSelectionChanged: (s) => setState(() => _reduceStock = s.first),
            ),
            const SizedBox(height: 6),
            Text(
              _reduceStock
                  ? 'Your system stock drops by the dispatched boxes.'
                  : 'Your system stock is NOT changed — only the held boxes are '
                      'released. Update your own count afterwards.',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }

  // When this dispatch leaves a remaining, the stockist MUST decide its fate:
  // close the order (release the rest) or keep it open (hold the rest, Part-N).
  // Prominent, unselected by default (required), hidden only on a full dispatch.
  Widget _closeSelector() {
    final rem = _remainingAfter;
    if (rem <= 0) return const SizedBox.shrink();
    final chosen = _close != null;
    // Amber while undecided, then green (close) / deep-orange (keep).
    final accent = !chosen
        ? const Color(0xFFE65100)
        : (_close! ? const Color(0xFF2E7D32) : const Color(0xFFE65100));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent, width: chosen ? 1 : 2),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_outlined, size: 18, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('$rem box${rem == 1 ? '' : 'es'} will be left over',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: accent)),
                ),
                if (!chosen)
                  Text('Choose one',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: accent)),
              ],
            ),
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              showSelectedIcon: true,
              emptySelectionAllowed: true,
              style: ButtonStyle(
                textStyle:
                    WidgetStateProperty.all(const TextStyle(fontSize: 12.5)),
                padding: WidgetStateProperty.all(
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 8)),
              ),
              segments: const [
                ButtonSegment(
                    value: true,
                    label: Text('Close order'),
                    icon: Icon(Icons.check_circle_outline, size: 16)),
                ButtonSegment(
                    value: false,
                    label: Text('Keep open'),
                    icon: Icon(Icons.pending_outlined, size: 16)),
              ],
              selected: chosen ? {_close!} : <bool>{},
              onSelectionChanged: (s) =>
                  setState(() => _close = s.isEmpty ? null : s.first),
            ),
            const SizedBox(height: 8),
            Text(
              !chosen
                  ? 'Pick what happens to the $rem left-over boxes before you record the dispatch.'
                  : (_close!
                      ? 'Order CLOSES. The $rem are released back to stock — the buyer re-orders them if still needed.'
                      : 'Order STAYS OPEN (Part-N). The $rem stay reserved for this buyer — dispatch them later on this same order.'),
              style: TextStyle(fontSize: 11.5, color: accent),
            ),
          ],
        ),
      ),
    );
  }

  // Dispatch-note details (Invoice / Vehicle / Date / Transporter / Note) +
  // a one-tap "All remaining" that fills every line's Send box.
  Widget _metaSection() {
    InputDecoration dec(String label) => InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Dispatch details',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const Spacer(),
              TextButton.icon(
                onPressed: _lines.isEmpty ? null : _dispatchAllRemaining,
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('All remaining',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _invoiceCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Invoice No'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _vehicleCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Vehicle / Truck No'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2025),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (d != null) setState(() { _date = d; _dirty = true; });
                  },
                  icon: const Icon(Icons.event, size: 16),
                  label: Text('Date: ${_fmtDate(_date)}',
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _navy,
                      minimumSize: const Size.fromHeight(44)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _transporterCtrl,
                  onChanged: (_) => _markDirty(),
                  decoration: dec('Transporter (optional)'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _noteCtrl,
              onChanged: (_) => _markDirty(),
              maxLines: 2,
              decoration: dec('Note (optional)'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(_Line l) {
    final over = l.dispatchNow > l.available;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: l.image.isEmpty
                  ? Container(
                      width: 56, height: 56,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.image_not_supported,
                          size: 22, color: Colors.grey))
                  : CachedNetworkImage(
                      imageUrl: CloudinaryService.thumbUrl(l.image, width: 200),
                      width: 56, height: 56, fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: Colors.grey.shade200),
                      errorWidget: (_, __, ___) =>
                          Container(color: Colors.grey.shade200)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  // 'None' is never a surface — in-name brands keep it in the
                  // design name. (project_per_brand_surface_mode)
                  Text(
                      [
                        l.size.replaceAll(' mm', ''),
                        if (l.surface.trim().isNotEmpty &&
                            l.surface.trim().toLowerCase() != 'none')
                          l.surface.trim(),
                      ].join(' · '),
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 2, children: [
                    if (l.ordered > 0)
                      _meta('Ordered ${l.ordered}', _navy),
                    if (l.dispatchedAlready > 0)
                      _meta('Done ${l.dispatchedAlready}', const Color(0xFFE65100)),
                    _meta('Stock ${l.available}',
                        over ? Colors.red.shade700 : Colors.green.shade700),
                    if (l.otherHeld > 0)
                      _meta('Booked ${l.otherHeld}', const Color(0xFF1565C0)),
                  ]),
                  if (over)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          'More than your stock — allowed, stock will become 0.',
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.red.shade700)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: l.ctrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onChanged: (_) {
                      _markDirty();
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      labelText: 'Send',
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: Colors.red.shade400),
                  tooltip: 'Remove from this dispatch',
                  onPressed: () => setState(() {
                    l.ctrl.dispose();
                    _lines.remove(l);
                    _dirty = true;
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4)),
        child: Text(t,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: c)),
      );
}
