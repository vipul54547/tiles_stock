import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/dna.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/platform_kind.dart';

/// 🖼️ MY ARTWORKS — `print_master`, and its IMAGE DNA.
///
/// The Design Library's twin, one level up:
///
///     My Design Library   a TILE   → surface · body · packing · covers
///     My Artworks         a PRINT  → Look Type ▸ Natural Name · Print Type · Design Joint · Colour
///
/// An ARTWORK is **size + name + image**. Nothing else. It is what a folder import makes, and it is
/// the top of the identity chain — every tile ever cut from it inherits its name, its size, its
/// photo and this DNA. Tag `1001` once and its Matt, Carving and GHR all carry it; there is no way
/// for one of them to be "white marble, bookmatch" while another is something else. Same picture,
/// same DNA.
///
/// 🔑 The four attributes here are exactly those with `dna_attributes.scope = 'print'`. They are
/// **mapped straight from this page** — no dialog, no drilling in — because tagging a few hundred
/// freshly-imported artworks is a job you do in one pass.
///
/// 🚫 No surface, no body, no packing, no brand. A picture is not made of anything and is not
/// packed. Those belong to a DESIGN, which he cuts from the artwork in the Library.
class MyArtworksScreen extends StatefulWidget {
  const MyArtworksScreen({super.key});
  @override
  State<MyArtworksScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);
const _dnaGold = Color(0xFFB9770E);

class _State extends State<MyArtworksScreen> {
  final _data = SupabaseDataService();

  List<Map<String, dynamic>> _artworks = [];

  /// The IMAGE DNA attributes, parent-first so the cascade reads top-down (Look Type, then its
  /// child Natural Name).
  List<DnaAttribute> _attrs = [];

  bool _loading = true;
  String _query = '';
  /// Show only the artworks with no design cut from them yet — the ones waiting for him.
  bool _onlyUntouched = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final artworks = await _data.myArtworks();
    final catalog = await _data.dnaCatalog();
    if (!mounted) return;

    // Only the IMAGE DNA. Everything else describes the TILE (Punch, Application, Series) and has
    // no meaning against a picture — the server refuses it too.
    final image = catalog.where((a) => a.isPrintDna).toList();
    // A child right after its parent: Natural Name sits under Look Type.
    double key(DnaAttribute a) => a.parentAttributeId == null
        ? a.sortOrder.toDouble()
        : (image
                    .where((z) => z.id == a.parentAttributeId)
                    .map((z) => z.sortOrder)
                    .firstOrNull ??
                a.sortOrder) +
            0.5;
    image.sort((x, y) => key(x).compareTo(key(y)));

    setState(() {
      _artworks = artworks;
      _attrs = image;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    return _artworks.where((a) {
      if (_onlyUntouched && ((a['tiles'] as num?)?.toInt() ?? 0) > 0) {
        return false;
      }
      if (q.isEmpty) return true;
      return (a['name'] ?? '').toString().toLowerCase().contains(q);
    }).toList();
  }

  void _snack(String m, {bool error = false}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(m),
            backgroundColor: error ? Colors.red : const Color(0xFF2E7D32)));

  /// The value ids this artwork currently carries for [attr].
  List<String> _tagged(Map<String, dynamic> a, DnaAttribute attr) {
    final dna = Map<String, dynamic>.from((a['dna'] as Map?) ?? const {});
    final v = dna[attr.id];
    return [for (final x in (v as List?) ?? const []) x.toString()];
  }

  /// Map an attribute straight from the card. Writes to the PRINT — no tile needed, which matters
  /// because a freshly imported artwork has none.
  Future<void> _set(
      Map<String, dynamic> a, DnaAttribute attr, List<String> valueIds) async {
    try {
      await _data.printDnaSet(
          printId: (a['print_id'] ?? '').toString(),
          attributeId: attr.id,
          valueIds: valueIds);
      await _load();
    } catch (e) {
      // "Pick the parent value first" lands here — Natural Name before its Look Type.
      if (mounted) _snack('$e', error: true);
    }
  }

