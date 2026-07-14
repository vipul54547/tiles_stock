import 'package:flutter/material.dart';
import '../../models/dna.dart';
import '../../services/supabase_data_service.dart';
import 'manage_my_dna_values_screen.dart';

/// The "+" per-design DNA mapper. Opens a sheet to tag one Library design with
/// its searchable attributes. Single-pick canonical attributes use a DROPDOWN
/// (None = default); Colour (multi) uses check-chips. Own-naming single-pick
/// free-text attributes (Series) use a picker of the stockist's own
/// previously-created values + "Create new" — no admin mapping. Every
/// canonical option is labelled with the stockist's OWN word for that value
/// (My Words; falls back to the admin's canonical name) while the hidden
/// canonical value_id is what gets stored, so all stockists' wording unifies
/// under one search key. (project_design_dna_engine)
/// [scope] picks WHICH DNA is being edited, and the two are different things:
///
/// * `'print'` — the **IMAGE DNA**: Look Type ▸ Natural Name · Design Joint · Print Type · Colour.
///   It describes the ARTWORK, so it is stored on the print and **every piece of that print carries
///   it**. Tag `1001` once and its Matt, Carving and GHR all have it.
/// * `'product'` — what describes **this piece alone**.
///
/// Null shows everything (the old behaviour). The server routes the write either way — the scope
/// here only decides what is worth *offering*, so the two icons don't both present the same list.
Future<void> showDnaEditor(BuildContext context,
    {required String libraryId, required String designName, String? scope}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) =>
        _DnaEditor(libraryId: libraryId, designName: designName, scope: scope),
  );
}

class _DnaEditor extends StatefulWidget {
  final String libraryId;
  final String designName;
  final String? scope;
  const _DnaEditor(
      {required this.libraryId, required this.designName, this.scope});

  @override
  State<_DnaEditor> createState() => _DnaEditorState();
}

