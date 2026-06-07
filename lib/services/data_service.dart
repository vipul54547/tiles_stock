import 'package:flutter/services.dart';
import '../models/tile_design.dart';
import '../models/stockist.dart';
import '../models/end_user.dart';
import '../models/inquiry.dart';

abstract class DataService {
  Future<List<TileDesign>> getAllDesigns();
  Future<List<TileDesign>> getDesignsByStockist(String stockistId);
  Future<List<TileDesign>> searchDesigns({
    String? stockistId,
    List<String>? sizes,
    List<String>? surfaceTypes,
    List<String>? colours,
    List<String>? qualities,
    String? stockType,
    int? minQty,
    int? maxQty,
  });
  Future<void> addDesign(TileDesign design);
  Future<void> updateDesign(TileDesign design);
  Future<List<Stockist>> getAllStockists();
  Future<Stockist?> getStockistById(String id);
  Future<String> createStockist(Map<String, dynamic> data);
  Future<void> sendInquiry(Inquiry inquiry);
  Future<List<Inquiry>> getInquiriesForStockist(String stockistId);
  Future<List<Inquiry>> getInquiriesForUser(String userId);
  Future<EndUser?> getEndUser(String userId);
  Future<void> updateEndUser(EndUser user);
}

class MockDataService implements DataService {
  static const _sizeMap = {
    '600x600':  '600x600 mm',
    '400x400':  '400x400 mm',
    '300x600':  '300x600 mm',
    '600x1200': '600x1200 mm',
  };

  static const _piecesPerBox = {
    '600x600 mm':  4,
    '400x400 mm':  6,
    '300x600 mm':  8,
    '600x1200 mm': 2,
  };

  static const _colours   = ['White', 'Beige', 'Grey', 'Black', 'Cream'];
  static const _qualities = ['Premium', 'Standard'];
  static const _stocks    = ['One Time', 'Regular'];

  // ── fallback mock data (used when no asset images found) ──────────────────
  static const _stockistProfiles = [
    (id: '001', count: 150, avg: 150),
    (id: '002', count: 120, avg: 170),
    (id: '003', count: 200, avg: 120),
    (id: '004', count: 100, avg: 200),
    (id: '005', count: 180, avg: 130),
    (id: '006', count: 600, avg:  35),
    (id: '007', count: 500, avg:  40),
    (id: '008', count: 450, avg:  45),
    (id: '009', count:  50, avg:  70),
    (id: '010', count:  60, avg:  80),
    (id: '011', count:  70, avg:  70),
    (id: '012', count:  55, avg:  90),
    (id: '013', count: 100, avg:  32),
    (id: '014', count: 120, avg:  26),
    (id: '015', count: 150, avg:  21),
    (id: '016', count:  80, avg:  40),
    (id: '017', count:  90, avg:  38),
    (id: '018', count:  70, avg:  45),
    (id: '019', count:  60, avg:  52),
    (id: '020', count:  50, avg:  62),
  ];
  static const _sizes    = ['600x600 mm', '400x400 mm', '300x600 mm', '600x1200 mm'];
  static const _surfaces = ['Matt', 'Glossy', 'Satin', 'Carving'];
  static const _series   = ['Marble', 'Granite', 'Ceramic', 'Porcelain', 'Travertine', 'Slate'];
  static const _grades   = ['Elite', 'Classic', 'Premium', 'Royal', 'Standard', 'Prime', 'Luxury', 'Urban'];

  static const _stockistIds = [
    '001','002','003','004','005','006','007','008','009','010',
    '011','012','013','014','015','016','017','018','019','020',
  ];

  // ── cached future ─────────────────────────────────────────────────────────
  Future<List<TileDesign>>? _designsFuture;

  Future<List<TileDesign>> _getDesigns() {
    _designsFuture ??= _loadDesigns();
    return _designsFuture!;
  }

  Future<List<TileDesign>> _loadDesigns() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final imagePaths = manifest.listAssets().where((p) =>
          p.startsWith('assets/images/') &&
          (p.endsWith('.jpg') || p.endsWith('.jpeg') ||
           p.endsWith('.png') || p.endsWith('.webp'))).toList();

