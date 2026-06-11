import 'package:flutter/material.dart';
import '../models/app_notification.dart';
import '../services/supabase_data_service.dart';

/// Unified in-app notification inbox for any signed-in role. RLS ensures each
/// user only sees their own notifications.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _State();
}

class _State extends State<NotificationsScreen> {
  final _svc = SupabaseDataService();
  late Future<List<AppNotification>> _future;

  @override
  void initState() {
    super.initState();
    _future = _svc.getNotifications();
  }

  Future<void> _reload() async {
    final f = _svc.getNotifications();
    setState(() { _future = f; });
    await f;
  }

  Future<void> _markAllRead() async {
    await _svc.markAllNotificationsRead();
    await _reload();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all notifications?'),
        content: const Text(
            'This permanently deletes all your notifications. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Clear all', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _svc.clearMyNotifications();
    await _reload();
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'interest':
        return Icons.bookmark_added_outlined;
      case 'inquiry_rejected':
        return Icons.block_outlined;
      case 'dispatch':
        return Icons.local_shipping_outlined;
      case 'registration':
        return Icons.person_add_alt_1_outlined;
      case 'account':
        return Icons.verified_user_outlined;
      case 'admin':
        return Icons.campaign_outlined;
      case 'stock_pending':
        return Icons.hourglass_top_rounded;
      case 'stock_approved':
        return Icons.check_circle_outline;
      case 'stock_rejected':
        return Icons.cancel_outlined;
      case 'stock_big_live':
        return Icons.inventory_2_outlined;
      default:
        return Icons.notifications_outlined;
    }
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} hr ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _markAllRead,
            child: const Text('Mark all read',
                style: TextStyle(color: Colors.white, fontSize: 12)),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'clear') _clearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear all')),
            ],
          ),
        ],
      ),
      body: FutureBuilder<List<AppNotification>>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none_rounded,
                      size: 72, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text('No notifications yet',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade500)),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _tile(items[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _tile(AppNotification n) {
    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline, color: Colors.red.shade400),
      ),
      onDismissed: (_) => _svc.deleteNotification(n.id),
      child: InkWell(
        onTap: () async {
          if (!n.isRead) {
            await _svc.markNotificationRead(n.id);
            await _reload();
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: n.isRead ? Colors.white : const Color(0xFFEAF2F8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: n.isRead ? Colors.grey.shade200 : const Color(0xFF1B4F72)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B4F72).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(_iconFor(n.type),
                    size: 20, color: const Color(0xFF1B4F72)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(n.title,
                              style: TextStyle(
                                  fontWeight: n.isRead
                                      ? FontWeight.w600
                                      : FontWeight.bold,
                                  fontSize: 14)),
                        ),
                        if (!n.isRead)
                          Container(
                            width: 8, height: 8,
                            decoration: const BoxDecoration(
                                color: Color(0xFF2E7D32),
                                shape: BoxShape.circle),
                          ),
                      ],
                    ),
                    if (n.body.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(n.body,
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade700)),
                    ],
                    const SizedBox(height: 4),
                    Text(_timeAgo(n.createdAt),
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
