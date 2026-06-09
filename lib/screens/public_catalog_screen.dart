import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../services/supabase_data_service.dart';

/// Public, login-free, read-only catalog opened via a stockist's private share
/// link (`/s/<token>`). Renders only that stockist's in-stock designs and a
/// WhatsApp contact button. Designed to be served from the Flutter‑Web build.
class PublicCatalogScreen extends StatefulWidget {
  final String token;
  const PublicCatalogScreen({super.key, required this.token});
  @override
  State<PublicCatalogScreen> createState() => _State();
}

class _State extends State<PublicCatalogScreen> {
  final _svc = SupabaseDataService();
  late Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = _svc.getPublicCatalog(widget.token);
  }

  Future<void> _whatsapp(Map<String, dynamic> stockist) async {
    final phone = '${stockist['country_code'] ?? '+91'}${stockist['phone'] ?? ''}'
        .replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.isEmpty) return;
    final msg = 'Hello ${stockist['name'] ?? ''}, I saw your catalog and '
        'would like to enquire about some designs.';
    final uri =
        Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(msg)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null) {
            return _unavailable();
          }
          final stockist = Map<String, dynamic>.from(data['stockist'] ?? {});
          final designs = (data['designs'] as List?) ?? const [];
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: const Color(0xFF1B4F72),
                foregroundColor: Colors.white,
                title: Text(stockist['name']?.toString() ?? 'Catalog'),
                actions: [
                  TextButton.icon(
                    onPressed: () => _whatsapp(stockist),
                    icon: const Icon(Icons.chat_rounded,
                        size: 18, color: Colors.white),
                    label: const Text('WhatsApp',
                        style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '${designs.length} designs in stock'
                    '${(stockist['city'] ?? '').toString().isNotEmpty ? ' · ${stockist['city']}' : ''}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              ),
              if (designs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                      child: Text('No designs in stock right now.',
                          style: TextStyle(color: Colors.grey))),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverMasonryGrid.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childCount: designs.length,
                    itemBuilder: (_, i) =>
                        _card(Map<String, dynamic>.from(designs[i])),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FutureBuilder<Map<String, dynamic>?>(
        future: _future,
        builder: (_, snap) {
          final stockist = snap.data?['stockist'];
          if (stockist == null) return const SizedBox.shrink();
          return FloatingActionButton.extended(
            onPressed: () => _whatsapp(Map<String, dynamic>.from(stockist)),
            backgroundColor: const Color(0xFF25D366),
            icon: const Icon(Icons.chat_rounded, color: Colors.white),
            label: const Text('Enquire on WhatsApp',
                style: TextStyle(color: Colors.white)),
          );
        },
      ),
    );
  }

  Widget _unavailable() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.link_off_rounded, size: 72, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('Catalog not available',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            Text('This link may be invalid or the stockist is currently inactive.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ],
        ),
      );

  Widget _card(Map<String, dynamic> d) {
    final images = (d['images'] as List?) ?? const [];
    final img = images.isNotEmpty ? images.first.toString() : '';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: img.isEmpty
                ? Container(
                    color: Colors.grey.shade100,
                    child: Icon(Icons.image_not_supported,
                        size: 32, color: Colors.grey.shade400))
                : CachedNetworkImage(
                    imageUrl: img,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: Colors.grey.shade200),
                    errorWidget: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image)),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((d['name'] ?? '').toString(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                    [
                      (d['size'] ?? '').toString().replaceAll(' mm', ''),
                      (d['surface'] ?? '').toString(),
                      (d['quality'] ?? '').toString(),
                    ].where((x) => x.isNotEmpty).join(' · '),
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 4),
                Text('${d['boxes']} boxes',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2E7D32))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
