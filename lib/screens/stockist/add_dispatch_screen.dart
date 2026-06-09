import 'package:flutter/material.dart';
import '../../services/stock_service.dart';
import '../../services/supabase_data_service.dart';
import '../../models/tile_design.dart';
import '../../models/choice_state.dart';

class AddDispatchScreen extends StatefulWidget {
  /// Optional design to pre-select (e.g. from the Inquiry tab's Dispatch button).
  final String? initialDesignId;
  const AddDispatchScreen({super.key, this.initialDesignId});
  @override
  State<AddDispatchScreen> createState() => _State();
}

class _State extends State<AddDispatchScreen> {
  final _stockSvc = StockService();
  final _dataSvc  = SupabaseDataService();
  final _formKey  = GlobalKey<FormState>();
  final _qtyCtrl   = TextEditingController();
  final _buyerCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  List<TileDesign> _designs = [];
  TileDesign? _selected;
  bool _loading = false;

  // Buyers who bookmarked the selected design (company, contact, phone, boxes).
  List<Map<String, dynamic>> _buyers = [];
  bool _loadingBuyers = false;

  // When the stockist picks a buyer from the list, remember who — so a
  // successful dispatch can reduce/clear that buyer's inquiry (My Choice).
  String? _pickedBuyerId;
  String _pickedBuyerName = '';

