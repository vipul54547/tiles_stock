import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/choice_state.dart';
import '../../utils/platform_kind.dart';
import '../../services/cloudinary_service.dart';
import '../../services/pano_upload.dart';
import '../../services/supabase_data_service.dart';

/// 🖼️ Add / edit a portfolio MATERIAL (project_media_portfolio_ddpi #3/#14).
///
/// Flow: pick a TYPE (only the ones the admin enabled) → give the media (image
/// upload for mockup/aligning/close-look; a link for 360/video) → optional Space
/// tag → tag which DESIGNS are in the shot → fine-tune visibility per tile.
///
/// Binding differs by type (see the buyer read `public_portfolio`):
///  • mockup/aligning/360/video ride the ARTWORK — tagging an artwork shows the
///    material on ALL its tiles by default; the grid only stores EXCEPTIONS
///    (unticked = hidden, or a non-default placement caption).
///  • close-look rides the TILE — nothing shows until you tick specific tiles.
class AddMaterialScreen extends StatefulWidget {
  /// The enabled/quota config from `my_media_config` (so we offer only allowed types).
  final Map<String, dynamic> config;

  /// When non-null, edits this existing material (a `my_media` row) instead of creating.
  final Map<String, dynamic>? existing;

  const AddMaterialScreen({super.key, required this.config, this.existing});

  @override
  State<AddMaterialScreen> createState() => _AddMaterialScreenState();
}

// type → (label, isImage, prefersLink)
const _typeMeta = <String, ({String label, bool image})>{
  'mockup': (label: 'Mockup', image: true),
  'aligning': (label: 'Aligning', image: true),
  'closelook': (label: 'Close-look', image: true),
  '360': (label: '360', image: false),
  'video': (label: 'Video', image: false),
};

class _AddMaterialScreenState extends State<AddMaterialScreen> {
  static const _navy = Color(0xFF1B4F72);
  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  String _type = '';
  final _url = TextEditingController(); // image secure_url OR video/360 link
  String? _space; // space value ('kitchen', …) or null
  final Set<String> _prints = {}; // tagged artwork ids
  String _artworkSearch = ''; // filters the tagging list

  List<Map<String, dynamic>> _artworks = [];
  List<Map<String, dynamic>> _spaces = [];
  List<Map<String, dynamic>> _placements = [];
  // grid: library_id → {row..., shown bool, placement value}
  List<Map<String, dynamic>> _grid = [];

  bool _loading = true;
  bool _uploading = false;
  bool _saving = false;
  bool _uploading360 = false; // a 360 bundle is uploading
  String? _bundleStatus; // progress / done text for the 360 upload
  bool _gridLoading = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  bool get _isCloselook => _type == 'closelook';
  bool get _isImageType => _typeMeta[_type]?.image ?? false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  List<String> get _enabledTypes =>
      _typeMeta.keys.where((t) => widget.config[t] == true).toList();

