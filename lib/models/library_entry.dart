/// One MASTER design in a stockist's own Design Library: a physical tile with its
/// own image, identified by master design name + size, carrying the design name it
/// has under each of the stockist's brands (aliases). The image is shared across
/// the stockist's OWN brands only — never borrowed from another stockist.
/// (project_stockist_library)
class LibraryEntry {
  final String id;
  final String size;
  final String masterName;
  final String imageUrl;

  /// brand_id -> the design's name under that brand.
  final Map<String, String> aliases;

  const LibraryEntry({
    required this.id,
    required this.size,
    required this.masterName,
    this.imageUrl = '',
    this.aliases = const {},
  });

  factory LibraryEntry.fromJson(Map<String, dynamic> j) {
    final aliases = <String, String>{};
    for (final a in (j['aliases'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(a as Map);
      final bid = (m['brand_id'] ?? '').toString();
      final name = (m['name'] ?? '').toString();
      if (bid.isNotEmpty && name.isNotEmpty) aliases[bid] = name;
    }
    return LibraryEntry(
      id: (j['id'] ?? '').toString(),
      size: (j['size'] ?? '').toString(),
      masterName: (j['master_design_name'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
      aliases: aliases,
    );
  }
}
