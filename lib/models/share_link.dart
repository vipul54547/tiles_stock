/// A stockist's public-catalog share link. The always-on "Permanent" link comes
/// from `stockists.share_token` (id == null, not revocable); the extra
/// create-on-demand links live in `stockist_share_links` and can expire / be
/// revoked. Built from the `my_share_links()` RPC rows.
class ShareLink {
  final String? id; // null for the permanent share_token link
  final String token;
  final String label; // "Permanent", "1 week", "1 month", …
  final DateTime? expiresAt; // null = never expires
  final DateTime? createdAt;
  final bool expired;
  final bool revocable;

  const ShareLink({
    required this.id,
    required this.token,
    required this.label,
    required this.expiresAt,
    required this.createdAt,
    required this.expired,
    required this.revocable,
  });

  factory ShareLink.fromJson(Map<String, dynamic> j) => ShareLink(
        id: j['id'] as String?,
        token: j['token'] as String? ?? '',
        label: j['label'] as String? ?? 'Link',
        expiresAt: j['expires_at'] != null
            ? DateTime.tryParse(j['expires_at'] as String)
            : null,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
        expired: j['expired'] as bool? ?? false,
        revocable: j['revocable'] as bool? ?? false,
      );
}

/// The durations offered when creating a link: (value sent to the RPC, label).
const List<({String value, String label})> kShareLinkDurations = [
  (value: 'permanent', label: 'Permanent'),
  (value: '1week', label: 'Valid 1 week'),
  (value: '1month', label: 'Valid 1 month'),
  (value: '3month', label: 'Valid 3 months'),
  (value: '6month', label: 'Valid 6 months'),
  (value: '1year', label: 'Valid 1 year'),
];
