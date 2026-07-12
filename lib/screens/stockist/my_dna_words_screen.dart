import 'package:flutter/material.dart';
import '../../models/dna.dart';
import '../../models/surface_type.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';

/// "My Words" — the stockist maps their OWN words onto the admin's canonical
/// Design-DNA values. Each admin value is a solid section-coloured chip on the
/// left; on the right the stockist types a word and taps Add to attach it as a
/// removable chip. The canonical value stays the hidden search key; these words
/// are what the stockist + buyer see and what import matching recognises.
/// (project_design_dna_engine)
class MyDnaWordsScreen extends StatefulWidget {
  const MyDnaWordsScreen({super.key});

  @override
  State<MyDnaWordsScreen> createState() => _MyDnaWordsScreenState();
}

class _MyDnaWordsScreenState extends State<MyDnaWordsScreen> {
  static const _navy = Color(0xFF1B4F72);

  // One solid colour per section (DNA attribute / Surface), cycled by position.
  // All admin chips within a section share it; it changes between sections.
  static const _sectionColors = [
    Color(0xFF00897B), // teal
    Color(0xFFEF6C00), // orange
    Color(0xFF6A1B9A), // purple
    Color(0xFF2E7D32), // green
    Color(0xFF1565C0), // blue
    Color(0xFFC2185B), // pink
    Color(0xFF5D4037), // brown
    Color(0xFF00838F), // cyan
  ];

  final _data = SupabaseDataService();

  List<DnaAttribute> _attrs = [];
  final Map<String, List<String>> _words = {}; // valueId → saved words
  final Map<String, TextEditingController> _ctrls = {}; // valueId → input buffer
  final Map<String, FocusNode> _focus = {}; // valueId → field focus

  // Surface is admin-controlled (not a DNA attribute), but the stockist maps
  // their OWN words onto each admin finish exactly like a DNA value. Shown as one
  // extra "Surface / Finish" section; words live in surface_aliases.
  List<SurfaceType> _surfaces = [];
  final Map<String, List<String>> _surfWords = {}; // finishName → saved words
  final Map<String, TextEditingController> _surfCtrls = {};
  final Map<String, FocusNode> _surfFocus = {};

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final c in _surfCtrls.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    for (final f in _surfFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final attrs = await _data.dnaCatalog();
    final words = await _data.dnaMyWords();
    final surfaces = await _data.getSurfaceTypes(activeOnly: true);
    final surfWords = currentStockistUUID.isEmpty
        ? <String, List<String>>{}
        : await _data.getSurfaceWordsByFinish(currentStockistUUID);
    if (!mounted) return;

    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _ctrls.clear();
    _focus.clear();
    _words.clear();
    for (final a in attrs) {
      if (a.isFreeText) continue;
      if (!a.allowMapping) continue; // nothing to map — admin words only
      for (final v in a.values) {
        if (v.name.toLowerCase() == 'none') continue;
        _words[v.id] = List<String>.from(words[v.id] ?? const []);
        _ctrls[v.id] = TextEditingController();
        _focus[v.id] = FocusNode();
      }
    }

    for (final c in _surfCtrls.values) {
      c.dispose();
    }
    for (final f in _surfFocus.values) {
      f.dispose();
    }
    _surfCtrls.clear();
    _surfFocus.clear();
    _surfWords.clear();
    // 'None' is the no-surface fallback (isSystem) — it carries no words.
    final finishes =
        surfaces.where((s) => !s.isSystem && s.name.toLowerCase() != 'none');
    for (final s in finishes) {
      _surfWords[s.name] = List<String>.from(surfWords[s.name] ?? const []);
      _surfCtrls[s.name] = TextEditingController();
      _surfFocus[s.name] = FocusNode();
    }

    setState(() {
      // Map-off attributes (admin words only) have nothing to map — leave them
      // out of My Words entirely. (project_dna_cascade_mapping)
      _attrs = attrs.where((a) => !a.isFreeText && a.allowMapping).toList();
      _surfaces = finishes.toList();
      _loading = false;
    });
  }

  // Split on comma / semicolon / new line; trim; drop blanks; case-insensitive dedup.
  List<String> _parse(String text) {
    final out = <String>[];
    final seen = <String>{};
    for (final part in text.split(RegExp(r'[,;\n]'))) {
      final w = part.trim();
      if (w.isEmpty) continue;
      if (seen.add(w.toLowerCase())) out.add(w);
    }
    return out;
  }

