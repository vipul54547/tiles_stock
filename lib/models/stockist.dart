class Stockist {

  final String id;

  final String name;

  final String email;

  final String phone;

  final String city;

  final String state;

  final String address;

  /// Display/boost weight for this stockist (stored as 0.00). Not yet used for
  /// any ordering — kept for future use.
  final double priority;

  /// Optional GST number.
  final String gstNumber;

  /// Optional tier label (e.g. Gold / Platinum / Silver). Free text, for
  /// future use.
  final String stockistType;

  final bool isActive;

  final DateTime createdAt;



  Stockist({

    required this.id,

    required this.name,

    required this.email,

    required this.phone,

    required this.city,

    required this.state,

    required this.address,

    this.priority = 0,

    this.gstNumber = '',

    this.stockistType = '',

    this.isActive = true,

    required this.createdAt,

  });



  factory Stockist.fromJson(Map<String, dynamic> json) => Stockist(

    id: json['id'],

    name: json['name'],

    email: json['email'],

    phone: json['phone'],

    city: json['city'],

    state: json['state'],

    address: json['address'],

    priority: (json['priority'] as num?)?.toDouble() ?? 0,

    gstNumber: json['gst_number'] ?? '',

    stockistType: json['stockist_type'] ?? '',

    isActive: json['is_active'] ?? true,

    createdAt: DateTime.parse(json['created_at']),

  );

}