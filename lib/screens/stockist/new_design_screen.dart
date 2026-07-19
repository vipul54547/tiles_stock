import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/brand.dart';
import '../../models/dna.dart';
import '../../models/library_entry.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/tile_types.dart';
import '../../utils/body_colour.dart';

const _navy = Color(0xFF1B4F72);
const _dnaGold = Color(0xFFB9770E);

/// 🧱 NEW DESIGN — the whole design on ONE page.
///
/// A design is cut from an artwork: it is that picture in a **surface**, made of a **body**, packed
/// a certain way (**pieces + weight → thickness**), described by its **DNA**, and stamped by each
/// brand's **cover**. This page collects all of it and saves it in one go, so the design is born
/// complete. The artwork's own image DNA (Look Type ▸ Natural Name · Design Joint · Print Type ·
/// Colour) is editable here too — it belongs to the picture, so every design inherits it.
class NewDesignScreen extends StatefulWidget {
  final Map<String, dynamic> artwork;

  /// When set, the page is in EDIT mode: it pre-fills from this design and saves via UPDATE paths
  /// (not tile_add). The artwork is read-only; the identity fields lock once the design has stock.
  final LibraryEntry? existing;
  const NewDesignScreen({super.key, required this.artwork, this.existing});
  @override
  State<NewDesignScreen> createState() => _NewDesignScreenState();
}

class _NewDesignScreenState extends State<NewDesignScreen> {
  final _data = SupabaseDataService();

  bool _loading = true;
  bool _saving = false;

  List<({String label, String canonical})> _surfaces = [];
  List<Brand> _brands = [];

  // Artwork (print) image DNA, parent-first. attrId -> selected valueIds.
  List<DnaAttribute> _imageDna = [];
  final Map<String, List<String>> _printDna = {};
  bool _showImageDna = false;

  // Identity + packing.
  ({String label, String canonical})? _surface;
  String? _body;
  final _piecesCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();

  // Per-design DNA.
  DnaAttribute? _punchAttr, _punchTypeAttr, _applicationAttr, _seriesAttr;
  String? _punchId, _punchTypeId, _applicationId;
  String? _punchDetail; // the leaf word tied to the picked Punch Type value
  String _series = 'Regular';

  // 🎨 Body colour — IDENTITY for a Full/Colour Body. The stockist's reusable palette + the pick.
  List<Map<String, dynamic>> _palette = [];
  String? _bodyColourId;
  Map<String, dynamic>? get _bodyColour =>
      _palette.where((c) => c['id'] == _bodyColourId).firstOrNull;
  bool get _needsBodyColour => _body != null && bodyHasColour(_body!);

  bool get _isEdit => widget.existing != null;
  // Identity (surface · body · body colour) is locked once the design holds stock — changing it
  // would move the product and strand that stock.
  bool get _idLocked => (widget.existing?.held ?? 0) > 0;

  // valueId -> name, across every DNA attribute — for the at-a-glance chains + covers context.
  final Map<String, String> _valueName = {};

  // Covers: the default brand carries the company name; more brands are added on demand.
  final _defaultCoverCtrl = TextEditingController();
  final List<({String? brandId, TextEditingController ctrl})> _extraCovers = [];

  String get _printId => (widget.artwork['print_id'] ?? '').toString();
  String get _artName => (widget.artwork['name'] ?? '').toString();
  String get _size => (widget.artwork['size'] ?? '').toString();

  Brand? get _defaultBrand => _brands.isEmpty
      ? null
      : _brands.firstWhere((b) => b.isDefault, orElse: () => _brands.first);

  @override
  void initState() {
    super.initState();
    if (!_isEdit) _defaultCoverCtrl.text = _artName; // create: pre-fill, editable
    _load();
  }

  @override
  void dispose() {
    _piecesCtrl.dispose();
    _weightCtrl.dispose();
    _defaultCoverCtrl.dispose();
    for (final c in _extraCovers) {
      c.ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _data.getMySurfaceOptions(),
      _data.getMyBrands(),
      _data.dnaCatalog(),
      _data.myBodyColours(),
    ]);
    if (!mounted) return;
    final surfaces = results[0] as List<({String label, String canonical})>;
    final palette = results[3] as List<Map<String, dynamic>>;
    final brands = (results[1] as List<Brand>).toList()
      ..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    final catalog = results[2] as List<DnaAttribute>;

    // Image DNA (scope=print), parent-first so Natural Name sits under Look Type.
    final image = catalog.where((a) => a.isPrintDna).toList();
    double key(DnaAttribute a) => a.parentAttributeId == null
        ? a.sortOrder.toDouble()
        : (image
                    .where((z) => z.id == a.parentAttributeId)
                    .map((z) => z.sortOrder)
                    .firstOrNull ??
                a.sortOrder) +
            0.5;
    image.sort((x, y) => key(x).compareTo(key(y)));