  // Shown when Add is tapped with nothing typed — then the field is focused.
  void _emptyHint(FocusNode node) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type a word first'),
        content: const Text(
            'Type your own word for this value (e.g. for "Sugar" type '
            '"Raindrop"), then tap Add. You can add several at once by separating '
            'them with commas.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    ).then((_) {
      if (mounted) node.requestFocus();
    });
  }

  // Append the typed word(s) to a value's saved words, then persist + clear input.
  Future<void> _addWord(String valueId) async {
    final typed = _parse(_ctrls[valueId]!.text);
    if (typed.isEmpty) {
      _emptyHint(_focus[valueId]!);
      return;
    }
    final cur = _words[valueId] ??= [];
    final seen = cur.map((w) => w.toLowerCase()).toSet();
    for (final w in typed) {
      if (seen.add(w.toLowerCase())) cur.add(w);
    }
    _ctrls[valueId]!.clear();
    setState(() {});
    await _persist(() => _data.dnaSetValueWords(valueId, cur));
  }

  void _removeWord(String valueId, String word) {
    _words[valueId]?.removeWhere((w) => w.toLowerCase() == word.toLowerCase());
    setState(() {});
    _persist(() => _data.dnaSetValueWords(valueId, _words[valueId] ?? const []));
  }

  Future<void> _addSurfaceWord(String finishName) async {
    if (currentStockistUUID.isEmpty) return;
    final typed = _parse(_surfCtrls[finishName]!.text);
    if (typed.isEmpty) {
      _emptyHint(_surfFocus[finishName]!);
      return;
    }
    final cur = _surfWords[finishName] ??= [];
    final seen = cur.map((w) => w.toLowerCase()).toSet();
    for (final w in typed) {
      if (seen.add(w.toLowerCase())) cur.add(w);
    }
    _surfCtrls[finishName]!.clear();
    setState(() {});
    await _persist(
        () => _data.setSurfaceWords(currentStockistUUID, finishName, cur));
  }

  void _removeSurfaceWord(String finishName, String word) {
    if (currentStockistUUID.isEmpty) return;
    _surfWords[finishName]
        ?.removeWhere((w) => w.toLowerCase() == word.toLowerCase());
    setState(() {});
    _persist(() => _data.setSurfaceWords(
        currentStockistUUID, finishName, _surfWords[finishName] ?? const []));
  }

  Future<void> _persist(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Words'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  color: _navy.withValues(alpha: 0.06),
                  child: const Text(
                    'Add YOUR words for each value or finish (e.g. for "Sugar" '
                    'type "Raindrop" then tap Add). Buyers see your words; search '
                    'and imports still group everyone under the standard value.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                    children: [
                      for (var i = 0; i < _attrs.length; i++)
                        _attrCard(_attrs[i],
                            _sectionColors[i % _sectionColors.length]),
                      if (_surfaces.isNotEmpty)
                        _surfaceCard(_sectionColors[
                            _attrs.length % _sectionColors.length]),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _attrCard(DnaAttribute a, Color color) {
    final values =
        a.values.where((v) => v.name.toLowerCase() != 'none').toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Container(width: 6, height: 34, color: color),
        title: Text(a.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Text('${values.length} values',
            style: const TextStyle(fontSize: 11.5)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: [
          for (final v in values)
            _wordRow(
              color: color,
              label: v.name,
              ctrl: _ctrls[v.id]!,
              focus: _focus[v.id]!,
              chips: _words[v.id] ?? const [],
              onAdd: () => _addWord(v.id),
              onRemove: (w) => _removeWord(v.id, w),
            ),
        ],
      ),
    );
  }

  Widget _surfaceCard(Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Container(width: 6, height: 34, color: color),
        title: const Text('Surface / Finish',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Text('${_surfaces.length} finishes',
            style: const TextStyle(fontSize: 11.5)),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        children: [
          for (final s in _surfaces)
            _wordRow(
              color: color,
              label: s.name,
              ctrl: _surfCtrls[s.name]!,
              focus: _surfFocus[s.name]!,
              chips: _surfWords[s.name] ?? const [],
              onAdd: () => _addSurfaceWord(s.name),
              onRemove: (w) => _removeSurfaceWord(s.name, w),
            ),
        ],
      ),
    );
  }

  // One admin value row: solid-colour admin chip (left) | input + Add + the
  // stockist's own removable word chips (right).
  Widget _wordRow({
    required Color color,
    required String label,
    required TextEditingController ctrl,
    required FocusNode focus,
    required List<String> chips,
    required VoidCallback onAdd,
    required void Function(String) onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Admin chip — solid section colour.
            SizedBox(
              width: 92,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(8)),
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
            ),
            const SizedBox(width: 10),
            Container(width: 1, color: Colors.grey.shade300),
            const SizedBox(width: 10),
            // Input + Add, then the stockist's word chips.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          focusNode: focus,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => onAdd(),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'type a word…',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: onAdd,
                        style: FilledButton.styleFrom(
                            backgroundColor: color,
                            visualDensity: VisualDensity.compact,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16)),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: chips
                          .map((w) => Chip(
                                label: Text(w,
                                    style: const TextStyle(
                                        fontSize: 12, color: _navy)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: color.withValues(alpha: 0.10),
                                side: BorderSide(
                                    color: color.withValues(alpha: 0.35)),
                                deleteIconColor: color,
                                onDeleted: () => onRemove(w),
                              ))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
