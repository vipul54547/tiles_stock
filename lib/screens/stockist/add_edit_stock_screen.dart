import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AddEditStockScreen extends StatefulWidget {
  final String? designId;
  const AddEditStockScreen({super.key, this.designId});
  @override State<AddEditStockScreen> createState() => _State();
}

class _State extends State<AddEditStockScreen> {
  final _formKey = GlobalKey<FormState>();
  bool get isEdit => widget.designId != null;
  final _nameCtrl = TextEditingController();
  final _sizeCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _piecesCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _thicknessCtrl = TextEditingController();
  final _colourCtrl = TextEditingController();
  String _surface = 'Matt';
  final _surfaces = ['Matt', 'Glossy', 'Satin', 'Rustic', 'Polished', 'Lappato'];
  String _quality = 'Premium';
  final _qualities = ['Premium', 'Standard'];
  String _stockType = 'Regular';
  final _stockTypes = ['Regular', 'One Time'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(isEdit ? 'Edit Stock' : 'Add New Stock'),
      ),


      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate_outlined, size: 48, color: Colors.grey),
                  const SizedBox(height: 8),
                  const Text('Add Design Face Images'),
                  TextButton(onPressed: () {}, child: const Text('Upload Images')),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _field(_nameCtrl, 'Design Name', required: true),
            _field(_sizeCtrl, 'Tile Size (e.g. 600x600 mm)', required: true),
            DropdownButtonFormField<String>(
              initialValue: _surface,
              decoration: const InputDecoration(labelText: 'Surface Type', border: OutlineInputBorder()),
              items: _surfaces.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => setState(() => _surface = v!),
            ),
            const SizedBox(height: 16),
            const Text('Quality', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              children: _qualities.map((q) {
                final selected = _quality == q;
                final Color bg;
                final Color fg;
                final IconData icon;
                switch (q) {
                  case 'Premium':
                    bg = const Color(0xFFFFF8E1); fg = const Color(0xFFF9A825); icon = Icons.star_rounded;
                    break;
                  case 'Both':
                    bg = const Color(0xFFE8F5E9); fg = const Color(0xFF2E7D32); icon = Icons.layers_outlined;
                    break;
                  default:
                    bg = const Color(0xFFE3F2FD); fg = const Color(0xFF1565C0); icon = Icons.verified_outlined;
                }
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _quality = q),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: selected ? fg : bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: fg,
                          width: selected ? 2 : 1,
                        ),
                        boxShadow: selected
                            ? [BoxShadow(color: fg.withValues(alpha: 0.25), blurRadius: 6, offset: const Offset(0, 2))]
                            : [],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 22, color: selected ? Colors.white : fg),
                          const SizedBox(height: 6),
                          Text(
                            q,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: selected ? Colors.white : fg,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            const Text('Stock Type', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 8),
            Row(
              children: _stockTypes.map((type) => Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _stockType = type),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: _stockType == type ? const Color(0xFF1B4F72) : Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _stockType == type ? const Color(0xFF1B4F72) : Colors.grey,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          type == 'Regular' ? Icons.autorenew : Icons.looks_one_outlined,
                          color: _stockType == type ? Colors.white : Colors.grey,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          type,
                          style: TextStyle(
                            color: _stockType == type ? Colors.white : Colors.grey,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          type == 'Regular' ? 'Always available' : 'Limited stock',
                          style: TextStyle(
                            fontSize: 10,
                            color: _stockType == type ? Colors.white70 : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
            _field(_colourCtrl, 'Colour', required: true),
            Row(children: [
              Expanded(child: _field(_piecesCtrl, 'Pieces/Box', numeric: true, required: true)),
              const SizedBox(width: 12),
              Expanded(child: _field(_qtyCtrl, 'Box Quantity', numeric: true, required: true)),
            ]),
            Row(children: [
              Expanded(child: _field(_weightCtrl, 'Box Weight (kg)', numeric: true, required: true)),
              const SizedBox(width: 12),
              Expanded(child: _field(_thicknessCtrl, 'Thickness (mm)', numeric: true, required: true)),
            ]),
            _field(_priceCtrl, 'Box Price', numeric: true, required: true),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  if (_formKey.currentState!.validate()) context.pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4F72),
                  foregroundColor: Colors.white,
                ),
                child: Text(isEdit ? 'Update Stock' : 'Add Stock', style: const TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, {bool required = false, bool numeric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: ctrl,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        validator: required ? (v) => v!.isEmpty ? 'Required' : null : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}