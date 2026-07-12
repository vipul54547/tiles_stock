import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/dna.dart';
import '../../services/supabase_data_service.dart';

/// Admin master list of "Design DNA" — the searchable design attributes. Each
/// attribute (Punch, Look Type, Colour…) has its own canonical values. Surface
/// is NOT a DNA attribute — it lives on the stock row (project_per_brand_surface_mode).
/// Fully dynamic: add/edit/delete attributes AND values anytime. Stockists map
/// their wording to these; buyers search on them. (project_design_dna_engine)
class ManageDesignDnaScreen extends StatefulWidget {
  const ManageDesignDnaScreen({super.key});

  @override
  State<ManageDesignDnaScreen> createState() => _ManageDesignDnaScreenState();
}

class _ManageDesignDnaScreenState extends State<ManageDesignDnaScreen> {
  static const _navy = Color(0xFF1B4F72);
  static const _cyan = Color(0xFF00838F);   // dependent (child) accent
  static const _amber = Color(0xFFB9770E);  // the DNA identity colour
  final _data = SupabaseDataService();

  Map<String, String> get _attrName => {for (final a in _attrs) a.id: a.name};
  Map<String, String> get _valueName =>
      {for (final a in _attrs) for (final v in a.values) v.id: v.name};

  DnaAttribute? _attr(String? id) {
    if (id == null) return null;
    for (final a in _attrs) {
      if (a.id == id) return a;
    }
    return null;
  }

