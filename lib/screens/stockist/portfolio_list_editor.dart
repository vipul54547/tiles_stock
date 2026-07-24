import 'package:flutter/material.dart';
import '../../models/brand.dart';
import '../../models/stock_catalog.dart';
import '../../services/supabase_data_service.dart';

/// 🖼️ Create / edit a PORTFOLIO catalogue (project_media_portfolio_ddpi
/// #13/#15/#21). A catalogue is stock-blind and scoped to exactly ONE brand:
/// the buyer sees that brand's designs under that brand's cover word, plus the
/// media (rooms/360/video). "Upload once, brand many" — send buyer A a "Bianco
/// Tera" catalogue and buyer B an "Anuj" one over the same designs + media.
///
/// v1 = name + one brand (the essential scope). Facet narrowing (surface/size/
/// space/DNA) is a later refinement — a brand catalogue shows all the brand's
/// designs by default.
class PortfolioListEditor extends StatefulWidget {
  final StockCatalog? existing;
  final List<Brand> brands;
  const PortfolioListEditor({super.key, this.existing, required this.brands});

  @override
  State<PortfolioListEditor> createState() => _PortfolioListEditorState();
}

class _PortfolioListEditorState extends State<PortfolioListEditor> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  String? _brandId;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _name.text = ex?.name ?? '';
    _desc.text = ex?.description ?? '';
    // Prefill: the existing catalogue's brand, else the default brand.
    _brandId = ex?.catalogueBrandId ??
        (widget.brands.where((b) => b.isDefault).isNotEmpty
            ? widget.brands.firstWhere((b) => b.isDefault).id
            : (widget.brands.isNotEmpty ? widget.brands.first.id : null));
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Give the catalogue a name.');
      return;
    }
    if (_brandId == null) {
      _snack('Pick a brand for the catalogue.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _data.saveCatalogue(
        id: widget.existing?.id,
        name: name,
        brandId: _brandId!,
        description: _desc.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('$e'.replaceAll('PostgrestException:', '').trim());
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isEdit ? 'Edit Portfolio List' : 'New Portfolio List')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'A portfolio catalogue shows this brand\'s designs and their media '
              '(rooms · 360 · video) — no stock or price. Share its link like any '
              'stock list.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Catalogue name *',
              hintText: 'e.g. Bianco Tera Collection',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _desc,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          const Text('Brand *',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13, color: _navy)),
          const SizedBox(height: 2),
          const Text(
              'The catalogue is scoped to one brand and shows each design under '
              'that brand\'s name.',
              style: TextStyle(fontSize: 11.5, color: Colors.black54)),
          const SizedBox(height: 8),
          if (widget.brands.isEmpty)
            const Text('No brands yet.', style: TextStyle(color: Colors.grey))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in widget.brands)
                  ChoiceChip(
                    label: Text(b.name),
                    selected: _brandId == b.id,
                    onSelected: (_) => setState(() => _brandId = b.id),
                  ),
              ],
            ),
          const SizedBox(height: 28),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _navy, foregroundColor: Colors.white),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(_isEdit ? 'Save Changes' : 'Create Catalogue',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
