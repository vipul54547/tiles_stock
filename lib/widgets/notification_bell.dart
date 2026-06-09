import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/supabase_data_service.dart';

/// AppBar bell that shows the unread notification count and opens the inbox.
/// Refreshes its count when it reappears (e.g. returning from the inbox).
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});
  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  final _svc = SupabaseDataService();
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final n = await _svc.getUnreadNotificationCount();
    if (mounted) setState(() => _unread = n);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Notifications',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_outlined),
          if (_unread > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
                child: Text(_unread > 99 ? '99+' : '$_unread',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
      onPressed: () async {
        await context.push('/notifications');
        _refresh();
      },
    );
  }
}