  List<DnaAttribute> _attrs = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _data.dnaCatalog();
      setState(() {
        _attrs = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
      duration: Duration(seconds: error ? 5 : 2),
    ));
  }

  Future<void> _run(Future<void> Function() action, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (ok != null) _snack(ok);
      await _load();
    } catch (e) {
      _snack(e.toString().replaceAll('PostgrestException:', '').trim(),
          error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── attribute actions ────────────────────────────────────────────────────
  Future<void> _addAttribute() async {
    final res = await showDialog<_NewAttr>(
      context: context,
      builder: (_) => const _AddAttributeDialog(),
    );
    if (res == null) return;
    await _run(
        () => _data.adminDnaAddAttribute(res.name,
            isMulti: res.isMulti, isFreeText: res.isFreeText),
        ok: 'Attribute added.');
  }

  Future<void> _renameAttribute(DnaAttribute a) async {
    final name = await _nameDialog(
        title: 'Rename attribute', initial: a.name, label: 'Attribute name');
    if (name == null || name.trim() == a.name) return;
    await _run(() => _data.adminDnaUpdateAttribute(a.id, name: name),
        ok: 'Renamed.');
  }

  Future<void> _deleteAttribute(DnaAttribute a) async {
    final yes = await _confirm('Delete attribute "${a.name}"?',
        'This removes the attribute and ALL its values, and clears it from every '
            'design that used it. This cannot be undone.');
    if (!yes) return;
    await _run(() => _data.adminDnaDeleteAttribute(a.id), ok: 'Deleted.');
  }

  // ── mapping + dependency ───────────────────────────────────────────────────
  Future<void> _setMapping(DnaAttribute a, bool on) async {
    await _run(() => _data.adminDnaUpdateAttribute(a.id, allowMapping: on),
        ok: on ? 'Stockist mapping ON.' : 'Admin words only.');
  }

  Future<void> _setParent(DnaAttribute a) async {
    // Candidates: other active value-list attributes, not self, and not already a
    // child of this one (blocks a direct cycle).
    final cands = _attrs
        .where((x) =>
            x.id != a.id && !x.isFreeText && x.parentAttributeId != a.id)
        .toList();
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('"${a.name}" depends on'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__none__'),
            child: const Text('Independent (no parent)'),
          ),
          const Divider(height: 1),
          for (final c in cands)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    if (chosen == '__none__') {
      if (!a.isDependent) return;
      await _run(() => _data.adminDnaUpdateAttribute(a.id, clearParent: true),
          ok: 'Now independent.');
    } else {
      if (chosen == a.parentAttributeId) return;
      await _run(
          () => _data.adminDnaUpdateAttribute(a.id, parentAttributeId: chosen),
          ok: 'Now a child of ${_attrName[chosen]}. Re-assign its values.');
    }
  }

  // ── value actions ─────────────────────────────────────────────────────────
  Future<void> _addValue(DnaAttribute a) async {
    String? parentValueId;
    if (a.isDependent) {
      final parent = _attr(a.parentAttributeId);
      final pvals = (parent?.values ?? const <DnaValue>[])
          .where((v) => v.name.toLowerCase() != 'none')
          .toList();
      if (pvals.isEmpty) {
        _snack('Add values to ${_attrName[a.parentAttributeId]} first.',
            error: true);
        return;
      }
      parentValueId = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('Under which ${_attrName[a.parentAttributeId]}?'),
          children: [
            for (final v in pvals)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, v.id),
                child: Text(v.name),
              ),
          ],
        ),
      );
      if (parentValueId == null) return;
    }
    final name = await _nameDialog(
        title: 'Add value to ${a.name}',
        label: 'Value',
        hint: a.isDependent ? 'e.g. Carara, kota stone' : 'e.g. Texture, Marble');
    if (name == null) return;
    await _run(() => _data.adminDnaAddValue(a.id, name, parentValueId: parentValueId),
        ok: 'Value added.');
  }

  Future<void> _renameValue(DnaAttribute a, DnaValue v) async {
    final name =
        await _nameDialog(title: 'Rename value', initial: v.name, label: 'Value');
    if (name == null || name.trim() == v.name) return;
    await _run(() => _data.adminDnaUpdateValue(v.id, name: name), ok: 'Renamed.');
  }

  Future<void> _deleteValue(DnaAttribute a, DnaValue v) async {
    if (v.name.toLowerCase() == 'none') {
      _snack('“None” is the default — it can\'t be deleted.', error: true);
      return;
    }
    final yes = await _confirm('Delete value "${v.name}"?',
        'Removes it from ${a.name}. Designs already using it keep their value.');
    if (!yes) return;
    await _run(() => _data.adminDnaDeleteValue(v.id), ok: 'Deleted.');
  }

  // ── dialogs ────────────────────────────────────────────────────────────────
  Future<bool> _confirm(String title, String body) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return yes == true;
  }

  Future<String?> _nameDialog(
      {required String title,
      required String label,
      String? initial,
      String? hint}) {
    final ctrl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: _navy, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Design DNA'),
        actions: [
          IconButton(
            tooltip: 'Add attribute',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _addAttribute,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 40),
            const SizedBox(height: 12),
            Text('Could not load: $_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    return Column(
      children: [
        // Top row — the other master-data lists live here too.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/admin/surfaces'),
                  icon: const Icon(Icons.texture_rounded, size: 18),
                  label: const Text('Finishes'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00897B)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/admin/sizes'),
                  icon: const Icon(Icons.straighten_rounded, size: 18),
                  label: const Text('Sizes'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF5E35B1)),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: _navy.withValues(alpha: 0.06),
          child: const Text(
            'These attributes power buyer search. Each has its own values. '
            'Stockists tag each design with them (mapping their wording to your '
            'values). Tap an attribute to manage its values.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            children: _attrs.map(_attrCard).toList(),
          ),
        ),
      ],
    );
  }

  Widget _attrCard(DnaAttribute a) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Flexible(
              child: Text(a.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            const SizedBox(width: 8),
            if (a.isMulti) _badge('multi', const Color(0xFF6A1B9A)),
            if (a.isFreeText) _badge('free text', Colors.teal),
            if (!a.allowMapping) _badge('no map', Colors.orange.shade800),
            if (a.isDependent)
              _badge('↳ ${_attrName[a.parentAttributeId] ?? 'parent'}', _cyan),
          ],
        ),
        subtitle: Text(
            a.isDependent
                ? 'Child of ${_attrName[a.parentAttributeId] ?? 'parent'} · '
                    '${a.values.length} value${a.values.length == 1 ? '' : 's'}'
                : a.isFreeText
                    ? 'Stockist types their own text (no fixed list).'
                    : '${a.values.length} value${a.values.length == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11.5)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [
          // Mapping on/off + Depends-on — the two new controls.
          Row(children: [
            Icon(a.allowMapping ? Icons.edit_note : Icons.lock_outline,
                size: 18, color: a.allowMapping ? _navy : Colors.orange.shade800),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Stockist mapping',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            Text(a.allowMapping ? 'On' : 'Admin words only',
                style: TextStyle(
                    fontSize: 11.5,
                    color: a.allowMapping ? Colors.grey.shade600 : Colors.orange.shade800)),
            Switch(
              value: a.allowMapping,
              activeThumbColor: _navy,
              onChanged: _busy ? null : (v) => _setMapping(a, v),
            ),
          ]),
          Row(children: [
            const Icon(Icons.account_tree_outlined, size: 18, color: _cyan),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Depends on',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: _busy ? null : () => _setParent(a),
              child: Text(
                  a.isDependent
                      ? (_attrName[a.parentAttributeId] ?? 'parent')
                      : 'Independent',
                  style: TextStyle(
                      color: a.isDependent ? _cyan : Colors.grey.shade600,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const Divider(height: 8),
          // attribute-level actions
          Row(
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _renameAttribute(a),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Rename'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _deleteAttribute(a),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
              ),
              const Spacer(),
              if (!a.isFreeText)
                ElevatedButton.icon(
                  onPressed: _busy ? null : () => _addValue(a),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Value'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _navy,
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          if (!a.isFreeText) const Divider(height: 8),
          if (!a.isFreeText)
            ...a.values.map((v) => _valueRow(a, v)),
        ],
      ),
    );
  }

  Widget _valueRow(DnaAttribute a, DnaValue v) {
    final isNone = v.name.toLowerCase() == 'none';
    final parentName =
        v.parentValueId == null ? null : _valueName[v.parentValueId];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(isNone ? Icons.lock_outline : Icons.label_outline,
              size: 16, color: isNone ? Colors.grey : _navy),
          const SizedBox(width: 10),
          Expanded(
            child: Text(v.name,
                style: TextStyle(
                    fontSize: 14,
                    color: isNone ? Colors.grey : Colors.black87)),
          ),
          // For a dependent attribute, show which parent value this sits under.
          if (parentName != null) ...[
            _badge('under $parentName', _amber),
            const SizedBox(width: 4),
          ],
          if (!isNone) ...[
            IconButton(
              tooltip: 'Rename',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: _busy ? null : () => _renameValue(a, v),
            ),
            IconButton(
              tooltip: 'Delete',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: Colors.red),
              onPressed: _busy ? null : () => _deleteValue(a, v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.bold, color: color)),
      );
}

class _NewAttr {
  final String name;
  final bool isMulti;
  final bool isFreeText;
  const _NewAttr(this.name, this.isMulti, this.isFreeText);
}

class _AddAttributeDialog extends StatefulWidget {
  const _AddAttributeDialog();
  @override
  State<_AddAttributeDialog> createState() => _AddAttributeDialogState();
}

class _AddAttributeDialogState extends State<_AddAttributeDialog> {
  final _ctrl = TextEditingController();
  bool _multi = false;
  bool _freeText = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add attribute'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Attribute name',
                hintText: 'e.g. Punch, Look Type, Use Type',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _multi,
            onChanged: _freeText ? null : (v) => setState(() => _multi = v ?? false),
            title: const Text('Multi-select (checkbox)',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text('A design can hold several values (like Colour)',
                style: TextStyle(fontSize: 11)),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _freeText,
            onChanged: (v) => setState(() {
              _freeText = v ?? false;
              if (_freeText) _multi = false;
            }),
            title:
                const Text('Free text (no value list)', style: TextStyle(fontSize: 13)),
            subtitle: const Text('Stockist types their own text (like Range)',
                style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final name = _ctrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _NewAttr(name, _multi, _freeText));
          },
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4F72),
              foregroundColor: Colors.white),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
