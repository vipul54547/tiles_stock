import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';

/// Admin: the shared Default / Anonymous banner pool — logo-free 1500×600 (2.5:1)
/// art shown on anonymous lists, as the fallback, and as the "Library" backgrounds
/// admins pick per brand (Manage brands & lists). One is picked per day
/// (pick_generic_banner). Per-brand banners live on the brand card, not here.
/// (project_admin_banner_system / project_brand_admin_console)
class ManageBannersScreen extends StatefulWidget {
  const ManageBannersScreen({super.key});
  @override
  State<ManageBannersScreen> createState() => _State();
}

class _State extends State<ManageBannersScreen> {
  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _banners = [];
  bool _loading = true;
  bool _uploading = false;
  // 'generic' = decorative pool; 'text' = clean backgrounds for message banners.
  String _kind = 'generic';

  static const Color _navy = Color(0xFF1B4F72);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final banners = await _data.getGenericBanners(kind: _kind);
    if (!mounted) return;
    setState(() {
      _banners = banners;
      _loading = false;
    });
  }

  Future<void> _upload() async {
    final x = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: 2000, imageQuality: 88);
    if (x == null) return;
    setState(() => _uploading = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (url != null) {
      try {
        await _data.addGenericBanner(url, kind: _kind);
        await _load();
      } catch (e) {
        _snack('Could not save banner: $e', error: true);
      }
    } else {
      _snack('Upload failed. Try again.', error: true);
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _toggle(Map<String, dynamic> b) async {
    final id = b['id'] as String;
    final next = !(b['is_active'] as bool? ?? true);
    setState(() => b['is_active'] = next);
    try {
      await _data.setBannerActive(id, next);
    } catch (e) {
      setState(() => b['is_active'] = !next);
      _snack('Could not update: $e', error: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete banner?'),
        content: const Text(
            'This removes it from the pool. Pages that picked it today fall '
            'back to another banner.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _data.deleteBanner(b['id'] as String);
      await _load();
    } catch (e) {
      _snack('Could not delete: $e', error: true);
    }
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
      appBar: AppBar(title: const Text('Catalog Banners')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _upload,
        backgroundColor: _navy,
        icon: _uploading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.add_photo_alternate_outlined),
        label: Text(_uploading
            ? 'Uploading…'
            : (_kind == 'text' ? 'Upload text background' : 'Upload banner')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _poolTab(),
    );
  }

  Widget _poolTab() {
    final activeCount = _banners.where((b) => b['is_active'] == true).length;
    final isText = _kind == 'text';
    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 90 + MediaQuery.viewPaddingOf(context).bottom),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 'generic', label: Text('Decorative')),
              ButtonSegment(value: 'text', label: Text('Text backgrounds')),
            ],
            selected: {_kind},
            onSelectionChanged: _uploading
                ? null
                : (s) {
                    setState(() {
                      _kind = s.first;
                      _loading = true;
                    });
                    _load();
                  },
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _navy.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(isText ? Icons.text_fields : Icons.theater_comedy,
                  color: _navy),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    isText
                        ? 'Text backgrounds — $activeCount active. Clean, low-detail '
                            'art for stockists\' message banners (order conditions '
                            'etc). Upload calm 1500×600 images so white text stays '
                            'readable.'
                        : 'Default / Anonymous pool — $activeCount active. Shown on '
                            'anonymous lists and as the fallback. One is picked per day, '
                            'so upload several (1500×600, 2.5:1).',
                    style: const TextStyle(fontSize: 12.5, color: _navy)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_banners.isEmpty)
          _empty('No banners yet', 'Tap “Upload banner” to add the first one.')
        else
          ..._banners.map(_poolTile),
      ],
    );
  }

  Widget _empty(String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(
          children: [
            Icon(Icons.image_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _poolTile(Map<String, dynamic> b) {
    final active = b['is_active'] as bool? ?? true;
    final url = (b['image_url'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Opacity(
            opacity: active ? 1 : 0.4,
            child: AspectRatio(
              aspectRatio: 2.5,
              child: Image.network(url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.broken_image))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(active ? Icons.check_circle : Icons.visibility_off,
                    size: 16,
                    color: active ? const Color(0xFF2E7D32) : Colors.grey),
                const SizedBox(width: 6),
                Text(active ? 'Active' : 'Hidden',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: active ? const Color(0xFF2E7D32) : Colors.grey)),
                const Spacer(),
                Switch(
                  value: active,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggle(b),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _delete(b),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
