class Stockist {

  final String id;

  final String name;

  final String email;

  final String phone;

  final String city;

  final String state;

  final String address;

  final DateTime createdAt;



  Stockist({

    required this.id,

    required this.name,

    required this.email,

    required this.phone,

    required this.city,

    required this.state,

    required this.address,

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

    createdAt: DateTime.parse(json['created_at']),

  );

} 