  /// The values of [attr] that are legal right now. A CHILD attribute is scoped to the parent value
  /// the artwork already carries: pick Look Type = Marble, and Natural Name offers only marbles.
  List<DnaValue> _optionsFor(Map<String, dynamic> a, DnaAttribute attr) {
    final all = attr.values.where((v) => v.name.toLowerCase() != 'none').toList();
    if (attr.parentAttributeId == null) return all;

    final parent =
        _attrs.where((x) => x.id == attr.parentAttributeId).firstOrNull;
    if (parent == null) return all;
    final parentValues = _tagged(a, parent).toSet();
    if (parentValues.isEmpty) return const [];
    return all
        .where((v) =>
            v.parentValueId == null || parentValues.contains(v.parentValueId))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FB),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('My Artworks'),
        actions: [
          if (isWindowsDesktop)
            IconButton(
              icon: const Icon(Icons.drive_folder_upload_outlined),
              tooltip: 'Import artworks from a folder',
              onPressed: () async {
                await context.push<bool>('/stockist/library/import-images');
                _load();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _searchBar(list.length),
                Expanded(
                  child: list.isEmpty
                      ? _empty()
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(12, 4, 12,
                              24 + MediaQuery.viewPaddingOf(context).bottom),
                          itemCount: list.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, i) => _card(list[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 46, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                _artworks.isEmpty
                    ? 'No artworks yet.\nImport a folder — the folder is the size, the filename is '
                        'the name, the file is the picture.'
                    : 'None match.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _searchBar(int shown) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by artwork name…',
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Colors.grey.shade300)),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Text('$shown of ${_artworks.length} artworks',
                  style: const TextStyle(fontSize: 11.5, color: Colors.grey)),
              const Spacer(),
              FilterChip(
                label: const Text('No design yet',
                    style: TextStyle(fontSize: 11.5)),
                selected: _onlyUntouched,
                visualDensity: VisualDensity.compact,
                onSelected: (v) => setState(() => _onlyUntouched = v),
              ),
            ]),
          ],
        ),
      );

  Widget _card(Map<String, dynamic> a) {
    final name = (a['name'] ?? '').toString();
    final size = (a['size'] ?? '').toString();
    final img = (a['image_url'] ?? '').toString();
    final tiles = (a['tiles'] as num?)?.toInt() ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64,
                height: 64,
                child: img.isEmpty
                    ? Container(
                        color: Colors.grey.shade100,
                        child: Icon(Icons.image_outlined,
                            color: Colors.grey.shade400))
                    : CachedNetworkImage(
                        imageUrl: CloudinaryService.thumbUrl(img, width: 180),
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade200),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade200)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    // 0 designs is HONEST, not broken: he has the picture and has not yet said
                    // what he sells from it.
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: tiles == 0
                            ? Colors.orange.withValues(alpha: 0.12)
                            : _navy.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                          tiles == 0
                              ? 'no design yet'
                              : '$tiles design${tiles == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: tiles == 0
                                  ? Colors.orange.shade900
                                  : _navy)),
                    ),
                  ]),
                  const SizedBox(height: 1),
                  Text(size.replaceAll(' mm', ''),
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 8),
                  // 🧬 THE IMAGE DNA — mapped straight from here.
                  for (final attr in _attrs) _attrRow(a, attr),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One attribute, mapped in place. Multi-value (Colour) is check-chips; single-value is a
  /// dropdown. A CHILD is greyed out until its parent is picked — that is the cascade, and the
  /// server enforces it too ("pick the parent value first").
  Widget _attrRow(Map<String, dynamic> a, DnaAttribute attr) {
    final options = _optionsFor(a, attr);
    final tagged = _tagged(a, attr);
    final blockedByParent = attr.parentAttributeId != null && options.isEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text('${attr.name}:',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade600)),
            ),
          ),
          Expanded(
            child: blockedByParent
                ? Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text('pick a ${_parentName(attr)} first',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade400)),
                  )
                : attr.isMulti
                    ? Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: [
                          for (final v in options)
                            FilterChip(
                              label: Text(v.name,
                                  style: const TextStyle(fontSize: 11)),
                              selected: tagged.contains(v.id),
                              visualDensity: VisualDensity.compact,
                              showCheckmark: true,
                              selectedColor: _dnaGold.withValues(alpha: 0.18),
                              onSelected: (on) {
                                final next = [...tagged];
                                on ? next.add(v.id) : next.remove(v.id);
                                _set(a, attr, next);
                              },
                            ),
                        ],
                      )
                    : DropdownButtonFormField<String>(
                        initialValue: tagged.isEmpty ? null : tagged.first,
                        isExpanded: true,
                        isDense: true,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6)),
                          hintText: '—',
                          hintStyle: TextStyle(
                              fontSize: 12, color: Colors.grey.shade400),
                        ),
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.black87),
                        items: [
                          for (final v in options)
                            DropdownMenuItem(value: v.id, child: Text(v.name)),
                        ],
                        onChanged: (v) => _set(a, attr, v == null ? [] : [v]),
                      ),
          ),
        ],
      ),
    );
  }

  String _parentName(DnaAttribute attr) =>
      _attrs
          .where((x) => x.id == attr.parentAttributeId)
          .map((x) => x.name)
          .firstOrNull ??
      'parent';
}
