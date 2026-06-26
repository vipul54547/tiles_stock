import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/banner_layout.dart';

/// Admin: per-brand identity for one stockist — rename, banner, and Live/
/// Correction/Off status. The "how many stock lists" allowance is now set
/// per-stockist on the stockist edit form, not per-brand. Reached from the
/// stockist edit form. (project_stockist_library)
class StockistBrandListsScreen extends StatefulWidget {
  final String seq; // stockist sequential id
  final String stockistName;
  const StockistBrandListsScreen(
      {super.key, required this.seq, required this.stockistName});
  @override
  State<StockistBrandListsScreen> createState() => _State();
}

class _State extends State<StockistBrandListsScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();
  List<Map<String, dynamic>> _brands = [];
  bool _loading = true;
  bool _saving = false;

  static const Color _navy = Color(0xFF1B4F72);

  // Placement keys for the position dropdowns.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final brands = await _data.adminStockistBrands(widget.seq);
    if (!mounted) return;
    setState(() {
      _brands = brands;
      _loading = false;
    });
  }

  // + Add brand — dialog pre-filled with the next default name "Brand N".
  Future<void> _addBrand() async {
    final ctrl = TextEditingController(text: 'Brand ${_brands.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              labelText: 'Brand name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await _data.addBrandForStockist(widget.seq, name.trim());
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(Map<String, dynamic> b) async {
    final ctrl = TextEditingController(text: (b['name'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename brand'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
              labelText: 'Brand name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name.trim() == b['name']) return;
    setState(() => _saving = true);
    try {
      await _data.renameBrand((b['id'] ?? '').toString(), name.trim());
      if (!mounted) return;
      setState(() => b['name'] = name.trim());
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text('${widget.stockistName} — Brands & Lists'),
        actions: [
          IconButton(
            tooltip: 'Add brand',
            icon: const Icon(Icons.add),
            onPressed: _saving ? null : _addBrand,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _brands.isEmpty
              ? _empty()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Text(
                          'Manage each brand\'s name, banner, and visibility. The '
                          'number of stock lists is set per-stockist on the '
                          'stockist edit form.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ),
                    ..._brands.map(_brandCard),
                  ],
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.sell_outlined, size: 60, color: Colors.grey.shade300),
              const SizedBox(height: 12),
              Text('No brands yet',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
              const SizedBox(height: 4),
              Text(
                  'Tap + (top right) to add a brand. The first one is the '
                  'company default.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ],
          ),
        ),
      );

  Widget _brandCard(Map<String, dynamic> b) {
    final isDefault = b['is_default'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell, size: 18, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(b['name']?.toString() ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: _navy)),
                ),
                if (isDefault)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('default',
                        style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ),
                IconButton(
                  tooltip: 'Rename brand',
                  icon: const Icon(Icons.edit_outlined, size: 19, color: _navy),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  onPressed: _saving ? null : () => _rename(b),
                ),
                if (!isDefault)
                  IconButton(
                    tooltip: 'Delete brand',
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: Colors.red),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.all(4),
                    onPressed: _saving ? null : () => _deleteBrand(b),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _bannerSection(b),
            const SizedBox(height: 10),
            _statusControl(b),
          ],
        ),
      ),
    );
  }

  // ── Banner (two-path overlay) ──────────────────────────────────────────────
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

  Future<void> _applyBanner(Map<String, dynamic> b) async {
    setState(() {});
    try {
      await _data.setBrandBannerConfig(
        (b['id'] ?? '').toString(),
        source: (b['banner_source'] ?? 'pool').toString(),
        bgUrl: (b['banner_bg_url'] ?? '').toString(),
        companyLogoUrl: (b['company_logo_url'] ?? '').toString(),
        companyPos: (b['company_pos'] ?? 'none').toString(),
        tdPos: (b['td_pos'] ?? 'footer').toString(),
      );
    } catch (e) {
      _snack('$e', error: true);
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

  // Pick a logo-free background from the shared pool (Path A library source).
  Future<void> _pickLibraryBg(Map<String, dynamic> b) async {
    final pool = await _data.getGenericBanners();
    final active = pool.where((p) => p['is_active'] == true).toList();
    if (!mounted) return;
    if (active.isEmpty) {
      _snack('No background banners in the pool yet (add them in Catalog Banners).',
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
                    onTap: () => Navigator.pop(ctx, (p['image_url'] ?? '').toString()),
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
    b['banner_bg_url'] = url;
    await _applyBanner(b);
  }

  Widget _bannerSection(Map<String, dynamic> b) {
    final source = (b['banner_source'] ?? 'pool').toString();
    final bg = (b['banner_bg_url'] ?? '').toString();
    final logo = (b['company_logo_url'] ?? '').toString();
    final companyPos = (b['company_pos'] ?? 'none').toString();
    final tdPos = (b['td_pos'] ?? 'footer').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Banner',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        // Source: pool / library / upload
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11.5)),
            ),
            segments: const [
              ButtonSegment(value: 'pool', label: Text('Pool')),
              ButtonSegment(value: 'library', label: Text('Library')),
              ButtonSegment(value: 'upload', label: Text('Upload')),
            ],
            selected: {['pool', 'library', 'upload'].contains(source) ? source : 'pool'},
            onSelectionChanged: _saving
                ? null
                : (sel) {
                    b['banner_source'] = sel.first;
                    _applyBanner(b);
                  },
          ),
        ),
        const SizedBox(height: 8),
        // Live preview
        _bannerPreview(b),
        const SizedBox(height: 8),
        if (source == 'pool')
          Text('Uses the shared daily-rotating pool (Catalog Banners).',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600))
        else if (source == 'library') ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : () => _pickLibraryBg(b),
                icon: const Icon(Icons.photo_library_outlined, size: 16),
                label: Text(bg.isEmpty ? 'Pick background' : 'Change background'),
              ),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () async {
                        final url = await _uploadImage(maxWidth: 600);
                        if (url != null) {
                          b['company_logo_url'] = url;
                          await _applyBanner(b);
                        }
                      },
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: Text(logo.isEmpty ? 'Upload logo' : 'Change logo'),
              ),
              if (logo.isNotEmpty)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          b['company_logo_url'] = '';
                          _applyBanner(b);
                        },
                  child: const Text('Remove logo',
                      style: TextStyle(color: Colors.red)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // With a logo all 9 cells are offered; with the big NAME (no logo) the
          // middle row is hidden so a wide name never lands in the centre band.
          _posDropdown(
              'Company position',
              effectiveCompanyPos(companyPos, hasLogo: logo.isNotEmpty),
              companyPosKeys(hasLogo: logo.isNotEmpty), (v) {
            b['company_pos'] = v;
            _applyBanner(b);
          }),
          const SizedBox(height: 6),
          _posDropdown('TilesDesign position', tdPos, _tdPosKeys, (v) {
            b['td_pos'] = v;
            _applyBanner(b);
          }),
          if (logo.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'No logo → the big company NAME shows (top or bottom row only).',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ),
        ] else ...[
          // upload (full finished design)
          OutlinedButton.icon(
            onPressed: _saving
                ? null
                : () async {
                    final url = await _uploadImage(maxWidth: 2000);
                    if (url != null) {
                      b['banner_bg_url'] = url;
                      await _applyBanner(b);
                    }
                  },
            icon: const Icon(Icons.upload, size: 16),
            label: Text(bg.isEmpty ? 'Upload full banner' : 'Replace banner'),
          ),
          const SizedBox(height: 6),
          _posDropdown('TilesDesign position', tdPos, _tdPosKeys, (v) {
            b['td_pos'] = v;
            _applyBanner(b);
          }),
        ],
      ],
    );
  }

  // Company dropdown keys come from banner_layout (9 grid + None with a logo,
  // middle row dropped for the big name). TilesDesign = 9 grid + Footer.
  static const _tdPosKeys = <String>[
    'footer', 'top-left', 'top-center', 'top-right', 'middle-left', 'center',
    'middle-right', 'bottom-left', 'bottom-center', 'bottom-right'
  ];

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

  // A small 2.5:1 preview: background + the company logo/name + a TilesDesign chip
  // at their chosen positions (approximate — the real /s/ render comes in Phase 4).
  Widget _bannerPreview(Map<String, dynamic> b) {
    final source = (b['banner_source'] ?? 'pool').toString();
    final bg = (b['banner_bg_url'] ?? '').toString();
    final logo = (b['company_logo_url'] ?? '').toString();
    // Mirror the renderer: a logo-less name never sits in the middle row.
    final companyPos = effectiveCompanyPos(
        (b['company_pos'] ?? 'none').toString(),
        hasLogo: logo.isNotEmpty);
    final tdPos = (b['td_pos'] ?? 'footer').toString();
    final name = (b['name'] ?? '').toString();

    Widget bgWidget;
    if (source == 'pool') {
      bgWidget = Container(
        color: _navy.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: const Text('Shared pool (rotates daily)',
            style: TextStyle(fontSize: 11, color: _navy)),
      );
    } else if (bg.isNotEmpty) {
      bgWidget = CachedNetworkImage(imageUrl: bg, fit: BoxFit.cover);
    } else {
      bgWidget = Container(
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: Text(source == 'upload' ? 'Upload a banner' : 'Pick a background',
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
            // company overlay (library path only; none = hidden)
            if (source == 'library' && companyPos != 'none')
              Align(
                alignment: _alignFor(companyPos),
                child: Container(
                  margin: const EdgeInsets.all(6),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: logo.isNotEmpty
                      ? Image.network(logo, height: 28)
                      : Text(name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            // TilesDesign mark
            Align(
              alignment: _alignFor(tdPos),
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text('TilesDesign',
                    style: TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w600, color: _navy)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Live / Correction / Off — the moderation control. Default brand omits "Off".
  Widget _statusControl(Map<String, dynamic> b) {
    final isDefault = b['is_default'] == true;
    var status = (b['status'] ?? 'live').toString();
    if (!['live', 'correction', 'off'].contains(status)) status = 'live';
    if (isDefault && status == 'off') status = 'live';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
            ),
            segments: [
              const ButtonSegment(
                  value: 'live',
                  label: Text('Live'),
                  icon: Icon(Icons.public, size: 15)),
              const ButtonSegment(
                  value: 'correction',
                  label: Text('Correction'),
                  icon: Icon(Icons.build_outlined, size: 15)),
              if (!isDefault)
                const ButtonSegment(
                    value: 'off',
                    label: Text('Off'),
                    icon: Icon(Icons.visibility_off_outlined, size: 15)),
            ],
            selected: {status},
            onSelectionChanged:
                _saving ? null : (sel) => _setStatus(b, sel.first),
          ),
        ),
        const SizedBox(height: 4),
        Text(
            'Live: stockist + buyers · Correction: only the stockist (to fix '
            'images), hidden from buyers'
            '${isDefault ? '' : ' · Off: hidden from everyone'}',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
      ],
    );
  }

  Future<void> _setStatus(Map<String, dynamic> b, String status) async {
    if (status == (b['status'] ?? 'live').toString()) return;
    if (status == 'off') {
      final ok = await _confirm('Turn off brand?',
          'Buyers and the stockist will no longer see "${b['name']}". '
          'You can turn it back on later.');
      if (!ok) return;
    }
    setState(() => _saving = true);
    try {
      await _data.setBrandStatus((b['id'] ?? '').toString(), status);
      if (!mounted) return;
      setState(() => b['status'] = status); // local update, keep stepper edits
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteBrand(Map<String, dynamic> b) async {
    final ok = await _confirm('Delete brand?',
        'Permanently delete "${b['name']}" and its stock lists. This frees a '
        'brand slot and cannot be undone.');
    if (!ok) return;
    setState(() => _saving = true);
    try {
      await _data.deleteBrand((b['id'] ?? '').toString());
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null));
  }
}
