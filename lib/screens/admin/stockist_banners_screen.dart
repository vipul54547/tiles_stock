import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';

/// Admin: assign a finished BRANDED banner per brand for one stockist, plus the
/// "use the shared pool instead" switch and a website note (for the designer).
/// Slots = the stockist's brands + an info card for the anonymous case (which
/// always uses the shared Default/Anonymous pool). (project_admin_banner_system)
class StockistBannersScreen extends StatefulWidget {
  final String seq; // stockist sequential id
  final String stockistName;
  const StockistBannersScreen(
      {super.key, required this.seq, required this.stockistName});
  @override
  State<StockistBannersScreen> createState() => _State();
}

class _State extends State<StockistBannersScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _brands = [];
  bool _loading = true;
  String? _busyBrandId;

  static const Color _navy = Color(0xFF1B4F72);
  static const Color _purple = Color(0xFF673AB7);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await _data.adminStockistBannerSlots(widget.seq);
    if (!mounted) return;
    setState(() {
      _brands = ((res?['brands'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _loading = false;
    });
  }

  Future<void> _run(String brandId, Future<void> Function() action) async {
    setState(() => _busyBrandId = brandId);
    try {
      await action();
      await _load();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busyBrandId = null);
    }
  }

  Future<void> _uploadBanner(Map<String, dynamic> b) async {
    final x = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: 2000, imageQuality: 88);
    if (x == null) return;
    setState(() => _busyBrandId = b['brand_id'] as String);
    final url = await CloudinaryService.uploadImage(x.path);
    if (url == null) {
      _snack('Upload failed. Try again.', error: true);
      if (mounted) setState(() => _busyBrandId = null);
      return;
    }
    await _run(b['brand_id'] as String,
        () => _data.adminSetBrandBanner(b['brand_id'] as String, url));
  }

  Future<void> _editWebsite(Map<String, dynamic> b) async {
    final ctrl = TextEditingController(text: (b['website_url'] ?? '').toString());
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Company website'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              hintText: 'https://…', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (url == null) return;
    await _run(b['brand_id'] as String,
        () => _data.adminSetBrandWebsite(b['brand_id'] as String, url));
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), backgroundColor: error ? Colors.red : null));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text('${widget.stockistName} — Banners')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 24 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                if (_brands.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                        'This stockist has no brands yet. A brand is created with '
                        'their first stock list.',
                        style: TextStyle(color: Colors.grey.shade600)),
                  )
                else
                  ..._brands.map(_brandCard),
                const SizedBox(height: 8),
                _anonymousInfo(),
              ],
            ),
    );
  }

  Widget _brandCard(Map<String, dynamic> b) {
    final brandId = b['brand_id'] as String;
    final isDefault = b['is_default'] == true;
    final usePool = b['use_pool_banner'] == true;
    final bannerUrl = (b['banner_url'] ?? '').toString();
    final website = (b['website_url'] ?? '').toString();
    final busy = _busyBrandId == brandId;
    final title = isDefault ? '${b['name']} (Company default)' : '${b['name']}';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Preview / state
          AspectRatio(
            aspectRatio: 2.5,
            child: usePool
                ? _poolPlaceholder('Uses the shared pool (rotates daily)')
                : (bannerUrl.isNotEmpty
                    ? Image.network(bannerUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _poolPlaceholder(
                            'Image unavailable'))
                    : _poolPlaceholder(
                        'No branded banner — falls back to the pool')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15, color: _navy)),
                const SizedBox(height: 8),
                // Upload / replace / remove (disabled when "use pool" is on)
                Opacity(
                  opacity: usePool ? 0.4 : 1,
                  child: IgnorePointer(
                    ignoring: usePool || busy,
                    child: Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () => _uploadBanner(b),
                          icon: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.upload, size: 18),
                          label: Text(bannerUrl.isEmpty ? 'Upload' : 'Replace'),
                          style:
                              FilledButton.styleFrom(backgroundColor: _purple),
                        ),
                        const SizedBox(width: 8),
                        if (bannerUrl.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => _run(brandId,
                                () => _data.adminClearBrandBanner(brandId)),
                            icon: const Icon(Icons.delete_outline,
                                size: 18, color: Colors.red),
                            label: const Text('Remove',
                                style: TextStyle(color: Colors.red)),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 18),
                // Use random pool
                Row(
                  children: [
                    const Expanded(
                      child: Text('Use random pool instead',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Switch(
                      value: usePool,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: busy
                          ? null
                          : (v) => _run(brandId,
                              () => _data.adminSetBrandUsePool(brandId, v)),
                    ),
                  ],
                ),
                // Website note
                InkWell(
                  onTap: busy ? null : () => _editWebsite(b),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.link, size: 16, color: Colors.grey.shade600),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            website.isEmpty
                                ? 'Add company website (for the designer)'
                                : website,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: website.isEmpty
                                    ? Colors.grey.shade500
                                    : _navy),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.edit, size: 14, color: Colors.grey.shade500),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _poolPlaceholder(String label) => Container(
        color: Colors.grey.shade100,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.theater_comedy, color: Colors.grey.shade400, size: 28),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          ],
        ),
      );

  Widget _anonymousInfo() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _purple.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.visibility_off_outlined, color: _purple),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Anonymous lists always use the shared Default / Anonymous pool '
                '(rotates daily) with a “Welcome to …” trust strip — never a '
                'branded banner. Manage that pool in the Default / Anonymous tab.',
                style: TextStyle(fontSize: 12.5, color: _purple),
              ),
            ),
          ],
        ),
      );
}
