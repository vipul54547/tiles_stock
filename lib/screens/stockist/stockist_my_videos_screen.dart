import 'package:flutter/material.dart';
import '../../services/supabase_data_service.dart';

/// Stockist "My Videos": a stockist adds/edits their OWN collection/promo
/// videos for the Banner Video slot. They can always ADD; whether the videos
/// DISPLAY is governed by the admin-set mode (shown read-only at the top).
/// Caps: 50 in the library, 5 shown at once (enforced server-side).
/// (project_tutorial_videos_plan — Banner Video, step 4)
class StockistMyVideosScreen extends StatefulWidget {
  const StockistMyVideosScreen({super.key});
  @override
  State<StockistMyVideosScreen> createState() => _State();
}

const _navy = Color(0xFF1B4F72);

String? _ytId(String url) {
  final m =
      RegExp(r'(?:youtu\.be/|[?&]v=|/shorts/|/embed/|/live/)([A-Za-z0-9_-]{11})')
          .firstMatch(url);
  if (m != null) return m.group(1);
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(url.trim())) return url.trim();
  return null;
}

class _State extends State<StockistMyVideosScreen> {
  final _data = SupabaseDataService();
  List<Map<String, dynamic>> _videos = [];
  String _mode = 'mixed';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait([
        _data.stockistMyVideos(),
        _data.stockistMyVideoMode(),
      ]);
      if (!mounted) return;
      setState(() {
        _videos = res[0] as List<Map<String, dynamic>>;
        _mode = res[1] as String;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load: $e', error: true);
    }
  }

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: error ? Colors.red : null));
  }

  String get _modeNote {
    switch (_mode) {
      case 'off':
        return 'The video banner is currently OFF for your page. Your videos '
            'are saved; ask us to turn it on.';
      case 'admin':
        return 'Right now only our learning videos show on your page. Your '
            'videos are saved — ask us to enable yours.';
      case 'stockist':
        return 'Your own videos play on your page.';
      case 'mixed':
      default:
        return 'Your videos play on your page, blended with our learning '
            'videos (2 of yours to every 1 of ours).';
    }
  }

  Future<void> _toggle(Map<String, dynamic> v) async {
    final id = v['id'] as String;
    final next = !(v['is_active'] as bool? ?? true);
    setState(() => v['is_active'] = next);
    try {
      await _data.stockistSetVideoActive(id, next);
    } catch (e) {
      setState(() => v['is_active'] = !next);
      _snack('Could not update: $e', error: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete video?'),
        content: const Text(
            'It stops showing right away. You have 24 hours to restore it '
            'before it is purged.'),
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
      await _data.stockistDeleteVideo(v['id'] as String);
      await _load();
    } catch (e) {
      _snack('Could not delete: $e', error: true);
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _EditSheet(existing: existing, data: _data),
    );
    if (saved == true) {
      await _load();
      _snack('Saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _videos.where((v) => v['is_active'] == true).length;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: const Text('My Videos')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add video'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, 90 + MediaQuery.viewPaddingOf(context).bottom),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _navy.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, color: _navy),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                              'Show your new-collection / promo videos in your '
                              'catalogue banner. $active of 5 shown. $_modeNote',
                              style:
                                  const TextStyle(fontSize: 12.5, color: _navy)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_videos.isEmpty)
                    _empty()
                  else
                    ..._videos.map(_tile),
                ],
              ),
            ),
    );
  }

  Widget _empty() => Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(children: [
          Icon(Icons.video_library_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text('No videos yet',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Text('Tap “Add video” to add your first one.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ]),
      );

  Widget _tile(Map<String, dynamic> v) {
    final act = v['is_active'] as bool? ?? true;
    final kind = (v['kind'] ?? 'tutorial').toString();
    final thumb = (v['thumbnail'] ?? '').toString();
    final title = (v['title'] ?? '').toString();
    final subtitle = (v['subtitle'] ?? '').toString();
    final tutorial = kind == 'tutorial';
    final chipColor = tutorial ? _navy : const Color(0xFFB9770E);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: act ? 1 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => _edit(v),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: thumb.isEmpty
                        ? Container(color: Colors.grey.shade200)
                        : Image.network(thumb,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.broken_image))),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: chipColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                                tutorial ? '▶ Tutorial' : '✦ Collection',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: chipColor)),
                          ),
                          const SizedBox(height: 6),
                          Text(title.isEmpty ? '(no title)' : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14)),
                          if (subtitle.isNotEmpty)
                            Text(subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Row(
              children: [
                const SizedBox(width: 8),
                Icon(act ? Icons.check_circle : Icons.visibility_off,
                    size: 16,
                    color: act ? const Color(0xFF2E7D32) : Colors.grey),
                const SizedBox(width: 6),
                Text(act ? 'Showing' : 'Hidden',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: act ? const Color(0xFF2E7D32) : Colors.grey)),
                const Spacer(),
                Switch(
                  value: act,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggle(v),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, color: _navy),
                  onPressed: () => _edit(v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _delete(v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Add / edit sheet ────────────────────────────────────────────────────────
class _EditSheet extends StatefulWidget {
  const _EditSheet({this.existing, required this.data});
  final Map<String, dynamic>? existing;
  final SupabaseDataService data;
  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _url;
  late final TextEditingController _title;
  late final TextEditingController _subtitle;
  late String _kind;
  late bool _active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _url = TextEditingController(text: (e?['video_url'] ?? '').toString());
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _subtitle = TextEditingController(text: (e?['subtitle'] ?? '').toString());
    _kind = (e?['kind'] ?? 'collection').toString();
    _active = e?['is_active'] as bool? ?? true;
    _url.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final id = _ytId(_url.text);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That doesn’t look like a YouTube link.'),
          backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.data.stockistSaveVideo(
        id: widget.existing?['id'] as String?,
        kind: _kind,
        title: _title.text.trim(),
        subtitle: _subtitle.text.trim(),
        url: _url.text.trim(),
        isActive: _active,
        sortOrder: (widget.existing?['sort_order'] as int?) ?? 0,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        // Surface the server's friendly message (e.g. the 5-shown / 50-library
        // cap) without the PostgrestException wrapper.
        final msg = e.toString().contains('message:')
            ? e.toString().split('message:').last.split(',').first.trim()
            : 'Could not save. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _ytId(_url.text);
    final editing = widget.existing != null;
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    final navBar = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(
          left: 20, right: 20, top: 18, bottom: 18 + (kb > navBar ? kb : navBar)),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(editing ? 'Edit video' : 'Add your video',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'collection', label: Text('Collection')),
                ButtonSegment(value: 'tutorial', label: Text('Tutorial')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'YouTube link',
                hintText: 'https://youtu.be/… or /shorts/…',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            if (_url.text.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              if (id != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      'https://img.youtube.com/vi/$id/hqdefault.jpg',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image)),
                    ),
                  ),
                )
              else
                Row(children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Can’t read a video id from that link.',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.red.shade700)),
                  ),
                ]),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'New Marble Series',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subtitle,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Subtitle (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              activeThumbColor: _navy,
              title: const Text('Show now'),
              subtitle: Text(
                  _active
                      ? 'Counts toward your 5 shown videos.'
                      : 'Kept in your library, not shown.',
                  style: const TextStyle(fontSize: 12)),
              onChanged: (v) => setState(() => _active = v),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: _navy,
                  minimumSize: const Size.fromHeight(48)),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(editing ? 'Save changes' : 'Add video'),
            ),
          ],
        ),
      ),
    );
  }
}
