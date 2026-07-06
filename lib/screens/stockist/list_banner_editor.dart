import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/stock_catalog.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/banner_layout.dart';
import '../../widgets/banner_view.dart';

/// Per-list banner editor — the full layout system (parity with the per-brand
/// banner): a source (pool / library / upload), an optional company logo or big
/// name with 9-cell placement, and a TilesDesign mark placement. Changes save
/// live to the list via [SupabaseDataService.setListBannerConfig]. Pops `true`
/// when anything changed so the caller reloads. (project_session_resume #6)
class ListBannerEditorScreen extends StatefulWidget {
  final StockCatalog catalog;
  const ListBannerEditorScreen({super.key, required this.catalog});
  @override
  State<ListBannerEditorScreen> createState() => _State();
}

class _State extends State<ListBannerEditorScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  static const Color _navy = Color(0xFF1B4F72);
  static const _gridPositions = <String, String>{
    'none': 'None',
    'top-left': 'Top-Left',
    'top-center': 'Top-Center',
    'top-right': 'Top-Right',
    'middle-left': 'Middle-Left',
    'center': 'Center',
    'middle-right': 'Middle-Right',
    'bottom-left': 'Bottom-Left',
    'bottom-center': 'Bottom-Center',
    'bottom-right': 'Bottom-Right',
    'footer': 'Footer',
  };
  // No 'none': admin decides show/hide; the stockist only picks WHERE.
  static const _tdPosKeys = <String>[
    'top-right', 'top-center', 'top-left', 'footer', 'middle-left',
    'center', 'middle-right', 'bottom-left', 'bottom-center', 'bottom-right'
  ];

  // Working copy of the list's banner config (empty source = shared pool).
  late String _source;
  late String _bgUrl;
  late String _logoUrl;
  late String _companyPos;
  late String _tdPos;
  final _heading = TextEditingController();
  final _message = TextEditingController();
  Timer? _debounce;
  static const _leftKeys = ['top-left', 'middle-left', 'bottom-left'];
  static const int _headingMax = 28;
  static const int _messageMax = 90;
  bool _saving = false;
  bool _changed = false;
  // Admin decides whether the TilesDesign mark shows at all; the stockist only
  // picks WHERE. When off, the whole TD-position control is hidden.
  bool _tdShow = false;
  // Real stockist name + brand colour, so the preview's big-name / welcome
  // strip / gradient match exactly what buyers see on /s/ (true WYSIWYG).
  String _stkName = '';
  Color _brandColor = _navy;

  // Message mode: a non-empty message turns the Library banner into a text
  // banner (text-friendly backgrounds + logo locked to the left column).
  bool get _msgMode => _message.text.trim().isNotEmpty;

  // In message mode with a logo, the logo must sit in the left column.
  String get _companyPosForSave {
    if (_source == 'library' && _msgMode && _logoUrl.isNotEmpty) {
      return _leftKeys.contains(_companyPos) ? _companyPos : 'middle-left';
    }
    return _companyPos;
  }

  void _onTextChanged() {
    setState(() {}); // reflect message-mode UI (bg kind + position options)
    _debounce?.cancel();
    // Silent save (no _saving toggle) so the field is never disabled while the
    // keyboard is up — that was dismissing the keyboard on every save.
    _debounce = Timer(const Duration(milliseconds: 800), () async {
      try {
        await _persist();
      } catch (e) {
        if (mounted) _snack('$e', error: true);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final c = widget.catalog;
    // Seed from the rich config; if only the legacy single image exists, treat
    // it as an 'upload' so the editor opens on that picture.
    _source = c.bannerSource.isNotEmpty
        ? c.bannerSource
        : (c.bannerUrl.isNotEmpty ? 'upload' : 'pool');
    _bgUrl = c.bannerBgUrl.isNotEmpty ? c.bannerBgUrl : c.bannerUrl;
    _logoUrl = c.companyLogoUrl;
    _companyPos = c.companyPos.isEmpty ? 'none' : c.companyPos;
    _tdPos = (c.tdPos.isEmpty || c.tdPos == 'none') ? 'top-right' : c.tdPos;
    _heading.text = c.bannerHeading;
    _message.text = c.bannerText;
    _loadStockistMeta();
  }

  // td_show (admin gate) + name + brand colour, used by the shared BannerView.
  Future<void> _loadStockistMeta() async {
    final td = await _data.getMyTdShow();
    final profile = await _data.getMyProfile();
    if (!mounted) return;
    setState(() {
      _tdShow = td;
      _stkName = (profile?['name'] ?? '').toString();
      final c = _parseHex((profile?['brand_color'] ?? '').toString());
      if (c != null) _brandColor = c;
    });
  }

  static Color? _parseHex(String s) {
    var h = s.trim().replaceAll('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }

  @override
  void dispose() {
    _heading.dispose();
    _message.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // The actual save. Shared by the visible _apply (spinner) and the silent text
  // debounce (no spinner, so the keyboard never loses focus mid-typing).
  Future<void> _persist() async {
    // 'none' = no banner at all: store the source but clear every visual field.
    final none = _source == 'none';
    await _data.setListBannerConfig(
      widget.catalog.id,
      source: _source,
      bgUrl: none ? '' : _bgUrl,
      companyLogoUrl: none ? '' : _logoUrl,
      companyPos: none ? 'none' : _companyPosForSave,
      tdPos: none ? '' : _tdPos,
      heading: (!none && _source == 'library') ? _heading.text.trim() : '',
      message: (!none && _source == 'library') ? _message.text.trim() : '',
    );
    _changed = true;
  }

  Future<void> _apply() async {
    setState(() => _saving = true);
    try {
      await _persist();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to the shared pool?'),
        content: const Text(
            'This list will stop using its own banner and fall back to the '
            'shared daily-rotating pool background.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset to pool')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await _data.setListBannerConfig(widget.catalog.id, source: '');
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _uploadImage({double maxWidth = 1600}) async {
    final x = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: maxWidth, imageQuality: 88);
    if (x == null) return null;
    setState(() => _saving = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (mounted) setState(() => _saving = false);
    if (url == null) _snack('Upload failed. Try again.', error: true);
    return url;
  }

  // Pick a logo-free background from the shared pool (library source).
  Future<void> _pickLibraryBg() async {
    final pool =
        await _data.getGenericBanners(kind: _msgMode ? 'text' : 'generic');
    final active = pool.where((p) => p['is_active'] == true).toList();
    if (!mounted) return;
    if (active.isEmpty) {
      _snack(
          _msgMode
              ? 'No text backgrounds available yet.'
              : 'No background banners available yet.',
          error: true);
      return;
    }
    final url = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Pick a background',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...active.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: GestureDetector(
                    onTap: () =>
                        Navigator.pop(ctx, (p['image_url'] ?? '').toString()),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AspectRatio(
                        aspectRatio: 2.5,
                        child: Image.network(
                            CloudinaryService.bannerUrl(
                                (p['image_url'] ?? '').toString()),
                            fit: BoxFit.cover),
                      ),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
    if (url == null) return;
    setState(() => _bgUrl = url);
    await _apply();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('${widget.catalog.name} — Banner'),
        actions: [
          if (widget.catalog.hasOwnBanner || _changed)
            TextButton(
              onPressed: _saving ? null : _reset,
              child: const Text('Reset to pool',
                  style: TextStyle(color: Colors.white, fontSize: 12.5)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [_bannerSection()],
      ),
    );
  }

  Widget _bannerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Banner',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle:
                  WidgetStateProperty.all(const TextStyle(fontSize: 12)),
            ),
            segments: const [
              ButtonSegment(value: 'pool', label: Text('Pool')),
              ButtonSegment(value: 'library', label: Text('Library')),
              ButtonSegment(value: 'upload', label: Text('Upload')),
              ButtonSegment(value: 'none', label: Text('None')),
            ],
            selected: {
              ['pool', 'library', 'upload', 'none'].contains(_source)
                  ? _source
                  : 'pool'
            },
            onSelectionChanged: _saving
                ? null
                : (sel) {
                    setState(() => _source = sel.first);
                    _apply();
                  },
          ),
        ),
        const SizedBox(height: 10),
        _bannerPreview(),
        const SizedBox(height: 10),
        if (_source == 'pool') ...[
          Text('Uses the shared daily-rotating background pool.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
          if (_tdShow) ...[
            const SizedBox(height: 10),
            _posDropdown('TilesDesign position', _tdPos, _tdPosKeys, (v) {
              setState(() => _tdPos = v);
              _apply();
            }),
            _tdHint(),
          ],
        ] else if (_source == 'library') ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : _pickLibraryBg,
                icon: const Icon(Icons.photo_library_outlined, size: 16),
                label:
                    Text(_bgUrl.isEmpty ? 'Pick background' : 'Change background'),
              ),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () async {
                        final url = await _uploadImage(maxWidth: 600);
                        if (url != null) {
                          setState(() => _logoUrl = url);
                          await _apply();
                        }
                      },
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: Text(_logoUrl.isEmpty ? 'Upload logo' : 'Change logo'),
              ),
              if (_logoUrl.isNotEmpty)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          setState(() => _logoUrl = '');
                          _apply();
                        },
                  child: const Text('Remove logo',
                      style: TextStyle(color: Colors.red)),
                ),
            ],
          ),
          _logoSizeGuide(),
          const SizedBox(height: 12),
          _messageSection(),
          const SizedBox(height: 10),
          if (!_msgMode)
            _posDropdown(
                'Company position',
                effectiveCompanyPos(_companyPos, hasLogo: _logoUrl.isNotEmpty),
                companyPosKeys(hasLogo: _logoUrl.isNotEmpty), (v) {
              setState(() => _companyPos = v);
              _apply();
            })
          else if (_logoUrl.isNotEmpty)
            _posDropdown('Logo position', _companyPosForSave, _leftKeys, (v) {
              setState(() => _companyPos = v);
              _apply();
            }),
          if (_tdShow) ...[
            const SizedBox(height: 6),
            _posDropdown('TilesDesign position', _tdPos, _tdPosKeys, (v) {
              setState(() => _tdPos = v);
              _apply();
            }),
            _tdHint(),
          ],
          if (_logoUrl.isEmpty && !_msgMode)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'No logo → your company NAME shows (top or bottom row only).',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
          if (_msgMode && _logoUrl.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('No logo → your message shows centered.',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
        ] else if (_source == 'upload') ...[
          OutlinedButton.icon(
            onPressed: _saving
                ? null
                : () async {
                    final url = await _uploadImage(maxWidth: 2000);
                    if (url != null) {
                      setState(() => _bgUrl = url);
                      await _apply();
                    }
                  },
            icon: const Icon(Icons.upload, size: 16),
            label: Text(_bgUrl.isEmpty ? 'Upload full banner' : 'Replace banner'),
          ),
          _bannerSizeHint(),
          if (_tdShow) ...[
            const SizedBox(height: 6),
            _posDropdown('TilesDesign position', _tdPos, _tdPosKeys, (v) {
              setState(() => _tdPos = v);
              _apply();
            }),
            _tdHint(),
          ],
        ] else ...[
          Text('This list has no banner. The share page starts straight at the '
              'tiles — no header image, logo, or message.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ],
      ],
    );
  }

  // Live preview — renders through the SAME widget as the buyer-facing /s/ page
  // (lib/widgets/banner_view.dart), so what the stockist designs here is exactly
  // what buyers see. The only editor-specific bits are stand-ins for backgrounds
  // that aren't loaded yet (the rotating pool, or an empty slot).
  Widget _bannerPreview() {
    if (_source == 'none') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 2.5,
          child: Container(
            color: Colors.grey.shade100,
            alignment: Alignment.center,
            child: Text('No banner',
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w500)),
          ),
        ),
      );
    }
    Widget? placeholder;
    if (_source == 'pool') {
      placeholder = Container(
        color: _navy.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: const Text('Shared pool (rotates daily)',
            style: TextStyle(fontSize: 11, color: _navy)),
      );
    } else if (_bgUrl.isEmpty) {
      placeholder = Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Text(
            _source == 'upload' ? 'Upload a banner' : 'Pick a background',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BannerView(
        source: _source,
        bgUrl: _source == 'pool' ? '' : _bgUrl,
        companyLogoUrl: _logoUrl,
        // _companyPosForSave applies the message-mode "logo to the left column"
        // rule exactly as it is persisted (so /s/ sees the same value).
        companyPos: _companyPosForSave,
        tdPos: _tdPos,
        tdShow: _tdShow,
        heading: _heading.text,
        message: _message.text,
        name: _stkName,
        brandColor: _brandColor,
        bgPlaceholder: placeholder,
      ),
    );
  }

  // The stockist picks WHERE the TilesDesign mark sits, but whether it shows at
  // all is an admin decision — set expectations so they don't expect to hide it.
  Widget _tdHint() => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
            'You choose where the TilesDesign mark sits; it only appears if '
            'TilesDesign turns it on for you.',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
      );

  // Optional message overlay (instruction / condition). A non-empty message
  // flips the editor into message mode (text backgrounds + logo left).
  Widget _messageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Message on banner (optional)',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        Text('An instruction or condition, shown over the background.',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        _msgField(_heading, 'Heading — e.g. Order Condition', _headingMax),
        const SizedBox(height: 8),
        _msgField(_message,
            'Message — e.g. 25% matt selection compulsory to place an order',
            _messageMax,
            maxLines: 3),
        if (_msgMode)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'Message mode: pick a text-friendly background; the logo sits '
                'on the left.',
                style: TextStyle(
                    fontSize: 10.5,
                    color: _navy,
                    fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _msgField(TextEditingController c, String hint, int max,
          {int maxLines = 1}) =>
      TextField(
        controller: c,
        minLines: 1,
        maxLines: maxLines,
        maxLength: max,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => _onTextChanged(),
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          counterStyle: const TextStyle(fontSize: 10),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Colors.black26)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(color: Colors.black26)),
        ),
      );

  // Size guidance shown under the upload buttons.
  Widget _bannerSizeHint() => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
            'Banner 1500 × 600 px · 2.5∶1 — off-ratio images are centre-cropped.',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600)),
      );

  // Two accepted logo shapes, each with a size sketch: square and 2∶1 rectangle.
  Widget _logoSizeGuide() {
    Widget shape(double w, double h, String title, String px) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade500),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 4),
            Text(title,
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
            Text(px,
                style: TextStyle(fontSize: 9.5, color: Colors.grey.shade600)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('Logo size',
              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade700)),
          const SizedBox(width: 16),
          shape(36, 36, 'Square', '480×480'),
          const SizedBox(width: 24),
          shape(52, 26, 'Rectangle', '960×480'),
        ],
      ),
    );
  }

  Widget _posDropdown(String label, String value, List<String> keys,
      ValueChanged<String> onChanged) {
    final v = keys.contains(value) ? value : keys.first;
    return Row(
      children: [
        SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontSize: 12.5))),
        Expanded(
          child: DropdownButton<String>(
            value: v,
            isExpanded: true,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: keys
                .map((k) => DropdownMenuItem(
                    value: k,
                    child: Text(_gridPositions[k] ?? k,
                        style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: _saving ? null : (val) => onChanged(val ?? keys.first),
          ),
        ),
      ],
    );
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null));
  }
}
