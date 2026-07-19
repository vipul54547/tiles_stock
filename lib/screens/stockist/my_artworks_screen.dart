import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
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
  final _picker = ImagePicker();

  /// The print_id whose faces are mid-upload/delete — its strip shows a spinner and locks.
  String? _busyFace;

  List<Map<String, dynamic>> _artworks = [];

  /// The admin size list, for the "+ New Artwork" dialog.
  List<String> _sizes = [];

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
    final sizes = await _data.getActiveSizeNames();
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
      _sizes = sizes;
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

  /// Add a FACE to the artwork — Faces-2, 3, 4 … Faces-1 is the artwork's own image. On desktop we
  /// open the file dialog straight away (no camera); on a phone we offer camera or gallery.
  Future<void> _addFace(Map<String, dynamic> a) async {
    final printId = (a['print_id'] ?? '').toString();
    ImageSource? source = ImageSource.gallery;
    if (!isWindowsDesktop) {
      source = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined, color: _navy),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined, color: _navy),
                title: const Text('Choose from gallery'),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
    }
    if (source == null) return;
    final x = await _picker.pickImage(
        source: source, maxWidth: 1600, imageQuality: 88);
    if (x == null || !mounted) return;

    setState(() => _busyFace = printId);
    try {
      final url = await CloudinaryService.uploadImage(x.path);
      if (url == null) throw 'Image upload failed. Try again.';
      await _data.printFaceAdd(printId: printId, imageUrl: url);
      await _load();
    } catch (e) {
      if (mounted) _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busyFace = null);
    }
  }

  /// Remove one extra face (Faces-1 cannot be removed here — it is the artwork's own image).
  Future<void> _deleteFace(Map<String, dynamic> a, Map<String, dynamic> face) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this face?'),
        content: Text(
            'Faces-${face['position']} will be removed. The remaining faces renumber.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyFace = (a['print_id'] ?? '').toString());
    try {
      await _data.printFaceDelete((face['id'] ?? '').toString());
      await _load();
    } catch (e) {
      if (mounted) _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busyFace = null);
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _addArtwork,
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Artwork'),
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
                              90 + MediaQuery.viewPaddingOf(context).bottom),
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

  /// Add ONE artwork by hand — the manual twin of the folder import. Size + name + image, and that
  /// is all an artwork is. Idempotent on (name, size): re-adding an existing one just adopts it.
  Future<void> _addArtwork() async {
    final nameCtrl = TextEditingController();
    String? size = _sizes.isNotEmpty ? _sizes.first : null;
    String? imageUrl;
    var uploading = false;
    var saving = false;

    Future<String?> pickAndUpload() async {
      ImageSource? source = ImageSource.gallery;
      if (!isWindowsDesktop) {
        source = await showModalBottomSheet<ImageSource>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading:
                      const Icon(Icons.photo_camera_outlined, color: _navy),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                ListTile(
                  leading:
                      const Icon(Icons.photo_library_outlined, color: _navy),
                  title: const Text('Choose from gallery'),
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      }
      if (source == null) return null;
      final x =
          await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 88);
      if (x == null) return null;
      return CloudinaryService.uploadImage(x.path);
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        Future<void> save() async {
          final name = nameCtrl.text.trim();
          if (name.isEmpty || size == null) {
            _snack('Give the artwork a name and a size.', error: true);
            return;
          }
          setLocal(() => saving = true);
          try {
            await _data.artworkImport(
                size: size!, name: name, imageUrl: imageUrl ?? '');
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            _snack('Artwork added.');
            await _load();
          } catch (e) {
            setLocal(() => saving = false);
            _snack('$e', error: true);
          }
        }

        return AlertDialog(
          title: const Text('New artwork'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'An artwork is a picture: a name, a size, and the image. Nothing else — the '
                  'surface and body come later, when you cut a design from it.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The picture.
                    InkWell(
                      onTap: (uploading || saving)
                          ? null
                          : () async {
                              setLocal(() => uploading = true);
                              final url = await pickAndUpload();
                              if (!ctx.mounted) return;
                              setLocal(() {
                                uploading = false;
                                if (url != null) imageUrl = url;
                              });
                              if (url == null) return;
                            },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                          color: Colors.grey.shade50,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: uploading
                            ? const Center(
                                child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)))
                            : imageUrl == null
                                ? Column(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_a_photo_outlined,
                                          color: Colors.grey.shade500),
                                      const SizedBox(height: 3),
                                      Text('Add photo',
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey.shade600)),
                                    ],
                                  )
                                : CachedNetworkImage(
                                    imageUrl: CloudinaryService.thumbUrl(
                                        imageUrl!, width: 220),
                                    fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          TextField(
                            controller: nameCtrl,
                            enabled: !saving,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                                labelText: 'Artwork name *',
                                border: OutlineInputBorder(),
                                isDense: true),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            initialValue: size,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: 'Size *',
                                border: OutlineInputBorder(),
                                isDense: true),
                            items: [
                              for (final s in _sizes)
                                DropdownMenuItem(
                                    value: s,
                                    child: Text(s.replaceAll(' mm', '')))
                            ],
                            onChanged: saving
                                ? null
                                : (v) => setLocal(() => size = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: (saving || uploading) ? null : save,
                child: Text(saving ? 'Adding…' : 'Add')),
          ],
        );
      }),
    );
    nameCtrl.dispose();
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
                  const SizedBox(height: 6),
                  // 🖼️ THE FACES — Faces-1 is the artwork's own image; add the rest here.
                  _facesStrip(a),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The faces row: Faces-1 (the artwork's own image) + every extra face, each labelled
  /// "faces-N", each extra with a delete ×, and a trailing "+ Add face" tile.
  Widget _facesStrip(Map<String, dynamic> a) {
    final printId = (a['print_id'] ?? '').toString();
    final face1 = (a['image_url'] ?? '').toString();
    final extras = [
      for (final f in (a['faces'] as List?) ?? const [])
        Map<String, dynamic>.from(f as Map)
    ];
    final busy = _busyFace == printId;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 96,
          child: Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Faces:',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _faceTile(imageUrl: face1, label: 'faces-1'),
              for (final f in extras)
                _faceTile(
                  imageUrl: (f['image_url'] ?? '').toString(),
                  label: 'faces-${f['position']}',
                  onDelete: busy ? null : () => _deleteFace(a, f),
                ),
              _addFaceTile(busy: busy, onTap: () => _addFace(a)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _faceTile(
      {required String imageUrl, required String label, VoidCallback? onDelete}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: imageUrl.isEmpty
                      ? Container(
                          color: Colors.grey.shade100,
                          child: Icon(Icons.image_outlined,
                              size: 18, color: Colors.grey.shade400))
                      : CachedNetworkImage(
                          imageUrl: CloudinaryService.thumbUrl(imageUrl, width: 140),
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: Colors.grey.shade200),
                          errorWidget: (_, __, ___) =>
                              Container(color: Colors.grey.shade200)),
                ),
              ),
              if (onDelete != null)
                Positioned(
                  top: -6,
                  right: -6,
                  child: InkWell(
                    onTap: onDelete,
                    child: Container(
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      padding: const EdgeInsets.all(2),
                      child: const Icon(Icons.close,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _addFaceTile({required bool busy, required VoidCallback onTap}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _navy.withValues(alpha: 0.4)),
              color: _navy.withValues(alpha: 0.04),
            ),
            child: busy
                ? const Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.add_a_photo_outlined, size: 20, color: _navy),
          ),
        ),
        const SizedBox(height: 2),
        Text('add', style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600)),
      ],
    );
  }

  /// One attribute, mapped in place. Multi-value (Colour) is check-chips; single-value is a
  /// dropdown. A CHILD is greyed out until its parent is picked — that is the cascade, and the
  /// server enforces it too ("pick the parent value first").
  Widget _attrRow(Map<String, dynamic> a, DnaAttribute attr) {
    final options = _optionsFor(a, attr);
    final tagged = _tagged(a, attr);
    // Two very different empty states, and they must NOT say the same thing:
    //   • parent not chosen yet   → "pick a Look Type first"
    //   • parent chosen, but it simply has no children of this attribute (e.g. no Natural Name
    //     is defined under "Wood") → say so, don't pretend nothing was picked.
    final parent = attr.parentAttributeId == null
        ? null
        : _attrs.where((x) => x.id == attr.parentAttributeId).firstOrNull;
    final parentTagged = parent != null && _tagged(a, parent).isNotEmpty;
    final waitingForParent = parent != null && !parentTagged;
    final noneForParent = parentTagged && options.isEmpty;

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
            child: waitingForParent
                ? Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text('pick a ${_parentName(attr)} first',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade400)),
                  )
                : noneForParent
                    ? Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(
                            'no ${attr.name} for ${_parentValueNames(a, parent)}',
                            style: TextStyle(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: Colors.grey.shade400)),
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

  /// The name(s) of the parent value(s) this artwork carries — e.g. "Wood" — for the
  /// "no Natural Name for Wood" hint.
  String _parentValueNames(Map<String, dynamic> a, DnaAttribute parent) {
    final ids = _tagged(a, parent).toSet();
    return parent.values
        .where((v) => ids.contains(v.id))
        .map((v) => v.name)
        .join(', ');
  }
}
