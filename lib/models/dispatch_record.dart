// A dispatch note (DSP-xxxxxx) as the BUYER sees it: what a supplier actually
// shipped against one of the buyer's orders, with the truck/invoice details and
// the per-design boxes. Read-only buyer history — no rates, by design.
//
// Built from the `my_dispatches()` RPC, which masks the stockist name when the
// supplier is anonymous (same rule as my_orders()).

class DispatchLine {
  final String designId;
  final String designName;
  final String size;
  final String surface;
  final String image;
  final int quantity;

  DispatchLine({
    required this.designId,
    required this.designName,
    required this.size,
    required this.surface,
    required this.image,
    required this.quantity,
  });

  factory DispatchLine.fromJson(Map<String, dynamic> j) => DispatchLine(
        designId:   (j['design_id'] ?? '').toString(),
        designName: (j['design_name'] ?? '').toString(),
        size:       (j['size'] ?? '').toString(),
        surface:    (j['surface'] ?? '').toString(),
        image:      (j['image'] ?? '').toString(),
        quantity:   (j['quantity'] as num?)?.toInt() ?? 0,
      );
}

class DispatchRecord {
  final String id;
  final String dispatchNo;     // DSP-000001
  final String token;          // the order it shipped against (INQ-…)
  final String stockistName;   // anonymity-masked
  final DateTime? dispatchedOn;
  final DateTime createdAt;
  final String invoiceNo;
  final String vehicleNo;
  final String transporter;
  final String note;
  final int totalBoxes;
  final List<DispatchLine> lines;

  DispatchRecord({
    required this.id,
    required this.dispatchNo,
    required this.token,
    required this.stockistName,
    required this.dispatchedOn,
    required this.createdAt,
    required this.invoiceNo,
    required this.vehicleNo,
    required this.transporter,
    required this.note,
    required this.totalBoxes,
    required this.lines,
  });

  static DateTime _dt(dynamic v) =>
      v == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.parse(v.toString());
  static DateTime? _dtn(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  factory DispatchRecord.fromJson(Map<String, dynamic> j) => DispatchRecord(
        id:           (j['id'] ?? '').toString(),
        dispatchNo:   (j['dispatch_no'] ?? '').toString(),
        token:        (j['token'] ?? '').toString(),
        stockistName: (j['stockist_name'] ?? '').toString(),
        dispatchedOn: _dtn(j['dispatched_on']),
        createdAt:    _dt(j['created_at']),
        invoiceNo:    (j['invoice_no'] ?? '').toString(),
        vehicleNo:    (j['vehicle_no'] ?? '').toString(),
        transporter:  (j['transporter'] ?? '').toString(),
        note:         (j['note'] ?? '').toString(),
        totalBoxes:   (j['total_boxes'] as num?)?.toInt() ?? 0,
        lines: (j['lines'] as List?)
                ?.map((e) => DispatchLine.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
      );

  /// The date to show/sort by: the supplier-entered dispatch date when present,
  /// otherwise when the record was created.
  DateTime get effectiveDate => dispatchedOn ?? createdAt;
}
