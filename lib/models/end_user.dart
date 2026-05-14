class EndUser {

  final String id;

  final String companyName;

  final String contactPerson;

  final String email;

  final String phone;

  final String city;

  final String gstNumber;

  final int inquiriesToday;

  final DateTime lastInquiryDate;



  EndUser({

    required this.id,

    required this.companyName,

    required this.contactPerson,

    required this.email,

    required this.phone,

    required this.city,

    required this.gstNumber,

    required this.inquiriesToday,

    required this.lastInquiryDate,

  });



  bool get canSendInquiry {

    final today = DateTime.now();

    final sameDay = lastInquiryDate.year == today.year &&

        lastInquiryDate.month == today.month &&

        lastInquiryDate.day == today.day;

    return !sameDay || inquiriesToday < 10;

  }



  int get remainingInquiries {

    final today = DateTime.now();

    final sameDay = lastInquiryDate.year == today.year &&

        lastInquiryDate.month == today.month &&

        lastInquiryDate.day == today.day;

    return sameDay ? (10 - inquiriesToday).clamp(0, 10) : 10;

  }

} 