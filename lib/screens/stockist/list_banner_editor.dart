import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/stock_catalog.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/banner_layout.dart';

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
  static const _tdPosKeys = <String>[
    'footer', 'top-left', 'top-center', 'top-right', 'middle-left', 'center',
    'middle-right', 'bottom-left', 'bottom-center', 'bottom-right'
  ];

  // Working copy of the list's banner config (empty source = brand fallback).
  late String _source;
  late String _bgUrl;
  late String _logoUrl;
  late String _companyPos;
  late String _tdPos;
  bool _saving = false;
  bool _changed = false;

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
    _tdPos = c.tdPos.isEmpty ? 'footer' : c.tdPos;
  }

  Future<void> _apply() async {
    setState(() => _saving = true);
    try {
      await _data.setListBannerConfig(
        widget.catalog.id,
        source: _source,
        bgUrl: _bgUrl,
        companyLogoUrl: _logoUrl,
        companyPos: _companyPos,
        tdPos: _tdPos,
      );
      _changed = true;
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
        title: const Text('Use the brand banner?'),
        content: const Text(
            'This list will stop using its own banner and fall back to the '
            'brand banner.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Use brand banner')),
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
    final pool = await _data.getGenericBanners();
    final active = pool.where((p) => p['is_active'] == true).toList();
    if (!mounted) return;
    if (active.isEmpty) {
      _snack('No background banners available yet.', error: true);
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
                        child: Image.network((p['image_url'] ?? '').toString(),
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
              child: const Text('Use brand banner',
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
            ],
            selected: {
              ['pool', 'library', 'upload'].contains(_source) ? _source : 'pool'
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
        if (_source == 'pool')
          Text('Uses the shared daily-rotating background pool.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600))
        else if (_source == 'library') ...[
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
          const SizedBox(height: 8),
          _posDropdown(
              'Company position',
              effectiveCompanyPos(_companyPos, hasLogo: _logoUrl.isNotEmpty),
              companyPosKeys(hasLogo: _logoUrl.isNotEmpty), (v) {
            setState(() => _companyPos = v);
            _apply();
          }),
          const SizedBox(height: 6),
          _posDropdown('TilesDesign position', _tdPos, _tdPosKeys, (v) {
            setState(() => _tdPos = v);
            _apply();
          }),
          if (_logoUrl.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'No logo → your company NAME shows (top or bottom row only).',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
        ] else ...[
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
          const SizedBox(height: 6),
          _posDropdown('TilesDesign position', _tdPos, _tdPosKeys, (v) {
            setState(() => _tdPos = v);
            _apply();
          }),
        ],
      ],
    );
  }

  // Approximate render: background + company logo/name + a TilesDesign chip at
  // their chosen positions. The real /s/ page uses your company name for the
  // name text; here it shows a placeholder.
  Widget _bannerPreview() {
    final companyPos =
        effectiveCompanyPos(_companyPos, hasLogo: _logoUrl.isNotEmpty);

    Widget bgWidget;
    if (_source == 'pool') {
      bgWidget = Container(
        color: _navy.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: const Text('Shared pool (rotates daily)',
            style: TextStyle(fontSize: 11, color: _navy)),
      );
    } else if (_bgUrl.isNotEmpty) {
      bgWidget = CachedNetworkImage(imageUrl: _bgUrl, fit: BoxFit.cover);
    } else {
      bgWidget = Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Text(
            _source == 'upload' ? 'Upload a banner' : 'Pick a background',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 2.5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            bgWidget,
            if (_source == 'library' && companyPos != 'none')
              Align(
                alignment: _alignFor(companyPos),
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _logoUrl.isNotEmpty
                      ? Image.network(_logoUrl, height: 28)
                      : const Text('Company name',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            Align(
              alignment: _alignFor(_tdPos),
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text('TilesDesign',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: _navy)),
              ),
            ),
          ],
        ),
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

  Alignment _alignFor(String pos) {
    switch (pos) {
      case 'top-left':
        return Alignment.topLeft;
      case 'top-center':
        return Alignment.topCenter;
      case 'top-right':
        return Alignment.topRight;
      case 'middle-left':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'middle-right':
        return Alignment.centerRight;
      case 'bottom-left':
        return Alignment.bottomLeft;
      case 'bottom-center':
      case 'footer':
        return Alignment.bottomCenter;
      case 'bottom-right':
        return Alignment.bottomRight;
      default:
        return Alignment.center;
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null));
  }
}