  @override
  void initState() {
    super.initState();
    _qtyCtrl.addListener(() => setState(() {})); // live "remaining" preview
    _loadDesigns();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _buyerCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDesigns() async {
    final all = await _dataSvc.getDesignsByStockist(currentStockistUUID);
    final inStock = all.where((d) => d.boxQuantity > 0).toList();
    final pre = widget.initialDesignId == null
        ? <TileDesign>[]
        : inStock.where((d) => d.id == widget.initialDesignId).toList();
    setState(() {
      _designs = inStock;
      _selected = pre.isEmpty ? null : pre.first;
    });
    if (_selected != null) _loadBuyers(_selected!.id);
  }

  // Loads the buyer list for a design so the stockist can pick who they're
  // dispatching to (tapping a buyer fills the name + their wanted quantity).
  Future<void> _loadBuyers(String designId) async {
    setState(() {
      _loadingBuyers = true;
      _buyers = [];
    });
    final buyers = await _dataSvc.getDesignBuyers(designId);
    if (!mounted) return;
    setState(() {
      _buyers = buyers;
      _loadingBuyers = false;
    });
  }

  void _onDesignChanged(TileDesign? d) {
    setState(() {
      _selected = d;
      _buyerCtrl.clear();
      _qtyCtrl.clear();
      _pickedBuyerId = null;
      _pickedBuyerName = '';
    });
    if (d != null) _loadBuyers(d.id);
  }

  // Fills buyer name + quantity from a tapped buyer row, capping the quantity
  // at the available stock so the form stays valid. Remembers the buyer id so
  // the dispatch can clear their inquiry afterwards.
  void _pickBuyer(Map<String, dynamic> b) {
    final wanted = (b['boxes'] as num?)?.toInt() ?? 0;
    final available = _selected?.boxQuantity ?? 0;
    final company = (b['company'] ?? '').toString();
    setState(() {
      _buyerCtrl.text = company;
      _qtyCtrl.text = '${wanted > available ? available : wanted}';
      _pickedBuyerId = (b['end_user_id'] ?? '').toString();
      _pickedBuyerName = company;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selected == null) return;

    final qty = int.parse(_qtyCtrl.text);
    if (qty > _selected!.boxQuantity) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Only ${_selected!.boxQuantity} boxes available!'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() => _loading = true);

    final ok = await _stockSvc.dispatchStock(
      designId:     _selected!.id,
      stockistUUID: currentStockistUUID,
      quantity:     qty,
      buyerName:    _buyerCtrl.text.trim(),
      notes:        _notesCtrl.text.trim(),
    );

    // If this dispatch was for a buyer picked from the inquiry list (and the
    // name wasn't changed afterwards), reduce/clear that buyer's inquiry.
    if (ok &&
        _pickedBuyerId != null &&
        _pickedBuyerId!.isNotEmpty &&
        _buyerCtrl.text.trim() == _pickedBuyerName) {
      await _dataSvc.fulfillChoice(_selected!.id, _pickedBuyerId!, qty);
      // Notify the buyer their order was dispatched.
      await _dataSvc.notifyDispatch(_selected!.id, _pickedBuyerId!, qty);
    }

    setState(() => _loading = false);
    if (!mounted) return;

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dispatch recorded successfully!'),
        backgroundColor: Colors.green,
      ));
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Dispatch failed. Please try again.'),
        backgroundColor: Colors.red,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Add Dispatch'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<TileDesign>(
              initialValue: _selected,
              decoration: const InputDecoration(
                labelText: 'Select Design',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.grid_view),
              ),
              items: _designs.map((d) => DropdownMenuItem(
                value: d,
                child: Row(
                  children: [
                    Expanded(
                        child: Text(d.name, overflow: TextOverflow.ellipsis)),
                    Text('${d.boxQuantity} boxes',
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              )).toList(),
              onChanged: _onDesignChanged,
              validator: (v) => v == null ? 'Please select a design' : null,
            ),
            const SizedBox(height: 16),

            // Current stock info
            if (_selected != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B4F72).withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFF1B4F72).withValues(alpha: 0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _infoCol('${_selected!.boxQuantity}', 'Current Stock',
                        const Color(0xFF1B4F72), true),
                    _infoCol(_selected!.size, 'Size'),
                    _infoCol(_selected!.surfaceType, 'Surface'),
                  ],
                ),
              ),

            // Buyers interested in this design — tap one to fill name + qty.
            if (_selected != null) _buildBuyersSection(),

            TextFormField(
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Dispatch Quantity (boxes)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.remove_circle_outline),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = int.tryParse(v);
                if (n == null || n <= 0) return 'Enter valid quantity';
                if (_selected != null && n > _selected!.boxQuantity) {
                  return 'Only ${_selected!.boxQuantity} boxes in stock';
                }
                return null;
              },
            ),
            _buildRemainingHint(),
            const SizedBox(height: 16),

            TextFormField(
              controller: _buyerCtrl,
              decoration: const InputDecoration(
                labelText: 'Buyer / Company Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.business_outlined),
              ),
              validator: (v) => v!.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _notesCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.notes_outlined),
              ),
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _submit,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_outlined),
                label: const Text('Record Dispatch',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[700],
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Buyer-interest list for the selected design. Each row is tappable and
  // fills the buyer name + their wanted quantity into the form.
  Widget _buildBuyersSection() {
    if (_loadingBuyers) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_buyers.isEmpty) return const SizedBox.shrink();

    final selectedName = _buyerCtrl.text.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF6A1B9A).withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF6A1B9A).withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.people_alt_outlined,
                  size: 16, color: Color(0xFF6A1B9A)),
              const SizedBox(width: 6),
              Text('Interested buyers (${_buyers.length})',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF6A1B9A))),
              const Spacer(),
              const Text('Tap to fill',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 8),
          ..._buyers.map((b) {
            final company = (b['company'] ?? '').toString();
            final contact = (b['contact'] ?? '').toString();
            final phone = (b['phone'] ?? '').toString();
            final boxes = (b['boxes'] as num?)?.toInt() ?? 0;
            final sub =
                [contact, phone].where((x) => x.isNotEmpty).join('  ·  ');
            final isPicked = company == selectedName && selectedName.isNotEmpty;
            return InkWell(
              onTap: () => _pickBuyer(b),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isPicked
                      ? const Color(0xFF6A1B9A).withValues(alpha: 0.12)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isPicked
                          ? const Color(0xFF6A1B9A)
                          : Colors.grey.shade200,
                      width: isPicked ? 1.5 : 1),
                ),
                child: Row(
                  children: [
                    if (isPicked)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.check_circle,
                            size: 16, color: Color(0xFF6A1B9A)),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(company,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13),
                              overflow: TextOverflow.ellipsis),
                          if (sub.isNotEmpty)
                            Text(sub,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1565C0).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('$boxes boxes',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1565C0))),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // Live "remaining after dispatch" preview under the quantity field.
  Widget _buildRemainingHint() {
    if (_selected == null) return const SizedBox.shrink();
    final n = int.tryParse(_qtyCtrl.text);
    if (n == null || n <= 0) return const SizedBox.shrink();
    final available = _selected!.boxQuantity;
    if (n > available) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, left: 4),
        child: Text('Exceeds stock — only $available boxes available',
            style: TextStyle(
                fontSize: 12,
                color: Colors.red.shade700,
                fontWeight: FontWeight.w600)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Text('After dispatch: ${available - n} boxes left',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
    );
  }

  Widget _infoCol(String value, String label,
      [Color color = Colors.black87, bool large = false]) =>
      Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: large ? 22 : 14,
                  fontWeight: FontWeight.bold,
                  color: color)),
          Text(label,
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      );
}