      if (imagePaths.isNotEmpty) return _buildFromAssets(imagePaths);
    } catch (_) {}
    return _buildMockDesigns();
  }

  // path format: assets/images/{size}/{finish}/{Design Name}.jpg
  List<TileDesign> _buildFromAssets(List<String> paths) {
    final designs = <TileDesign>[];
    var i = 0;
    for (final path in paths) {
      final parts = path.split('/');
      if (parts.length < 5) continue;

      final size = _sizeMap[parts[2]];
      if (size == null) continue;

      final finish   = parts[3];
      final fileName = parts[4];
      final name     = fileName.contains('.')
          ? fileName.substring(0, fileName.lastIndexOf('.'))
          : fileName;

      designs.add(TileDesign(
        id:           'design_$i',
        name:         name,
        size:         size,
        surfaceType:  finish,
        faceImageUrls: [path],
        stockistId:   _stockistIds[i % _stockistIds.length],
        colour:       _colours[i % _colours.length],
        quality:      _qualities[i % _qualities.length],
        stockType:    _stocks[i % _stocks.length],
        boxQuantity:  20 + (i * 7) % 180,
        piecesPerBox: _piecesPerBox[size] ?? 4,
        boxWeightKg:  18.0 + (i % 10) * 0.5,
        thicknessMm:  8.0 + (i % 3),
        boxPrice:     800.0 + (i % 20) * 50.0,
        updatedAt:    DateTime.now().subtract(Duration(days: i % 60)),
      ));
      i++;
    }
    return designs;
  }

  static int _boxQty(int avg, int localIdx) {
    const offsets = [-3, -2, -1, 0, 1, 2, 3];
    final step = (avg / 5).round().clamp(1, avg);
    return (avg + offsets[localIdx % offsets.length] * step).clamp(1, 999999);
  }

  List<TileDesign> _buildMockDesigns() {
    final designs = <TileDesign>[];
    var g = 0;
    for (final p in _stockistProfiles) {
      for (var j = 0; j < p.count; j++) {
        designs.add(TileDesign(
          id:           'design_$g',
          name:         '${_series[g % _series.length]} ${_grades[g % _grades.length]}',
          size:         _sizes[g % _sizes.length],
          surfaceType:  _surfaces[g % _surfaces.length],
          faceImageUrls: [],
          stockistId:   p.id,
          colour:       _colours[g % _colours.length],
          quality:      _qualities[g % _qualities.length],
          stockType:    _stocks[g % _stocks.length],
          boxQuantity:  _boxQty(p.avg, j),
          piecesPerBox: [4, 6, 8][g % 3],
          boxWeightKg:  18.5 + (g % 10) * 0.5,
          thicknessMm:  8.0 + (g % 3),
          boxPrice:     800.0 + (g % 20) * 50.0,
          updatedAt:    DateTime.now().subtract(Duration(days: g % 60)),
        ));
        g++;
      }
    }
    return designs;
  }

  @override
  Future<List<TileDesign>> getAllDesigns() async => _getDesigns();

  @override
  Future<List<TileDesign>> getDesignsByStockist(String stockistId) async {
    final all = await _getDesigns();
    return all.where((d) => d.stockistId == stockistId).toList();
  }

  @override
  Future<List<TileDesign>> searchDesigns({
    String? stockistId,
    List<String>? sizes,
    List<String>? surfaceTypes,
    List<String>? colours,
    List<String>? qualities,
    String? stockType,
    int? minQty,
    int? maxQty,
  }) async {
    final all = await _getDesigns();
    return all.where((d) {
      if (stockistId != null && d.stockistId != stockistId) return false;
      if (sizes != null && sizes.isNotEmpty && !sizes.contains(d.size)) return false;
      if (surfaceTypes != null && surfaceTypes.isNotEmpty && !surfaceTypes.contains(d.surfaceType)) return false;
      if (colours != null && colours.isNotEmpty && !colours.contains(d.colour)) return false;
      if (qualities != null && qualities.isNotEmpty && !qualities.contains(d.quality)) return false;
      if (stockType != null && d.stockType != stockType) return false;
      if (minQty != null && d.boxQuantity < minQty) return false;
      if (maxQty != null && d.boxQuantity > maxQty) return false;
      return true;
    }).toList();
  }

  @override Future<void> addDesign(TileDesign design) async {}
  @override Future<void> updateDesign(TileDesign design) async {}

  @override
  Future<List<Stockist>> getAllStockists() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return [
      Stockist(id: '001', name: 'Raj Tiles',          email: 'raj@tiles.com',       phone: '9876543210', city: 'Ahmedabad', state: 'Gujarat',       address: '123 Tile Market, Odhav',          createdAt: DateTime(2023, 1, 15)),
      Stockist(id: '002', name: 'Krishna Ceramics',   email: 'krishna@ceramics.com', phone: '9876543211', city: 'Surat',     state: 'Gujarat',       address: '45 Ceramic Hub, Ring Road',       createdAt: DateTime(2023, 2, 10)),
      Stockist(id: '003', name: 'Modern Tiles Co.',   email: 'info@moderntiles.com', phone: '9876543212', city: 'Mumbai',    state: 'Maharashtra',   address: '78 Industrial Area, Andheri',     createdAt: DateTime(2023, 3,  5)),
      Stockist(id: '004', name: 'Premium Floor World',email: 'floor@premium.com',    phone: '9876543213', city: 'Pune',      state: 'Maharashtra',   address: '12 Floor World Complex, Wakad',   createdAt: DateTime(2023, 4, 20)),
      Stockist(id: '005', name: 'City Tile Centre',   email: 'info@citytile.com',    phone: '9876543214', city: 'Bangalore', state: 'Karnataka',     address: '56 City Centre, Koramangala',     createdAt: DateTime(2023, 5,  1)),
      Stockist(id: '006', name: 'Star Ceramics',      email: 'star@ceramics.com',    phone: '9876543215', city: 'Delhi',     state: 'Delhi',         address: '90 Ceramic Zone, Rohini',         createdAt: DateTime(2023, 5, 15)),
      Stockist(id: '007', name: 'Golden Tiles',       email: 'info@goldentiles.com', phone: '9876543216', city: 'Jaipur',    state: 'Rajasthan',     address: '34 Golden Plaza, MI Road',        createdAt: DateTime(2023, 6,  1)),
      Stockist(id: '008', name: 'Royal Floor',        email: 'royal@floor.com',      phone: '9876543217', city: 'Chennai',   state: 'Tamil Nadu',    address: '67 Floor World, Anna Nagar',      createdAt: DateTime(2023, 6, 20)),
      Stockist(id: '009', name: 'Elite Tiles',        email: 'elite@tiles.com',      phone: '9876543218', city: 'Hyderabad', state: 'Telangana',     address: '23 Elite Hub, Banjara Hills',     createdAt: DateTime(2023, 7,  5)),
      Stockist(id: '010', name: 'Sunshine Tiles',     email: 'sunshine@tiles.com',   phone: '9876543219', city: 'Kolkata',   state: 'West Bengal',   address: '89 Sunshine Complex, Salt Lake',  createdAt: DateTime(2023, 7, 20)),
      Stockist(id: '011', name: 'Blue Marble',        email: 'blue@marble.com',      phone: '9876543220', city: 'Ahmedabad', state: 'Gujarat',       address: '45 Marble Street, Satellite',     createdAt: DateTime(2023, 8,  1)),
      Stockist(id: '012', name: 'Classic Ceramics',   email: 'classic@ceramics.com', phone: '9876543221', city: 'Surat',     state: 'Gujarat',       address: '12 Classic Zone, Adajan',         createdAt: DateTime(2023, 8, 15)),
      Stockist(id: '013', name: 'New Age Tiles',      email: 'newage@tiles.com',     phone: '9876543222', city: 'Mumbai',    state: 'Maharashtra',   address: '56 New Age Plaza, Thane',         createdAt: DateTime(2023, 9,  1)),
      Stockist(id: '014', name: 'Grand Flooring',     email: 'grand@flooring.com',   phone: '9876543223', city: 'Pune',      state: 'Maharashtra',   address: '78 Grand Complex, Kothrud',       createdAt: DateTime(2023, 9, 15)),
      Stockist(id: '015', name: 'Metro Tiles',        email: 'metro@tiles.com',      phone: '9876543224', city: 'Bangalore', state: 'Karnataka',     address: '34 Metro Hub, Whitefield',        createdAt: DateTime(2023, 10, 1)),
      Stockist(id: '016', name: 'Crystal Floor',      email: 'crystal@floor.com',    phone: '9876543225', city: 'Delhi',     state: 'Delhi',         address: '90 Crystal Zone, Dwarka',         createdAt: DateTime(2023, 10, 15)),
      Stockist(id: '017', name: 'Diamond Tiles',      email: 'diamond@tiles.com',    phone: '9876543226', city: 'Jaipur',    state: 'Rajasthan',     address: '23 Diamond Plaza, Vaishali Nagar',createdAt: DateTime(2023, 11, 1)),
      Stockist(id: '018', name: 'Silver Stone',       email: 'silver@stone.com',     phone: '9876543227', city: 'Chennai',   state: 'Tamil Nadu',    address: '67 Silver Hub, T. Nagar',         createdAt: DateTime(2023, 11, 15)),
      Stockist(id: '019', name: 'Green Earth Tiles',  email: 'green@earth.com',      phone: '9876543228', city: 'Hyderabad', state: 'Telangana',     address: '45 Green Complex, Gachibowli',    createdAt: DateTime(2023, 12, 1)),
      Stockist(id: '020', name: 'Prime Ceramics',     email: 'prime@ceramics.com',   phone: '9876543229', city: 'Kolkata',   state: 'West Bengal',   address: '12 Prime Zone, New Town',         createdAt: DateTime(2023, 12, 15)),
    ];
  }

  @override Future<Stockist?> getStockistById(String id) async => null;
  @override Future<String> createStockist(Map<String, dynamic> data) async => '021';
  @override Future<void> sendInquiry(Inquiry inquiry) async {}
  @override Future<List<Inquiry>> getInquiriesForStockist(String stockistId) async => [];
  @override Future<List<Inquiry>> getInquiriesForUser(String userId) async => [];
  @override Future<EndUser?> getEndUser(String userId) async => null;
  @override Future<void> updateEndUser(EndUser user) async {}
}
