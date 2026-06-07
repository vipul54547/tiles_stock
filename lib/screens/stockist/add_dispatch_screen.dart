import 'package:flutter/material.dart';
import '../../services/stock_service.dart';
import '../../services/supabase_data_service.dart';
import '../../models/tile_design.dart';
import '../../models/choice_state.dart';

class AddDispatchScreen extends StatefulWidget {
  const AddDispatchScreen({super.key});
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

  @override
  void initState() {
    super.initState();
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
    setState(() => _designs = all.where((d) => d.boxQuantity > 0).toList());
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
              onChanged: (v) => setState(() => _selected = v),
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
                return null;
              },
            ),
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
