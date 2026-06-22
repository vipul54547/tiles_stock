import 'package:flutter/material.dart';
import '../../models/dna.dart';
import '../../models/surface_type.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_data_service.dart';

/// "My Words" — the stockist maps their OWN words onto the admin's canonical
/// Design-DNA values. Type words separated by comma / semicolon / new line; a
/// live chip preview shows exactly what's saved. The canonical value stays the
/// hidden search key; these words are what the stockist + their buyer see, and
/// what import matching recognises. (project_design_dna_engine)
class MyDnaWordsScreen extends StatefulWidget {
  const MyDnaWordsScreen({super.key});

  @override
  State<MyDnaWordsScreen> createState() => _MyDnaWordsScreenState();
}

class _MyDnaWordsScreenState extends State<MyDnaWordsScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();

  List<DnaAttribute> _attrs = [];
  final Map<String, TextEditingController> _ctrls = {}; // valueId → controller
  // Surface is admin-controlled (not a DNA attribute), but the stockist maps
  // their OWN words onto each admin finish exactly like a DNA value. Shown as one
  // extra "Surface / Finish" card; words live in surface_aliases (same table the
  // PDF Map-surfaces step writes), so both directions stay in sync.
  List<SurfaceType> _surfaces = [];
  final Map<String, TextEditingController> _surfCtrls = {}; // finishName → ctrl
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
    _ctrls.clear();
    for (final a in attrs) {
      if (a.isFreeText) continue;
      for (final v in a.values) {
        if (v.name.toLowerCase() == 'none') continue;
        _ctrls[v.id] =
            TextEditingController(text: (words[v.id] ?? const []).join(', '));
      }
    }
    for (final c in _surfCtrls.values) {
      c.dispose();
    }
    _surfCtrls.clear();
    // 'None' is the no-surface fallback (isSystem) — it carries no words.
    final finishes =
        surfaces.where((s) => !s.isSystem && s.name.toLowerCase() != 'none');
    for (final s in finishes) {
      _surfCtrls[s.name] = TextEditingController(
          text: (surfWords[s.name] ?? const []).join(', '));
    }
    setState(() {
      _attrs = attrs.where((a) => !a.isFreeText).toList();
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

  Future<void> _save(String valueId) async {
    final words = _parse(_ctrls[valueId]!.text);
    setState(() => _saving = true);
    try {
      await _data.dnaSetValueWords(valueId, words);
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

  void _removeWord(String valueId, String word) {
    final ctrl = _ctrls[valueId]!;
    final words = _parse(ctrl.text)
      ..removeWhere((w) => w.toLowerCase() == word.toLowerCase());
    ctrl.text = words.join(', ');
    setState(() {});
    _save(valueId);
  }

  Future<void> _saveSurface(String finishName) async {
    if (currentStockistUUID.isEmpty) return;
    final words = _parse(_surfCtrls[finishName]!.text);
    setState(() => _saving = true);
    try {
      await _data.setSurfaceWords(currentStockistUUID, finishName, words);
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

  void _removeSurfaceWord(String finishName, String word) {
    final ctrl = _surfCtrls[finishName]!;
    final words = _parse(ctrl.text)
      ..removeWhere((w) => w.toLowerCase() == word.toLowerCase());
    ctrl.text = words.join(', ');
    setState(() {});
    _saveSurface(finishName);
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
                    'type "Raindrop"). Separate with comma, semicolon or new '
                    'line. Buyers see your words; search and imports still group '
                    'everyone under the standard value.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
                    children: [
                      ..._attrs.map(_attrCard),
                      if (_surfaces.isNotEmpty) _surfaceCard(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _attrCard(DnaAttribute a) {
    final values =
        a.values.where((v) => v.name.toLowerCase() != 'none').toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Text(a.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Text('${values.length} values',
            style: const TextStyle(fontSize: 11.5)),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        children: values.map((v) => _valueField(v)).toList(),
      ),
    );
  }

  Widget _valueField(DnaValue v) {
    final ctrl = _ctrls[v.id]!;
    final chips = _parse(ctrl.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v.name,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
          const SizedBox(height: 4),
          Focus(
            onFocusChange: (has) {
              if (!has) _save(v.id); // persist when leaving the field
            },
            child: TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 2,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}), // refresh live chips
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'your words, comma separated',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: chips
                  .map((w) => Chip(
                        label: Text(w, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onDeleted: () => _removeWord(v.id, w),
                        backgroundColor: _navy.withValues(alpha: 0.07),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  // Surface = admin finishes (the label) + the stockist's own words (chips) that
  // map to each. Same UI as a DNA attribute card; reads/writes surface_aliases.
  Widget _surfaceCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: const Text('Surface / Finish',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Text('${_surfaces.length} finishes',
            style: const TextStyle(fontSize: 11.5)),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        children: _surfaces.map((s) => _surfaceField(s.name)).toList(),
      ),
    );
  }

  Widget _surfaceField(String finishName) {
    final ctrl = _surfCtrls[finishName]!;
    final chips = _parse(ctrl.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(finishName,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
          const SizedBox(height: 4),
          Focus(
            onFocusChange: (has) {
              if (!has) _saveSurface(finishName); // persist when leaving
            },
            child: TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 2,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}), // refresh live chips
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'your words, comma separated',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: chips
                  .map((w) => Chip(
                        label: Text(w, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onDeleted: () => _removeSurfaceWord(finishName, w),
                        backgroundColor: _navy.withValues(alpha: 0.07),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