    // Pre-populate the print's existing image DNA.
    final dna = Map<String, dynamic>.from((widget.artwork['dna'] as Map?) ?? const {});
    for (final e in dna.entries) {
      _printDna[e.key] = [for (final v in (e.value as List?) ?? const []) v.toString()];
    }

    // A flat valueId -> name map for the summaries.
    for (final a in catalog) {
      for (final v in a.values) {
        _valueName[v.id] = v.name;
      }
    }

    DnaAttribute? named(String n) =>
        catalog.where((x) => x.scope == 'product' && x.name == n).firstOrNull;
    final punchA = named('Punch');
    final punchTypeA = named('Punch Type');
    final appA = named('Application');
    final seriesA = named('Series');

    // ── EDIT MODE prefill ──
    Map<String, List<DnaValue>> designDna = {};
    if (_isEdit) {
      designDna = await _data.dnaForDesign(widget.existing!.id);
      if (!mounted) return;
    }

    setState(() {
      _surfaces = surfaces;
      _brands = brands;
      _palette = palette;
      _imageDna = image;
      _punchAttr = punchA;
      _punchTypeAttr = punchTypeA;
      _applicationAttr = appA;
      _seriesAttr = seriesA;

      if (_isEdit) {
        final e = widget.existing!;
        // Identity.
        _surface = surfaces
            .where((s) =>
                s.canonical.toLowerCase() == e.surfaceType.trim().toLowerCase())
            .firstOrNull;
        _body = e.tileType.trim().isEmpty ? null : e.tileType.trim();
        _bodyColourId = e.bodyColour?['id']?.toString();
        if (_bodyColourId != null &&
            !palette.any((c) => c['id'] == _bodyColourId) &&
            e.bodyColour != null) {
          _palette = [...palette, e.bodyColour!];
        }
        // Packing (first).
        if (e.packings.isNotEmpty) {
          _piecesCtrl.text = e.packings.first.pieces.toString();
          _weightCtrl.text = _trim(e.packings.first.weightKg);
        }
        // Per-design DNA.
        List<DnaValue>? vals(DnaAttribute? a) =>
            a == null ? null : designDna[a.id];
        _punchId = vals(punchA)?.firstOrNull?.id;
        // Punch Type: the primary value (parent = a Punch value), and its detail word (parent = a
        // Punch Type value).
        final ptVals = vals(punchTypeA) ?? const <DnaValue>[];
        final ownPt = punchTypeA?.values.map((v) => v.id).toSet() ?? {};
        for (final v in ptVals) {
          if (v.parentValueId != null && ownPt.contains(v.parentValueId)) {
            _punchDetail = v.name; // a leaf detail
          } else {
            _punchTypeId = v.id; // the primary Punch Type value
          }
        }
        _applicationId = vals(appA)?.firstOrNull?.id;
        final s = vals(seriesA)?.firstOrNull?.name;
        if (s != null && s.isNotEmpty) _series = s;
        // Covers.
        final def = _defaultBrand;
        e.aliases.forEach((bid, word) {
          if (def != null && bid == def.id) {
            _defaultCoverCtrl.text = word;
          } else {
            _extraCovers
                .add((brandId: bid, ctrl: TextEditingController(text: word)));
          }
        });
      }
      _loading = false;
    });
  }

  void _snack(String m, {bool error = false}) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(m),
        backgroundColor: error ? Colors.red : const Color(0xFF2E7D32)));

  List<DnaValue> _live(DnaAttribute? a) => a == null
      ? const []
      : a.values.where((v) => v.name.toLowerCase() != 'none').toList();

  String? get _thicknessLabel {
    final pieces = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
    final weight = double.tryParse(_weightCtrl.text.trim()) ?? 0;
    if (_body == null || pieces <= 0 || weight <= 0) return null;
    return thicknessRangeLabel(_size, pieces, weight, _body!);
  }

  /// How many faces the artwork carries: its own image (Faces-1) + the extras.
  int get _facesCount {
    final hasImg =
        (widget.artwork['image_url'] ?? '').toString().trim().isNotEmpty;
    final extras = (widget.artwork['faces'] as List?)?.length ?? 0;
    return (hasImg ? 1 : 0) + extras;
  }

  String? _valOf(String? id) => id == null ? null : _valueName[id];

  /// The image DNA a print carries, as PARENT ▸ CHILD chains (Look Type ▸ Natural Name), with a
  /// multi-value attribute (Colour) joined. One string per top-level attribute that has a value.
  List<String> get _imageDnaChips {
    final out = <String>[];
    for (final a in _imageDna.where((x) => x.parentAttributeId == null)) {
      final ids = _printDna[a.id] ?? const [];
      if (ids.isEmpty) continue;
      var chain = a.isMulti
          ? ids.map(_valOf).whereType<String>().join(', ')
          : (_valOf(ids.first) ?? '');
      if (chain.isEmpty) continue;
      // Append the one child (e.g. Natural Name under Look Type), if tagged.
      for (final c in _imageDna.where((x) => x.parentAttributeId == a.id)) {
        final cid = _printDna[c.id] ?? const [];
        if (cid.isNotEmpty) {
          final cn = _valOf(cid.first);
          if (cn != null && cn.isNotEmpty) chain = '$chain ▸ $cn';
        }
      }
      out.add(chain);
    }
    return out;
  }

  /// The punch chain for the covers context: Punch ▸ Punch Type ▸ detail.
  String? get _punchChain {
    final p = _valOf(_punchId);
    if (p == null) return null;
    final t = _valOf(_punchTypeId);
    final d = (_punchDetail ?? '').trim();
    return [p, if (t != null) t, if (d.isNotEmpty) d].join(' ▸ ');
  }

  // ── save ────────────────────────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    final pieces = int.tryParse(_piecesCtrl.text.trim()) ?? 0;
    final weight = double.tryParse(_weightCtrl.text.trim()) ?? 0;
    if (_surface == null) {
      _snack('Pick a surface — every design has one.', error: true);
      return;
    }
    if (_body == null) {
      _snack('Say what it is made of (the body).', error: true);
      return;
    }
    if (pieces <= 0 || weight <= 0) {
      _snack('Enter the pieces per box and the box weight.', error: true);
      return;
    }
    if (_needsBodyColour && _bodyColourId == null) {
      _snack('Pick a body colour — a Full Body / Colour Body is told apart by it.',
          error: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final String libId;
      if (_isEdit) {
        libId = widget.existing!.id;
        // Identity edits — only when the design holds no stock (else it is locked).
        if (!_idLocked) {
          final e = widget.existing!;
          if (_surface!.canonical.toLowerCase() !=
              e.surfaceType.trim().toLowerCase()) {
            await _data.setLibrarySurface(libId, _surface!.canonical,
                label: _surface!.label);
          }
          final newBcid = _needsBodyColour ? _bodyColourId : null;
          final oldBcid = e.bodyColour?['id']?.toString();
          if (e.tileType.trim() != (_body ?? '') || oldBcid != newBcid) {
            await _data.librarySetBody(libId, _body, newBcid);
          }
        }
      } else {
        // Create — the artwork's image DNA (the print's), then the tile itself.
        for (final a in _imageDna) {
          await _data.printDnaSet(
              printId: _printId,
              attributeId: a.id,
              valueIds: _printDna[a.id] ?? const []);
        }
        // Body colour is IDENTITY, so it goes INTO tile_add (it makes the product).
        libId = await _data.tileAdd(
            printId: _printId,
            surface: _surface!.canonical,
            tileType: _body,
            bodyColourId: _needsBodyColour ? _bodyColourId : null);
        if (libId.isEmpty) throw 'Could not create the design.';
      }

      // Packing — skip when editing and it is unchanged.
      final oldPk = _isEdit && widget.existing!.packings.isNotEmpty
          ? widget.existing!.packings.first
          : null;
      if (oldPk == null ||
          oldPk.pieces != pieces ||
          (oldPk.weightKg - weight).abs() > 0.001) {
        await _data.packingAdd(libraryId: libId, pieces: pieces, weightKg: weight);
      }

      // Per-design DNA — set OR clear the current selection.
      if (_punchAttr != null) {
        await _data.dnaSetDesign(
            libId, _punchAttr!.id, _punchId != null ? [_punchId!] : []);
        if (_punchTypeAttr != null) {
          await _data.dnaSetDesign(libId, _punchTypeAttr!.id,
              _punchTypeId != null ? [_punchTypeId!] : []);
          if (_punchTypeId != null) {
            final leaf = (_punchDetail ?? '').trim();
            if (leaf.isNotEmpty) {
              await _data.dnaSetValueDetail(libId, _punchTypeId!, [leaf]);
            }
          }
        }
      }
      if (_applicationAttr != null) {
        await _data.dnaSetDesign(libId, _applicationAttr!.id,
            _applicationId != null ? [_applicationId!] : []);
      }
      if (_seriesAttr != null) {
        await _data.dnaSetDesignText(libId, _seriesAttr!.id,
            _series.trim().isNotEmpty ? [_series.trim()] : []);
      }

      // Covers — each brand + the word it stamps = a BOX.
      if (_defaultBrand != null && _defaultCoverCtrl.text.trim().isNotEmpty) {
        await _data.coverNameSet(
            libraryId: libId,
            brandId: _defaultBrand!.id,
            name: _defaultCoverCtrl.text.trim());
      }
      for (final c in _extraCovers) {
        final bid = c.brandId;
        final word = c.ctrl.text.trim();
        if (bid != null && word.isNotEmpty) {
          await _data.coverNameSet(libraryId: libId, brandId: bid, name: word);
        }
      }

      if (!mounted) return;
      _snack(_isEdit ? 'Design updated.' : 'Design added.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF2F5),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: Text(_isEdit ? 'Edit Design' : 'New Design'),
      ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(backgroundColor: _navy),
                      child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save changes' : 'Save design')),
                    ),
                  ],
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
              children: [
                _artworkCard(),
                _designCard(),
                _packingCard(),
                _dnaCard(),
                _coversCard(),
              ],
            ),
    );
  }

  // ── cards ─────────────────────────────────────────────────────────────────────────────────
  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _secHeader(String n, String title, [String? sub]) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                  radius: 11,
                  backgroundColor: _navy,
                  child: Text(n,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white))),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
            if (sub != null)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 2),
                child: Text(sub,
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600)),
              ),
          ],
        ),
      );

  Widget _artworkCard() {
    final img = (widget.artwork['image_url'] ?? '').toString();
    return _card([
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 84,
            height: 84,
            child: img.isEmpty
                ? Container(
                    color: Colors.grey.shade100,
                    child:
                        Icon(Icons.image_outlined, color: Colors.grey.shade400))
                : CachedNetworkImage(
                    imageUrl: CloudinaryService.thumbUrl(img, width: 220),
                    fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_artName,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w800)),
              Row(children: [
                Text(_size.replaceAll(' mm', ''),
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
                if (_facesCount > 1) ...[
                  Text('  ·  ',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade400)),
                  Text('🖼 $_facesCount faces',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _navy)),
                ],
              ]),
              const SizedBox(height: 8),
              InkWell(
                onTap: _isEdit
                    ? null
                    : () => setState(() => _showImageDna = !_showImageDna),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_isEdit ? '🔒 ' : '🧬 ',
                      style: const TextStyle(fontSize: 12)),
                  Text(
                      _isEdit
                          ? 'Artwork DNA · manage in My Artworks'
                          : 'Artwork DNA (optional)',
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: _dnaGold,
                          fontWeight: FontWeight.w700)),
                  if (!_isEdit)
                    Icon(_showImageDna ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: _dnaGold),
                ]),
              ),
              // The chosen image DNA at a glance, as PARENT ▸ CHILD chains (always in edit).
              if ((_isEdit || !_showImageDna) && _imageDnaChips.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final chain in _imageDnaChips)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _dnaGold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(chain,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.brown.shade800)),
                      ),
                  ]),
                ),
            ],
          ),
        ),
      ]),
      if (!_isEdit && _showImageDna) ...[
        const SizedBox(height: 8),
        Text('Describes the ARTWORK — every design of it inherits this.',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        for (final attr in _imageDna) _imageDnaField(attr),
      ],
    ]);
  }

  Widget _designCard() => _card([
        _secHeader('1', 'The design',
            'A design is the artwork in a surface, made of something.'),
        // 🔒 Identity locks once the design holds stock — changing it would strand that stock.
        if (_idLocked)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            decoration: BoxDecoration(
              color: const Color(0xFFFCF3E2),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFE3C88A)),
            ),
            child: Text(
              '🔒 This design holds ${widget.existing!.held} boxes of stock, so its identity '
              '(surface · body · body colour) is locked. Clear the stock to change it.',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF8A6D3B)),
            ),
          ),
        DropdownButtonFormField<({String label, String canonical})>(
          initialValue: _surface,
          isExpanded: true,
          decoration: _dec('Surface *'),
          items: [
            for (final o in _surfaces)
              DropdownMenuItem(
                  value: o,
                  child: Text(o.label.trim().toLowerCase() ==
                          o.canonical.trim().toLowerCase()
                      ? o.canonical
                      : '${o.label} (${o.canonical})'))
          ],
          onChanged: (_saving || _idLocked)
              ? null
              : (v) => setState(() => _surface = v),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _body,
          isExpanded: true,
          decoration: _dec('Made of (body) *'),
          items: [
            for (final t in tileTypeNames)
              DropdownMenuItem(value: t, child: Text(t))
          ],
          onChanged: (_saving || _idLocked)
              ? null
              : (v) => setState(() {
                    _body = v;
                    if (!_needsBodyColour) _bodyColourId = null;
                  }),
        ),
        // 🎨 Body colour is IDENTITY for a Full/Colour Body — compulsory, and it splits products.
        if (_needsBodyColour) ...[
          const SizedBox(height: 12),
          Text('Body colour *',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .5,
                  color: Colors.grey.shade600)),
          const SizedBox(height: 5),
          _bodyColourField(),
          const SizedBox(height: 4),
          Text(
            'Required for Full Body / Colour Body — same print & surface, a different body '
            'colour is a DIFFERENT product.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ]);

  Widget _bodyColourField() {
    final bc = _bodyColour;
    return InkWell(
      onTap: (_saving || _idLocked) ? null : _pickBodyColour,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(
              color: bc == null ? Colors.red.shade300 : Colors.grey.shade400),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          if (bc == null)
            Text('Pick or create a body colour…',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade500))
          else ...[
            _swatch(bc, 30),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((bc['name'] ?? '').toString(),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  Text(_labText(bc),
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ],
          Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
        ]),
      ),
    );
  }

  Widget _packingCard() {
    final band = _thicknessLabel;
    return _card([
      _secHeader('2', 'Packing',
          'Read the pieces and weight off the box — the thickness follows.'),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _piecesCtrl,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: _dec('Pieces per box *'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _weightCtrl,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: _dec('Box weight (kg) *'),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Icon(Icons.straighten, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            band == null
                ? 'Thickness — fill body, pieces and weight'
                : 'Thickness $band  (worked out from the box)',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: band == null ? Colors.grey.shade600 : _navy),
          ),
        ),
      ]),
    ]);
  }

  Widget _dnaCard() {
    final punchTypeOpts = (_punchTypeAttr == null || _punchId == null)
        ? const <DnaValue>[]
        : _punchTypeAttr!.values
            .where((v) =>
                v.parentValueId == _punchId && v.name.toLowerCase() != 'none')
            .toList();
    return _card([
      _secHeader('3', 'Describe this design',
          'All optional — these belong to THIS design.'),
      _valueDrop(_punchAttr, _punchId, _live(_punchAttr), (v) {
        setState(() {
          _punchId = v;
          _punchTypeId = null;
          _punchDetail = null;
        });
      }),
      if (_punchId != null)
        _valueDrop(_punchTypeAttr, _punchTypeId, punchTypeOpts, (v) {
          setState(() {
            _punchTypeId = v;
            _punchDetail = null;
          });
        }),
      // The free-text LEAF: pick / add / edit / delete a word under this Punch Type.
      if (_punchTypeId != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _freeTextField(
            label: 'Punch Type detail — pick, add, edit or delete',
            value: _punchDetail,
            onTap: () async {
              final r = await _pickFreeText(
                title: 'Punch Type detail',
                valuesOf: () => (_punchTypeAttr?.values ?? const <DnaValue>[])
                    .where((v) => v.parentValueId == _punchTypeId)
                    .toList(),
                current: _punchDetail,
                allowNone: true,
              );
              if (r == null || !mounted) return;
              if (r == '__new__') {
                final w = await _promptText('New Punch Type detail');
                if (w != null && w.isNotEmpty) setState(() => _punchDetail = w);
              } else {
                setState(() => _punchDetail = r.isEmpty ? null : r);
              }
            },
          ),
        ),
      const SizedBox(height: 12),
      _valueDrop(_applicationAttr, _applicationId, _live(_applicationAttr),
          (v) => setState(() => _applicationId = v)),
      // Series — pick / add / edit / delete; defaults to Regular, never None.
      if (_seriesAttr != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _freeTextField(
            label: 'Series — pick, add, edit or delete',
            value: _series,
            onTap: () async {
              final r = await _pickFreeText(
                title: 'Series',
                valuesOf: () => _live(_seriesAttr),
                current: _series,
                allowNone: false,
              );
              if (r == null || !mounted) return;
              if (r == '__new__') {
                final w = await _promptText('New series');
                if (w != null && w.isNotEmpty) setState(() => _series = w);
              } else if (r.isNotEmpty) {
                setState(() => _series = r);
              }
            },
          ),
        ),
      // Body colour is NOT here — it is IDENTITY, so it lives in §1 (The design).
    ]);
  }

  Widget _freeTextField(
      {required String label,
      required String? value,
      required VoidCallback onTap}) {
    final empty = value == null || value.isEmpty;
    return InkWell(
      onTap: _saving ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: _dec(label),
        child: Row(children: [
          Expanded(
            child: Text(empty ? '— None —' : value,
                style: TextStyle(
                    fontSize: 14,
                    color: empty ? Colors.grey.shade500 : Colors.black87)),
          ),
          Icon(Icons.arrow_drop_down, color: Colors.grey.shade600),
        ]),
      ),
    );
  }

  /// Refresh the product-DNA attributes after a value was renamed/deleted.
  Future<void> _reloadCatalog() async {
    final catalog = await _data.dnaCatalog();
    if (!mounted) return;
    DnaAttribute? named(String n) =>
        catalog.where((x) => x.scope == 'product' && x.name == n).firstOrNull;
    setState(() {
      _punchAttr = named('Punch');
      _punchTypeAttr = named('Punch Type');
      _applicationAttr = named('Application');
      _seriesAttr = named('Series');
      for (final a in catalog) {
        for (final v in a.values) {
          _valueName[v.id] = v.name;
        }
      }
    });
  }

  /// A free-text picker sheet: choose a value, or EDIT / DELETE the stockist's OWN values, or create
  /// new. Returns the chosen name, '' for None, '__new__' to create, or null on dismiss.
  Future<String?> _pickFreeText({
    required String title,
    required List<DnaValue> Function() valuesOf,
    required String? current,
    bool allowNone = true,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final values = valuesOf()
            .where((v) => v.name.toLowerCase() != 'none')
            .toList();
        return SafeArea(
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(title,
                  style:
                      const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            if (allowNone)
              ListTile(
                leading: Icon(
                    (current == null || current.isEmpty)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: (current == null || current.isEmpty)
                        ? _navy
                        : Colors.grey),
                title: const Text('— None —'),
                onTap: () => Navigator.pop(ctx, ''),
              ),
            for (final v in values)
              ListTile(
                leading: Icon(
                    current == v.name
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: current == v.name ? _navy : Colors.grey),
                title: Text(v.name),
                trailing: v.isOwn
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 19),
                          tooltip: 'Rename',
                          onPressed: () async {
                            final w = await _promptText('Rename "${v.name}"');
                            if (w == null || w.isEmpty) return;
                            try {
                              await _data.dnaRenameMyValue(v.id, w);
                              await _reloadCatalog();
                              setSheet(() {});
                            } catch (e) {
                              if (mounted) _snack('$e', error: true);
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 19, color: Colors.red),
                          tooltip: 'Delete',
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                title: const Text('Delete value?'),
                                content: Text('Remove "${v.name}" from your list?'),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(c, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('Delete',
                                          style: TextStyle(color: Colors.red))),
                                ],
                              ),
                            );
                            if (ok != true) return;
                            try {
                              await _data.dnaDeleteMyValue(v.id);
                              await _reloadCatalog();
                              setSheet(() {});
                            } catch (e) {
                              if (mounted) _snack('$e', error: true);
                            }
                          },
                        ),
                      ])
                    : null,
                onTap: () => Navigator.pop(ctx, v.name),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: _navy),
              title: const Text('Create new…',
                  style: TextStyle(color: _navy, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
          ]),
        );
      }),
    );
  }

  Widget _coversCard() {
    final def = _defaultBrand;
    final used = <String>{
      if (def != null) def.id,
      for (final c in _extraCovers)
        if (c.brandId != null) c.brandId!,
    };
    final available = _brands.where((b) => !used.contains(b.id)).toList();

    return _card([
      _secHeader('4', 'Covers · what each brand prints',
          'A cover on the packing is a BOX. The factory\'s word — 1001 on FAMOUS, 601001 on ANUJ.'),
      _coverContext(),
      if (def != null) ...[
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: _dnaGold.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: _dnaGold.withValues(alpha: 0.28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('COMPANY DESIGN NAME · DEFAULT BRAND',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _dnaGold,
                      letterSpacing: .4)),
              const SizedBox(height: 8),
              Row(children: [
                _brandPill(def.name, gold: true),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _defaultCoverCtrl,
                    enabled: !_saving,
                    decoration: _dec(null)
                        .copyWith(hintText: 'word on this brand\'s cover'),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Pre-filled with the artwork name — edit it if this brand '
                  'stamps something else.',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
      for (int i = 0; i < _extraCovers.length; i++) _coverRow(i, available),
      const SizedBox(height: 2),
      OutlinedButton.icon(
        onPressed: (_saving || available.isEmpty)
            ? null
            : () => setState(() => _extraCovers
                .add((brandId: null, ctrl: TextEditingController()))),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add brand'),
        style: OutlinedButton.styleFrom(foregroundColor: _navy),
      ),
    ]);
  }

  /// The whole design at a glance, so he can see what he is naming while giving each cover word.
  Widget _coverContext() {
    final joint = () {
      final dj = _imageDna.where((a) => a.name == 'Design Joint').firstOrNull;
      if (dj == null) return null;
      final ids = _printDna[dj.id] ?? const [];
      return ids.isEmpty ? null : _valOf(ids.first);
    }();
    final facts = <({String k, String v})>[
      (k: 'Artwork', v: _artName),
      (k: 'Size', v: _size.replaceAll(' mm', '')),
      if (_surface != null) (k: 'Surface', v: _surface!.label),
      if (_body != null) (k: 'Body', v: _body!),
      if (_bodyColour != null)
        (k: 'Body colour', v: (_bodyColour!['name'] ?? '').toString()),
      if (joint != null) (k: 'Joint', v: joint),
      if (_thicknessLabel != null) (k: 'Thickness', v: _thicknessLabel!),
      if (_punchChain != null) (k: 'Punch', v: _punchChain!),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F8FA),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('YOU\'RE NAMING THIS DESIGN',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: .4,
                color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 5, children: [
          for (final f in facts)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Text.rich(TextSpan(children: [
                TextSpan(
                    text: '${f.k} ',
                    style: TextStyle(
                        fontSize: 10.5, color: Colors.grey.shade600)),
                TextSpan(
                    text: f.v,
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w700)),
              ])),
            ),
        ]),
      ]),
    );
  }

  Widget _coverRow(int i, List<Brand> available) {
    final row = _extraCovers[i];
    // The brands this row may pick: still-free ones + its own current pick.
    final opts = [
      ..._brands.where((b) => b.id == row.brandId),
      ...available,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(children: [
        SizedBox(
          width: 128,
          child: DropdownButtonFormField<String>(
            initialValue: row.brandId,
            isExpanded: true,
            decoration: _dec(null),
            hint: const Text('Brand', style: TextStyle(fontSize: 13)),
            items: [
              for (final b in opts)
                DropdownMenuItem(
                    value: b.id,
                    child: Text(b.name,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _saving
                ? null
                : (v) => setState(
                    () => _extraCovers[i] = (brandId: v, ctrl: row.ctrl)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: row.ctrl,
            enabled: !_saving,
            decoration: _dec(null)
                .copyWith(hintText: 'word on this brand\'s cover'),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: Colors.red),
          tooltip: 'Remove',
          onPressed: _saving
              ? null
              : () => setState(() {
                    _extraCovers.removeAt(i).ctrl.dispose();
                  }),
        ),
      ]),
    );
  }

  // ── image DNA field (print scope) ───────────────────────────────────────────────────────────
  Widget _imageDnaField(DnaAttribute attr) {
    final tagged = _printDna[attr.id] ?? const [];
    // A child is scoped to the parent value the print carries.
    final parent = attr.parentAttributeId == null
        ? null
        : _imageDna.where((x) => x.id == attr.parentAttributeId).firstOrNull;
    final parentTagged = parent != null && (_printDna[parent.id] ?? const []).isNotEmpty;
    if (parent != null && !parentTagged) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: InputDecorator(
          decoration: _dec(attr.name),
          child: Text('pick a ${parent.name} first',
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade400)),
        ),
      );
    }
    final opts = attr.values.where((v) {
      if (v.name.toLowerCase() == 'none') return false;
      if (parent == null) return true;
      final pv = (_printDna[parent.id] ?? const []).toSet();
      return v.parentValueId == null || pv.contains(v.parentValueId);
    }).toList();

    if (attr.isMulti) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(attr.name,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade600)),
          const SizedBox(height: 5),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final v in opts)
              FilterChip(
                label: Text(v.name, style: const TextStyle(fontSize: 11.5)),
                selected: tagged.contains(v.id),
                visualDensity: VisualDensity.compact,
                selectedColor: _dnaGold.withValues(alpha: 0.18),
                onSelected: _saving
                    ? null
                    : (on) => setState(() {
                          final next = [...tagged];
                          on ? next.add(v.id) : next.remove(v.id);
                          _printDna[attr.id] = next;
                        }),
              ),
          ]),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DropdownButtonFormField<String>(
        initialValue: opts.any((v) => v.id == (tagged.isEmpty ? null : tagged.first))
            ? tagged.first
            : null,
        isExpanded: true,
        decoration: _dec(attr.name),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('—')),
          for (final v in opts)
            DropdownMenuItem(value: v.id, child: Text(v.name)),
        ],
        onChanged: _saving
            ? null
            : (v) => setState(() {
                  _printDna[attr.id] = v == null ? [] : [v];
                  // Clear a child whose parent changed.
                  for (final child in _imageDna
                      .where((c) => c.parentAttributeId == attr.id)) {
                    _printDna.remove(child.id);
                  }
                }),
      ),
    );
  }

  // ── small helpers ───────────────────────────────────────────────────────────────────────────
  Widget _valueDrop(DnaAttribute? attr, String? current, List<DnaValue> opts,
      void Function(String?) onPick) {
    if (attr == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String?>(
        initialValue: opts.any((v) => v.id == current) ? current : null,
        isExpanded: true,
        decoration: _dec(attr.name),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
          for (final v in opts)
            DropdownMenuItem(value: v.id, child: Text(v.name)),
        ],
        onChanged: _saving ? null : onPick,
      ),
    );
  }

  Widget _brandPill(String name, {bool gold = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(
          color: gold ? _dnaGold : _navy,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(name,
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white)),
      );

  InputDecoration _dec(String? label) => InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      );

  // ── body colour helpers ─────────────────────────────────────────────────────────────────────
  double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

  String _labText(Map<String, dynamic> bc) {
    final l = _num(bc['l']), a = _num(bc['a']), b = _num(bc['b']);
    if (l != null || a != null || b != null) {
      String f(double? x) => x == null ? '–' : _trim(x);
      return 'L ${f(l)} · a ${f(a)} · b ${f(b)}';
    }
    final hex = (bc['hex'] ?? '').toString();
    return hex.isEmpty ? 'no colour value' : 'Hex $hex';
  }

  String _trim(double x) => x % 1 == 0 ? x.toStringAsFixed(0) : x.toString();

  Widget _swatch(Map<String, dynamic> bc, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bodyColourSwatch(bc),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: Colors.black.withValues(alpha: 0.12)),
        ),
      );

  Future<void> _pickBodyColour() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('Body colour',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          for (final bc in _palette)
            ListTile(
              leading: _swatch(bc, 30),
              title: Text((bc['name'] ?? '').toString(),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle:
                  Text(_labText(bc), style: const TextStyle(fontSize: 11.5)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_bodyColourId == bc['id'])
                  const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.check, color: _navy, size: 20)),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  tooltip: 'Edit',
                  onPressed: () =>
                      Navigator.pop(ctx, '__edit__:${bc['id']}'),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 19, color: Colors.red),
                  tooltip: 'Delete',
                  onPressed: () =>
                      Navigator.pop(ctx, '__delete__:${bc['id']}'),
                ),
              ]),
              onTap: () => Navigator.pop(ctx, (bc['id'] ?? '').toString()),
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_circle_outline, color: _navy),
            title: const Text('Create new body colour…',
                style: TextStyle(color: _navy, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, '__new__'),
          ),
        ]),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen == '__new__') {
      await _bodyColourDialog();
    } else if (chosen.startsWith('__edit__:')) {
      final id = chosen.substring(9);
      final bc = _palette.where((c) => c['id'] == id).firstOrNull;
      if (bc != null) await _bodyColourDialog(edit: bc);
    } else if (chosen.startsWith('__delete__:')) {
      await _deleteBodyColour(chosen.substring(11));
    } else {
      setState(() => _bodyColourId = chosen);
    }
  }

  Future<void> _deleteBodyColour(String id) async {
    final bc = _palette.where((c) => c['id'] == id).firstOrNull;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete body colour?'),
        content: Text(
            'Remove "${(bc?['name'] ?? '').toString()}" from your palette? '
            'A design that uses it must be changed first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.bodyColourDelete(id);
      final palette = await _data.myBodyColours();
      if (mounted) {
        setState(() {
          _palette = palette;
          if (_bodyColourId == id) _bodyColourId = null;
        });
      }
    } catch (e) {
      if (mounted) _snack('$e', error: true);
    }
  }

  Future<void> _bodyColourDialog({Map<String, dynamic>? edit}) async {
    final nameCtrl = TextEditingController(text: (edit?['name'] ?? '').toString());
    String s(dynamic v) => v == null ? '' : _trim((v as num).toDouble());
    final lCtrl = TextEditingController(text: s(edit?['l']));
    final aCtrl = TextEditingController(text: s(edit?['a']));
    final bCtrl = TextEditingController(text: s(edit?['b']));
    final hexCtrl = TextEditingController(text: (edit?['hex'] ?? '').toString());
    const signedDec = TextInputType.numberWithOptions(decimal: true, signed: true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(edit == null ? 'New body colour' : 'Edit body colour'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Name it your way — it is your word, and it is the identity.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration:
                    _dec('Name *').copyWith(hintText: 'e.g. Earth, Milky Body'),
              ),
              const SizedBox(height: 12),
              Text('L · a · b  (optional — for accuracy, preferred over Hex)',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: lCtrl,
                        keyboardType: signedDec,
                        decoration: _dec('L'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: aCtrl,
                        keyboardType: signedDec,
                        decoration: _dec('a'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: bCtrl,
                        keyboardType: signedDec,
                        decoration: _dec('b'))),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: hexCtrl,
                decoration:
                    _dec('Hex (fallback)').copyWith(hintText: '#6B3F2A'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save colour')),
        ],
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      try {
        String? id;
        if (edit == null) {
          id = await _data.bodyColourUpsert(
            name: nameCtrl.text.trim(),
            l: double.tryParse(lCtrl.text.trim()),
            a: double.tryParse(aCtrl.text.trim()),
            b: double.tryParse(bCtrl.text.trim()),
            hex: hexCtrl.text.trim().isEmpty ? null : hexCtrl.text.trim(),
          );
        } else {
          await _data.bodyColourUpdate(
            id: (edit['id'] ?? '').toString(),
            name: nameCtrl.text.trim(),
            l: double.tryParse(lCtrl.text.trim()),
            a: double.tryParse(aCtrl.text.trim()),
            b: double.tryParse(bCtrl.text.trim()),
            hex: hexCtrl.text.trim().isEmpty ? null : hexCtrl.text.trim(),
          );
          id = (edit['id'] ?? '').toString();
        }
        final palette = await _data.myBodyColours();
        if (mounted) {
          setState(() {
            _palette = palette;
            _bodyColourId = id;
          });
        }
      } catch (e) {
        if (mounted) _snack('$e', error: true);
      }
    }
    nameCtrl.dispose();
    lCtrl.dispose();
    aCtrl.dispose();
    bCtrl.dispose();
    hexCtrl.dispose();
  }

  Future<String?> _promptText(String title) async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (t) => Navigator.pop(ctx, t.trim()),
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
    ctrl.dispose();
    return v;
  }
}