class _DnaEditorState extends State<_DnaEditor> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  List<DnaAttribute> _attrs = [];
  final Map<String, Set<String>> _selected = {}; // attrId → valueIds (canonical)
  final Map<String, List<String>> _freeTexts = {}; // attrId → free-text values
  // free_text_detail: primary valueId → the stockist's word tied to it.
  final Map<String, String> _detailWord = {};
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
    final all = await _data.dnaCatalog();
    // Offer only the DNA this editor is for. The image DNA belongs to the artwork and the rest to
    // the piece — showing both lists under both icons is how you end up tagging the wrong thing.
    final attrs = widget.scope == null
        ? all
        : all.where((a) => a.scope == widget.scope).toList();
    final cur = await _data.dnaForDesign(widget.libraryId);
    final words = await _data.dnaMyWords();
    if (!mounted) return;
    setState(() {
      // Free-text attributes (e.g. Range) are edited as typed chips; the rest
      // pick canonical values (dropdown / check-chips). Order each dependent
      // (child) attribute right after its parent so the cascade reads top-down.
      final sorted = attrs.toList();
      double keyOf(DnaAttribute a) {
        if (a.parentAttributeId == null) return a.sortOrder.toDouble();
        final p = attrs.where((z) => z.id == a.parentAttributeId);
        return (p.isEmpty ? a.sortOrder : p.first.sortOrder) + 0.5;
      }
      sorted.sort((x, y) {
        final c = keyOf(x).compareTo(keyOf(y));
        return c != 0 ? c : x.sortOrder.compareTo(y.sortOrder);
      });
      _attrs = sorted;
      _myWords = words;
      _selected.clear();
      _detailWord.clear();
      for (final a in _attrs.where((a) => !a.isFreeText)) {
        // For a free_text_detail attribute a tagged value is either a PRIMARY
        // value (its parent is in the parent attribute) or a stockist DETAIL word
        // (its parent is one of THIS attribute's own values).
        final ownIds =
            a.freeTextDetail ? a.values.map((v) => v.id).toSet() : null;
        final set = <String>{};
        for (final v in cur[a.id] ?? const <DnaValue>[]) {
          if (ownIds != null &&
              v.parentValueId != null &&
              ownIds.contains(v.parentValueId)) {
            _detailWord[v.parentValueId!] = v.name;
          } else {
            set.add(v.id);
          }
        }
        _selected[a.id] = set;
      }
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
  // admin's canonical name. When mapping is OFF, always the admin name.
  String _label(DnaAttribute a, DnaValue v) {
    if (!a.allowMapping) return v.name;
    final words = _myWords[v.id];
    return (words != null && words.isNotEmpty) ? words.first : v.name;
  }

  bool _isNone(DnaValue v) => v.name.toLowerCase() == 'none';

  DnaAttribute? _attr(String? id) {
    if (id == null) return null;
    for (final a in _attrs) {
      if (a.id == id) return a;
    }
    return null;
  }

  // The parent value chosen on THIS design for a dependent attribute (null = the
  // stockist hasn't picked the parent yet, so the child stays gated).
  String? _parentValueOf(DnaAttribute child) {
    final pid = child.parentAttributeId;
    if (pid == null) return null;
    final sel = _selected[pid];
    return (sel != null && sel.isNotEmpty) ? sel.first : null;
  }

  // When a parent value changes, its children no longer apply — clear them, and
  // recurse so deeper levels (e.g. a free-text under a value-list child) clear
  // too. [visited] guards against a mis-configured attribute cycle.
  void _clearChildrenOf(DnaAttribute parent, [Set<String>? visited]) {
    final seen = visited ?? <String>{};
    if (!seen.add(parent.id)) return;
    for (final child in _attrs.where((x) => x.parentAttributeId == parent.id)) {
      if (child.isFreeText) {
        if (_freeTexts[child.id]?.isNotEmpty ?? false) {
          setState(() => _freeTexts[child.id] = []);
          _saveFreeText(child);
        }
      } else if (_selected[child.id]?.isNotEmpty ?? false) {
        setState(() => _selected[child.id]!.clear());
        _save(child);
      }
      _clearChildrenOf(child, seen); // deeper levels
    }
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

  // Single-pick dropdown: null = None (clears the attribute on this design).
  void _pickSingle(DnaAttribute a, String? valueId) {
    final old =
        (_selected[a.id]?.isNotEmpty ?? false) ? _selected[a.id]!.first : null;
    setState(() {
      final sel = _selected[a.id]!..clear();
      if (valueId != null) sel.add(valueId);
    });
    _save(a);
    if (old != valueId) {
      // If this attribute is a parent and its value changed, reset its children.
      _clearChildrenOf(a);
      // A free_text_detail word is tied to the old value — the server clears it
      // via the orphan sweep; drop it from client state too.
      if (a.freeTextDetail && old != null) {
        setState(() => _detailWord.remove(old));
      }
    }
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
    // Own-naming single-pick attributes (e.g. Series): no admin mapping, the
    // stockist creates + manages their own value list.
    final isOwnSingle = a.isFreeText && !a.isMulti;

    // Dependent (child) attribute: gate it behind its parent value.
    final parentName = a.isDependent ? _attr(a.parentAttributeId)?.name : null;
    final parentVal = a.isDependent ? _parentValueOf(a) : null;
    final gated = a.isDependent && parentVal == null;

    Widget content;
    if (gated) {
      content = _gatedPlaceholder(parentName ?? 'parent');
    } else if (isOwnSingle) {
      content = _singleFreeTextPicker(a);
    } else if (a.isFreeText) {
      content = _freeTextEditor(a);
    } else {
      // Value-list: for a child, only the values under the chosen parent value.
      // A free_text_detail attribute must not list its own detail words as
      // pickable primaries (their parent is one of THIS attribute's values).
      final Set<String> ownIds =
          a.freeTextDetail ? a.values.map((v) => v.id).toSet() : <String>{};
      final opts = a.values
          .where((v) =>
              !_isNone(v) &&
              (!a.isDependent || v.parentValueId == parentVal) &&
              !ownIds.contains(v.parentValueId))
          .toList();
      final primary = a.isMulti ? _multiChips(a, opts) : _singleDropdown(a, opts);

      // free_text_detail: once a value is picked, offer a word tied to it.
      final picked = (!a.isMulti && (_selected[a.id]?.isNotEmpty ?? false))
          ? _selected[a.id]!.first
          : null;
      if (a.freeTextDetail && picked != null) {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [primary, const SizedBox(height: 8), _detailControl(a, picked)],
        );
      } else {
        content = primary;
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(a.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
              const SizedBox(width: 6),
              if (parentName != null)
                Text('↳ $parentName',
                    style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFF00838F),
                        fontWeight: FontWeight.w600)),
              if (a.isMulti)
                Text('(pick any)',
                    style:
                        TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
              const Spacer(),
              if (isOwnSingle && !gated)
                InkWell(
                  onTap: () => _manageOwnValues(a),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.settings_outlined,
                        size: 16, color: Colors.grey.shade600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          content,
        ],
      ),
    );
  }

  // free_text_detail: a dropdown of words already saved under [primaryValueId]
  // + "Create new". The word is stored tied to that value (e.g. under Wave).
  Widget _detailControl(DnaAttribute a, String primaryValueId) {
    const amber = Color(0xFFB9770E);
    final words =
        a.values.where((v) => v.parentValueId == primaryValueId).toList();
    final current = _detailWord[primaryValueId];
    final value = words.any((w) => w.name == current) ? current : null;
    final parentName = a.values
        .firstWhere((v) => v.id == primaryValueId,
            orElse: () => const DnaValue(id: '', name: ''))
        .name;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: amber.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Detail for “$parentName”',
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: amber)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String?>(
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            items: [
              const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('— None —',
                      style: TextStyle(color: Colors.black45, fontSize: 13.5))),
              ...words.map((w) => DropdownMenuItem<String?>(
                  value: w.name,
                  child: Text(w.name, style: const TextStyle(fontSize: 13.5)))),
              const DropdownMenuItem<String?>(
                  value: '__new__',
                  child: Text('＋ Create new…',
                      style:
                          TextStyle(color: amber, fontWeight: FontWeight.w600))),
            ],
            onChanged: (v) {
              if (v == '__new__') {
                _newDetail(primaryValueId);
              } else {
                _setDetail(primaryValueId, v);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _setDetail(String primaryValueId, String? name) async {
    final word = name?.trim() ?? '';
    setState(() {
      if (word.isEmpty) {
        _detailWord.remove(primaryValueId);
      } else {
        _detailWord[primaryValueId] = word;
      }
    });
    setState(() => _saving = true);
    try {
      await _data.dnaSetValueDetail(
          widget.libraryId, primaryValueId, word.isEmpty ? [] : [word]);
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

  Future<void> _newDetail(String primaryValueId) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add detail'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              hintText: 'e.g. water punch', isDense: true),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _setDetail(primaryValueId, name);
    if (mounted) _load(); // refresh so the new word joins the dropdown
  }

  Widget _gatedPlaceholder(String parentName) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(Icons.subdirectory_arrow_right,
              size: 16, color: Colors.grey.shade500),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Choose $parentName first',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ),
        ]),
      );

  Future<void> _manageOwnValues(DnaAttribute a) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ManageMyDnaValuesScreen(
            attributeId: a.id, attributeName: a.name),
      ),
    );
    if (mounted) _load(); // names/values may have changed
  }

  // Own-naming single-pick (e.g. Series): tap to open a picker of the
  // stockist's own previously-created values + "None" + "Create new".
  Future<void> _setSingleFreeText(DnaAttribute a, String? text) async {
    setState(() {
      _freeTexts[a.id] = (text == null || text.isEmpty) ? [] : [text];
    });
    await _saveFreeText(a);
  }

  Future<void> _pickSingleFreeText(DnaAttribute a) async {
    final current =
        (_freeTexts[a.id] ?? const <String>[]).isEmpty ? null : _freeTexts[a.id]!.first;
    final result = await showModalBottomSheet<_FreeTextPick>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _FreeTextPickSheet(attribute: a, current: current),
    );
    if (result == null) return;
    if (result.createNew) {
      if (!mounted) return;
      final ctrl = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('New ${a.name.toLowerCase()}'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(isDense: true),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Add')),
          ],
        ),
      );
      if (name == null || name.isEmpty) return;
      await _setSingleFreeText(a, name);
    } else {
      await _setSingleFreeText(a, result.name);
    }
  }

  Widget _singleFreeTextPicker(DnaAttribute a) {
    final current =
        (_freeTexts[a.id] ?? const <String>[]).isEmpty ? null : _freeTexts[a.id]!.first;
    return InkWell(
      onTap: () => _pickSingleFreeText(a),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current ?? '— None —',
                style: TextStyle(
                    fontSize: 13.5,
                    color: current == null ? Colors.black45 : Colors.black87),
              ),
            ),
            Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
          ],
        ),
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
  Widget _singleDropdown(DnaAttribute a, List<DnaValue> options) {
    final sel = _selected[a.id] ?? const {};
    final current = sel.isEmpty ? null : sel.first;
    // Guard against a stored value that's no longer in the active/filtered list.
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
              child: Text(_label(a, v),
                  style: const TextStyle(fontSize: 13.5),
                  overflow: TextOverflow.ellipsis),
            )),
      ],
      onChanged: (v) => _pickSingle(a, v),
    );
  }

  // Multi-pick (Colour) → check-chips.
  Widget _multiChips(DnaAttribute a, List<DnaValue> options) {
    final sel = _selected[a.id] ?? const {};
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: options.map((v) {
        final on = sel.contains(v.id);
        return FilterChip(
          label: Text(_label(a, v)),
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

class _FreeTextPick {
  final bool createNew;
  final String? name;
  const _FreeTextPick.value(this.name) : createNew = false;
  const _FreeTextPick.create()
      : createNew = true,
        name = null;
}

// Picker sheet for an own-naming single-pick free-text attribute (Series):
// "None" + the stockist's own previously-created values + "Create new".
class _FreeTextPickSheet extends StatelessWidget {
  static const _navy = Color(0xFF1B4F72);
  final DnaAttribute attribute;
  final String? current;
  const _FreeTextPickSheet({required this.attribute, required this.current});

  @override
  Widget build(BuildContext context) {
    final options = attribute.values.where((v) => !_isNone(v)).toList();
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(attribute.name,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          ListTile(
            leading: Icon(
                current == null ? Icons.radio_button_checked : Icons.radio_button_off,
                color: current == null ? _navy : Colors.grey),
            title: const Text('— None —'),
            onTap: () => Navigator.pop(context, const _FreeTextPick.value(null)),
          ),
          ...options.map((v) => ListTile(
                leading: Icon(
                    current == v.name
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: current == v.name ? _navy : Colors.grey),
                title: Text(v.name),
                onTap: () =>
                    Navigator.pop(context, _FreeTextPick.value(v.name)),
              )),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add_circle_outline, color: _navy),
            title: Text('Create new ${attribute.name.toLowerCase()}…',
                style: const TextStyle(color: _navy, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(context, const _FreeTextPick.create()),
          ),
        ],
      ),
    );
  }

  bool _isNone(DnaValue v) => v.name.toLowerCase() == 'none';
}
