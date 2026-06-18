import 'package:flutter/material.dart';
import '../../models/dna.dart';
import '../../services/supabase_data_service.dart';

/// The "+" per-design DNA mapper. Opens a sheet to tag one Library design with
/// its searchable attributes — single-pick (chips) for most, multi-pick
/// (checkbox chips) for Colour. Saves per attribute via dna_set_design.
/// Free-text attributes (e.g. Range) are skipped for now (no canonical values).
Future<void> showDnaEditor(BuildContext context,
    {required String libraryId, required String designName}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _DnaEditor(libraryId: libraryId, designName: designName),
  );
}

class _DnaEditor extends StatefulWidget {
  final String libraryId;
  final String designName;
  const _DnaEditor({required this.libraryId, required this.designName});

  @override
  State<_DnaEditor> createState() => _DnaEditorState();
}

class _DnaEditorState extends State<_DnaEditor> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  List<DnaAttribute> _attrs = [];
  final Map<String, Set<String>> _selected = {}; // attrId → valueIds
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final attrs = await _data.dnaCatalog();
    final cur = await _data.dnaForDesign(widget.libraryId);
    if (!mounted) return;
    setState(() {
      _attrs = attrs.where((a) => !a.isFreeText).toList();
      _selected
        ..clear()
        ..addEntries(_attrs.map((a) =>
            MapEntry(a.id, (cur[a.id] ?? const []).map((v) => v.id).toSet())));
      _loading = false;
    });
  }

  Future<void> _save(DnaAttribute a) async {
    setState(() => _saving = true);
    try {
      await _data.dnaSetDesign(
          widget.libraryId, a.id, _selected[a.id]!.toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: Colors.red.shade700));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _pick(DnaAttribute a, String valueId) {
    setState(() {
      final sel = _selected[a.id]!;
      if (a.isMulti) {
        sel.contains(valueId) ? sel.remove(valueId) : sel.add(valueId);
      } else {
        sel
          ..clear()
          ..add(valueId);
      }
    });
    _save(a);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (_, scroll) {
            return Column(
              children: [
                const SizedBox(height: 8),
                Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.science_outlined, color: _navy, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Design DNA · ${widget.designName}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                      if (_saving)
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                      'Tag this design so buyers can find it. Changes save '
                      'automatically.',
                      style: TextStyle(fontSize: 11.5, color: Colors.black54)),
                ),
                const Divider(height: 12),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          children: _attrs.map(_attrSection).toList(),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _attrSection(DnaAttribute a) {
    final sel = _selected[a.id] ?? const {};
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(a.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13.5)),
              const SizedBox(width: 6),
              if (a.isMulti)
                Text('(pick any)',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: a.values.map((v) {
              final on = sel.contains(v.id);
              return ChoiceChip(
                label: Text(v.name),
                selected: on,
                showCheckmark: a.isMulti,
                selectedColor: _navy.withValues(alpha: 0.15),
                labelStyle: TextStyle(
                    fontSize: 12.5,
                    color: on ? _navy : Colors.black87,
                    fontWeight: on ? FontWeight.bold : FontWeight.normal),
                side: BorderSide(
                    color: on ? _navy : Colors.grey.shade300),
                onSelected: (_) => _pick(a, v.id),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
