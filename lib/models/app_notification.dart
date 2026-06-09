class AppNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final bool isRead;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        type: (j['type'] ?? 'info').toString(),
        title: (j['title'] ?? '').toString(),
        body: (j['body'] ?? '').toString(),
        isRead: j['is_read'] ?? false,
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