  Future<void> _bootstrap() async {
    try {
      final results = await Future.wait([
        _data.myArtworks(),
        _data.lookupValues('space'),
        _data.lookupValues('placement'),
      ]);
      _artworks = results[0];
      _spaces = results[1];
      _placements = results[2];

      final ex = widget.existing;
      if (ex != null) {
        _type = ex['type'] as String? ?? '';
        _url.text = ex['url'] as String? ?? '';
        _space = ex['space'] as String?;
        for (final a in (ex['artworks'] as List? ?? const [])) {
          final pid = (a as Map)['print_id'] as String?;
          if (pid != null) _prints.add(pid);
        }
        await _loadGrid();
      } else {
        final en = _enabledTypes;
        if (en.isNotEmpty) _type = en.first;
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ── media input ─────────────────────────────────────────────────────────────

  Future<void> _pickImage() async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    setState(() => _uploading = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (url != null) _url.text = url;
    });
    if (url == null) _snack('Upload failed — try again.', error: true);
  }

  // ── tagging + grid ────────────────────────────────────────────────────────

  Future<void> _loadGrid() async {
    if (_prints.isEmpty) {
      setState(() => _grid = []);
      return;
    }
    setState(() => _gridLoading = true);
    try {
      final rows = await _data.myMediaGrid(
          printIds: _prints.toList(), assetId: widget.existing?['id'] as String?);
      // For a NEW close-look nothing is shown until ticked → start every row off.
      final defaultOff = _isCloselook && !_isEdit;
      setState(() {
        _grid = [
          for (final r in rows)
            {
              ...r,
              'shown': defaultOff ? false : (r['shown'] ?? true),
              'placement': r['placement'] ?? 'both',
            }
        ];
        _gridLoading = false;
      });
    } catch (e) {
      setState(() => _gridLoading = false);
      _snack(e.toString(), error: true);
    }
  }

  void _toggleArtwork(String pid, bool on) {
    setState(() => on ? _prints.add(pid) : _prints.remove(pid));
    _loadGrid();
  }

  // ── save ──────────────────────────────────────────────────────────────────

  String? _validate() {
    if (_type.isEmpty) return 'Pick a material type.';
    if (_url.text.trim().isEmpty) {
      return _isImageType ? 'Add an image.' : 'Paste a link.';
    }
    if (_isCloselook) {
      if (!_grid.any((r) => r['shown'] == true)) {
        return 'Tick at least one tile this close-look is for.';
      }
    } else if (_prints.isEmpty) {
      return 'Tag at least one design in the shot.';
    }
    return null;
  }

  /// Tile payload for the server. Close-look = the ticked tiles (the binding).
  /// Artwork-bound = only exceptions (hidden, or a non-default placement caption).
  List<Map<String, dynamic>> _tilePayload() {
    if (_isCloselook) {
      return [
        for (final r in _grid)
          if (r['shown'] == true)
            {
              'library_id': r['library_id'],
              'shown': true,
              'placement': r['placement'],
            }
      ];
    }
    return [
      for (final r in _grid)
        if (r['shown'] != true || (r['placement'] ?? 'both') != 'both')
          {
            'library_id': r['library_id'],
            'shown': r['shown'] == true,
            'placement': r['placement'],
          }
    ];
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      _snack(err, error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final prints = _isCloselook ? <String>[] : _prints.toList();
      final tiles = _tilePayload();
      if (_isEdit) {
        final id = widget.existing!['id'] as String;
        await _data.mediaUpdate(id, _url.text.trim(), _space);
        await _data.mediaSetArtworks(id, prints);
        await _data.mediaSetTiles(id, tiles);
      } else {
        await _data.mediaAdd(
          type: _type,
          url: _url.text.trim(),
          space: _space,
          printIds: prints,
          tiles: tiles,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _saving = false);
      _snack(e.toString(), error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
      duration: Duration(seconds: error ? 4 : 2),
    ));
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Material' : 'Add Material')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load: $_error'))
              : _enabledTypes.isEmpty && !_isEdit
                  ? const Center(
                      child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'No media types are enabled for you yet. Ask the admin '
                          'to turn on Mockup / Aligning / Close-look / 360 / Video.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey)),
                    ))
                  : _form(),
      bottomNavigationBar: (_loading || _error != null)
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
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
                        : Text(_isEdit ? 'Save Changes' : 'Add Material',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        // type
        _label('Type'),
        Wrap(
          spacing: 8,
          children: [
            for (final t in _typeMeta.keys)
              if (widget.config[t] == true || (_isEdit && t == _type))
                ChoiceChip(
                  label: Text(_typeMeta[t]!.label),
                  selected: _type == t,
                  onSelected: _isEdit
                      ? null // type is fixed once created
                      : (_) {
                          setState(() {
                            _type = t;
                            _url.clear();
                          });
                          _loadGrid();
                        },
                ),
          ],
        ),
        if (_type == '360' || _type == 'video') _quotaHint(),
        const SizedBox(height: 16),

        // media
        _label(_isImageType
            ? 'Image'
            : (_type == '360' ? '360 walk-in' : 'Link')),
        if (_isImageType)
          _imageInput()
        else if (_type == '360')
          _bundle360Input()
        else
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              hintText: 'YouTube / video URL',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        const SizedBox(height: 16),

        // space (mockups + 360 carry a room tag)
        if (_type == 'mockup' || _type == '360') ...[
          _label('Space (optional)'),
          DropdownButtonFormField<String?>(
            initialValue: _space,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), isDense: true),
            items: [
              const DropdownMenuItem(value: null, child: Text('—')),
              for (final s in _spaces)
                DropdownMenuItem(
                    value: s['value'] as String,
                    child: Text(s['label'] as String)),
            ],
            onChanged: (v) => setState(() => _space = v),
          ),
          const SizedBox(height: 16),
        ],

        // artworks
        _label(_isCloselook
            ? 'Which design (to find its tiles)'
            : 'Designs in the shot'),
        _artworkPicker(),
        const SizedBox(height: 16),

        // visibility grid
        if (_prints.isNotEmpty) ...[
          _label(_isCloselook
              ? 'Tick the tile(s) this close-look shows'
              : 'Shows on these tiles — untick to hide, set Wall/Floor'),
          _gridView(),
        ],
      ],
    );
  }

  Widget _quotaHint() {
    final u = _type == '360' ? widget.config['used_360'] : widget.config['used_video'];
    final q = _type == '360' ? widget.config['quota_360'] : widget.config['quota_video'];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text('Used ${u ?? 0} of ${q ?? 0}.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
    );
  }

  // 🌐 360 = a Pano2VR bundle FOLDER, hosted in Supabase Storage. On Windows the
  // stockist picks the folder and it uploads; anywhere, a hosted index.html URL
  // can be pasted. (media portfolio P2)
  Future<void> _pick360Bundle() async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick the Pano2VR bundle folder (with index.html)');
    if (dir == null) return;
    setState(() {
      _uploading360 = true;
      _bundleStatus = 'Uploading…';
    });
    try {
      final prefix =
          '$currentStockistUUID/${DateTime.now().millisecondsSinceEpoch}';
      final url = await PanoUpload.uploadBundle(dir, prefix: prefix,
          onProgress: (done, total) {
        if (mounted) {
          setState(() => _bundleStatus = 'Uploading $done / $total…');
        }
      });
      if (!mounted) return;
      setState(() {
        _uploading360 = false;
        _bundleStatus = 'Uploaded ✓';
        _url.text = url;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading360 = false;
        _bundleStatus = null;
      });
      _snack(e.toString(), error: true);
    }
  }

  Widget _bundle360Input() {
    final has = _url.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isWindowsDesktop)
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _uploading360 ? null : _pick360Bundle,
                icon: _uploading360
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.threesixty, size: 18),
                label: Text(has ? 'Replace 360 bundle' : 'Upload 360 bundle folder'),
              ),
              if (_bundleStatus != null) ...[
                const SizedBox(width: 12),
                Flexible(
                  child: Text(_bundleStatus!,
                      style: TextStyle(
                          fontSize: 12,
                          color: _bundleStatus == 'Uploaded ✓'
                              ? const Color(0xFF2E7D32)
                              : Colors.grey.shade600)),
                ),
              ],
            ],
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          decoration: InputDecoration(
            hintText: isWindowsDesktop
                ? 'Hosted index.html URL (filled after upload)'
                : 'Paste a hosted Pano2VR index.html URL',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (isWindowsDesktop && !has)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                'Pick the folder that contains index.html, pano.xml and the '
                'tiles — it uploads and the link fills in.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ),
      ],
    );
  }

  Widget _imageInput() {
    final has = _url.text.trim().isNotEmpty;
    return Row(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          clipBehavior: Clip.antiAlias,
          child: _uploading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : has
                  ? Image.network(CloudinaryService.thumbUrl(_url.text, width: 200),
                      fit: BoxFit.cover)
                  : Icon(Icons.image_outlined, color: Colors.grey.shade400),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _uploading ? null : _pickImage,
          icon: const Icon(Icons.upload, size: 18),
          label: Text(has ? 'Replace' : 'Upload'),
        ),
      ],
    );
  }

  Widget _artworkPicker() {
    if (_artworks.isEmpty) {
      return const Text('No designs yet.', style: TextStyle(color: Colors.grey));
    }
    final q = _artworkSearch.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _artworks
        : _artworks
            .where((a) =>
                (a['name']?.toString().toLowerCase() ?? '').contains(q) ||
                (a['size']?.toString().toLowerCase() ?? '').contains(q))
            .toList();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search designs…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (v) => setState(() => _artworkSearch = v),
              ),
            ),
            if (_prints.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text('${_prints.length} selected',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: _navy)),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: filtered.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No matches.',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final a = filtered[i];
                    final pid = a['print_id'] as String;
          final on = _prints.contains(pid);
          return CheckboxListTile(
            dense: true,
            value: on,
            controlAffinity: ListTileControlAffinity.leading,
            secondary: (a['image_url'] as String?)?.isNotEmpty == true
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                        CloudinaryService.thumbUrl(a['image_url'] as String,
                            width: 100),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover),
                  )
                : null,
            title: Text(a['name']?.toString() ?? '',
                style: const TextStyle(fontSize: 14)),
            subtitle: Text('${a['size'] ?? ''} · ${a['tiles'] ?? 0} tiles',
                style: const TextStyle(fontSize: 11)),
            onChanged: (v) => _toggleArtwork(pid, v ?? false),
          );
                  },
                ),
        ),
      ],
    );
  }

  Widget _gridView() {
    if (_gridLoading) {
      return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()));
    }
    if (_grid.isEmpty) {
      return const Text('These designs have no tiles yet.',
          style: TextStyle(color: Colors.grey));
    }
    return Column(
      children: [
        for (final r in _grid)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: Checkbox(
                value: r['shown'] == true,
                onChanged: (v) => setState(() => r['shown'] = v ?? false),
              ),
              title: Text(
                  '${r['name'] ?? ''} · ${r['surface_label'] ?? r['surface_type'] ?? ''}',
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                  [r['tile_type'], r['body_colour']]
                      .where((e) => e != null && '$e'.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(fontSize: 11)),
              trailing: SizedBox(
                width: 130,
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: (r['placement'] as String?) ?? 'both',
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final p in _placements)
                      DropdownMenuItem(
                          value: p['value'] as String,
                          child: Text(p['label'] as String,
                              style: const TextStyle(fontSize: 12))),
                  ],
                  onChanged: r['shown'] == true
                      ? (v) => setState(() => r['placement'] = v)
                      : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13, color: _navy)),
      );
}
