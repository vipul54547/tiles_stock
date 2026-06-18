import 'package:flutter/material.dart';
import '../../models/dna.dart';
import '../../services/supabase_data_service.dart';

/// The "+" per-design DNA mapper. Opens a sheet to tag one Library design with
/// its searchable attributes. Single-pick attributes use a DROPDOWN (None =
/// default); Colour (multi) uses check-chips. Every option is labelled with the
/// stockist's OWN word for that value (My Words; falls back to the admin's
/// canonical name) while the hidden canonical value_id is what gets stored, so
/// all stockists' wording unifies under one search key. (project_design_dna_engine)
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
  final Map<String, Set<String>> _selected = {}; // attrId → valueIds (canonical)
  final Map<String, List<String>> _freeTexts = {}; // attrId → free-text values
  final Map<String, TextEditingController> _ftCtrls = {}; // free-text inputs
  Map<String, List<String>> _myWords = {}; // valueId → stockist's words
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ftCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final attrs = await _data.dnaCatalog();
    final cur = await _data.dnaForDesign(widget.libraryId);
    final words = await _data.dnaMyWords();
    if (!mounted) return;
    setState(() {
      // Free-text attributes (e.g. Range) are edited as typed chips; the rest
      // pick canonical values (dropdown / check-chips).
      _attrs = attrs.toList();
      _myWords = words;
      _selected
        ..clear()
        ..addEntries(_attrs
            .where((a) => !a.isFreeText)
            .map((a) =>
                MapEntry(a.id, (cur[a.id] ?? const []).map((v) => v.id).toSet())));
      _freeTexts
        ..clear()
        ..addEntries(_attrs
            .where((a) => a.isFreeText)
            .map((a) =>
                MapEntry(a.id, (cur[a.id] ?? const []).map((v) => v.name).toList())));
      _loading = false;
    });
  }

  // The label shown for a value: the stockist's first own word for it, else the
  // admin's canonical name.
  String _label(DnaValue v) {
    final words = _myWords[v.id];
    return (words != null && words.isNotEmpty) ? words.first : v.name;
  }

  bool _isNone(DnaValue v) => v.name.toLowerCase() == 'none';

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

  // Single-pick dropdown: null = None (clears the attribute on this design).
  void _pickSingle(DnaAttribute a, String? valueId) {
    setState(() {
      final sel = _selected[a.id]!..clear();
      if (valueId != null) sel.add(valueId);
    });
    _save(a);
  }

  // Multi-pick (Colour) check-chips.
  void _toggleMulti(DnaAttribute a, String valueId) {
    setState(() {
      final sel = _selected[a.id]!;
      sel.contains(valueId) ? sel.remove(valueId) : sel.add(valueId);
    });
    _save(a);
  }

  // Free-text (e.g. Range): save the whole text list for the attribute.
  Future<void> _saveFreeText(DnaAttribute a) async {
    setState(() => _saving = true);
    try {
      await _data.dnaSetDesignText(
          widget.libraryId, a.id, _freeTexts[a.id] ?? const []);
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

  void _addFreeText(DnaAttribute a) {
    final ctrl = _ftCtrls[a.id];
    final t = ctrl?.text.trim() ?? '';
    if (t.isEmpty) return;
    final list = _freeTexts.putIfAbsent(a.id, () => []);
    if (list.any((x) => x.toLowerCase() == t.toLowerCase())) {
      ctrl?.clear();
      return;
    }
    setState(() {
      list.add(t);
      ctrl?.clear();
    });
    _saveFreeText(a);
  }

  void _removeFreeText(DnaAttribute a, String t) {
    setState(() => _freeTexts[a.id]?.remove(t));
    _saveFreeText(a);
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
                      'Tag this design so buyers can find it. Options use your '
                      'own words (set them in "My Words"). Changes save '
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
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
                    style:
                        TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 6),
          a.isFreeText
              ? _freeTextEditor(a)
              : (a.isMulti ? _multiChips(a) : _singleDropdown(a)),
        ],
      ),
    );
  }

  // Free-text (e.g. Range): typed values shown as removable chips + an add field.
  Widget _freeTextEditor(DnaAttribute a) {
    final texts = _freeTexts[a.id] ?? const <String>[];
    final ctrl = _ftCtrls.putIfAbsent(a.id, () => TextEditingController());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (texts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: texts
                  .map((t) => InputChip(
                        label: Text(t, style: const TextStyle(fontSize: 12.5)),
                        onDeleted: () => _removeFreeText(a, t),
                        backgroundColor: _navy.withValues(alpha: 0.08),
                        side: BorderSide(color: Colors.grey.shade300),
                      ))
                  .toList(),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => _addFreeText(a),
                decoration: InputDecoration(
                  hintText: 'Add ${a.name.toLowerCase()}…',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300)),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle, color: _navy),
              tooltip: 'Add',
              onPressed: () => _addFreeText(a),
            ),
          ],
        ),
      ],
    );
  }

  // Single-pick → dropdown; the leading "None" entry clears the attribute.
  Widget _singleDropdown(DnaAttribute a) {
    final options = a.values.where((v) => !_isNone(v)).toList();
    final sel = _selected[a.id] ?? const {};
    final current = sel.isEmpty ? null : sel.first;
    // Guard against a stored value that's no longer in the active catalog.
    final value =
        options.any((v) => v.id == current) ? current : null;
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey.shade300)),
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('— None —',
              style: TextStyle(color: Colors.black45, fontSize: 13.5)),
        ),
        ...options.map((v) => DropdownMenuItem<String?>(
              value: v.id,
              child: Text(_label(v),
                  style: const TextStyle(fontSize: 13.5),
                  overflow: TextOverflow.ellipsis),
            )),
      ],
      onChanged: (v) => _pickSingle(a, v),
    );
  }

  // Multi-pick (Colour) → check-chips.
  Widget _multiChips(DnaAttribute a) {
    final sel = _selected[a.id] ?? const {};
    final options = a.values.where((v) => !_isNone(v)).toList();
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: options.map((v) {
        final on = sel.contains(v.id);
        return FilterChip(
          label: Text(_label(v)),
          selected: on,
          showCheckmark: true,
          selectedColor: _navy.withValues(alpha: 0.15),
          labelStyle: TextStyle(
              fontSize: 12.5,
              color: on ? _navy : Colors.black87,
              fontWeight: on ? FontWeight.bold : FontWeight.normal),
          side: BorderSide(color: on ? _navy : Colors.grey.shade300),
          onSelected: (_) => _toggleMulti(a, v.id),
        );
      }).toList(),
    );
  }
}
