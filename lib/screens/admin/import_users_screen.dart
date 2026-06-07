import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import '../../main.dart';

// ── Row model ─────────────────────────────────────────────────────────────────

class _UserRow {
  final int rowNum;
  final String role;
  final String email;
  final String password;
  final String name;
  final String phone;
  final String city;
  final String state;
  final String address;
  final String sequentialId;
  final String contactPerson;
  final String gstNumber;

  String? validationError;
  String status = 'pending'; // pending | importing | success | failed
  String? resultMessage;

  _UserRow({
    required this.rowNum,
    required this.role,
    required this.email,
    required this.password,
    required this.name,
    required this.phone,
    required this.city,
    required this.state,
    required this.address,
    required this.sequentialId,
    required this.contactPerson,
    required this.gstNumber,
  }) {
    _validate();
  }

  void _validate() {
    if (role.isEmpty) { validationError = 'role is required'; return; }
    if (!['admin', 'stockist', 'end_user'].contains(role)) {
      validationError = 'role must be admin / stockist / end_user'; return;
    }
    if (email.isEmpty) { validationError = 'email is required'; return; }
    if (!email.contains('@')) { validationError = 'invalid email'; return; }
    if (password.length < 6) { validationError = 'password must be ≥ 6 chars'; return; }
    if (role == 'stockist') {
      if (sequentialId.isEmpty) { validationError = 'sequential_id required for stockist'; return; }
      if (name.isEmpty) { validationError = 'name required for stockist'; return; }
    }
    if (role == 'end_user') {
      if (name.isEmpty) { validationError = 'company_name required for end_user'; return; }
      if (contactPerson.isEmpty) { validationError = 'contact_person required for end_user'; return; }
    }
  }

  bool get isValid => validationError == null;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class ImportUsersScreen extends StatefulWidget {
  const ImportUsersScreen({super.key});
  @override
  State<ImportUsersScreen> createState() => _ImportUsersScreenState();
}

class _ImportUsersScreenState extends State<ImportUsersScreen> {
  List<_UserRow> _rows = [];
  bool _parsed    = false;
  bool _importing = false;
  int  _doneCount = 0;

  final _pathCtrl = TextEditingController();

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  // ── File loading ──────────────────────────────────────────────────────────

  Future<void> _loadFromPath() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      _showSnack('Please enter a file path.');
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      _showSnack('File not found:\n$path');
      return;
    }
    final bytes = await file.readAsBytes();
    await _parseBytes(bytes);
  }

  Future<void> _pickAndParse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;

    final bytes = result.files.single.bytes!;
    _pathCtrl.text = result.files.single.path ?? '';
    await _parseBytes(bytes);
  }

  Future<void> _parseBytes(List<int> bytes) async {
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel.tables[excel.tables.keys.first];
    if (sheet == null) {
      _showSnack('Could not read sheet from the file.');
      return;
    }

    final rows = sheet.rows;
    if (rows.isEmpty) {
      _showSnack('The sheet is empty.');
      return;
    }

    // Build header index from first row
    final header = rows.first
        .map((c) => c?.value?.toString().trim().toLowerCase() ?? '')
        .toList();

    int col(String name) => header.indexOf(name);

    String cell(List<Data?> row, String colName) {
      final i = col(colName);
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final parsed = <_UserRow>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      // skip fully empty rows
      if (row.every((c) => c == null || c.value == null || c.value.toString().trim().isEmpty)) {
        continue;
      }
      parsed.add(_UserRow(
        rowNum:        r + 1,
        role:          cell(row, 'role'),
        email:         cell(row, 'email'),
        password:      cell(row, 'password'),
        name:          cell(row, 'name'),
        phone:         cell(row, 'phone'),
        city:          cell(row, 'city'),
        state:         cell(row, 'state'),
        address:       cell(row, 'address'),
        sequentialId:  cell(row, 'sequential_id'),
        contactPerson: cell(row, 'contact_person'),
        gstNumber:     cell(row, 'gst_number'),
      ));
    }

    if (parsed.isEmpty) {
      _showSnack('No data rows found (only header?).');
      return;
    }

    setState(() {
      _rows    = parsed;
      _parsed  = true;
      _doneCount = 0;
    });
  }

  // ── Import ────────────────────────────────────────────────────────────────

  Future<void> _startImport() async {
    final validRows = _rows.where((r) => r.isValid).toList();
    if (validRows.isEmpty) {
      _showSnack('No valid rows to import.');
      return;
    }

    setState(() {
      _importing = true;
      _doneCount = 0;
    });

    for (final row in validRows) {
      setState(() => row.status = 'importing');
      try {
        await supabase.rpc('create_user_from_excel', params: {
          'p_email':          row.email,
          'p_password':       row.password,
          'p_role':           row.role,
          'p_sequential_id':  row.sequentialId.isEmpty  ? null : row.sequentialId,
          'p_name':           row.name.isEmpty           ? null : row.name,
          'p_phone':          row.phone,
          'p_city':           row.city,
          'p_state':          row.state,
          'p_address':        row.address,
          'p_company_name':   row.name.isEmpty           ? null : row.name,
          'p_contact_person': row.contactPerson.isEmpty  ? null : row.contactPerson,
          'p_gst_number':     row.gstNumber.isEmpty      ? null : row.gstNumber,
        });
        setState(() {
          row.status = 'success';
          _doneCount++;
        });
      } catch (e) {
        setState(() {
          row.status = 'failed';
          row.resultMessage = e.toString().replaceAll('PostgrestException:', '').trim();
          _doneCount++;
        });
      }
    }

    setState(() => _importing = false);
  }

  void _reset() => setState(() {
    _rows    = [];
    _parsed  = false;
    _importing = false;
    _doneCount = 0;
  });

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Users from Excel'),
        actions: [
          if (_parsed)
            TextButton.icon(
              onPressed: _importing ? null : _reset,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Reset', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _parsed ? _buildPreview() : _buildInstructions(),
    );
  }

  // ── Instructions screen ───────────────────────────────────────────────────

  Widget _buildInstructions() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1B4F72), Color(0xFF2E86C1)],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.upload_file_rounded, color: Colors.white, size: 40),
                SizedBox(height: 10),
                Text('Bulk User Import',
                    style: TextStyle(color: Colors.white, fontSize: 20,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text('Upload an .xlsx file to create admins, stockists,\n'
                    'and end users all at once.',
                    style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const Text('Required columns', style: TextStyle(
              fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 10),
          _columnTable(),

          const SizedBox(height: 20),
          _sampleSection(),

          const SizedBox(height: 28),

          // ── Path input ────────────────────────────────────────────────────
          const Text('Option 1 — paste the file path directly',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  decoration: InputDecoration(
                    hintText:
                        r'e.g. G:\tiles_stock login details\login detail file.xlsx',
                    hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                    prefixIcon: const Icon(Icons.insert_drive_file_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    isDense: false,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 54,
                child: ElevatedButton(
                  onPressed: _loadFromPath,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B4F72),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  child: const Text('Load',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: Divider(color: Colors.grey.shade300)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('OR',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
            ),
            Expanded(child: Divider(color: Colors.grey.shade300)),
          ]),
          const SizedBox(height: 16),

          // ── File picker ───────────────────────────────────────────────────
          const Text('Option 2 — browse for the file',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _pickAndParse,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Browse & Pick Excel File (.xlsx)',
                  style: TextStyle(fontSize: 15)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B4F72),
                side: const BorderSide(color: Color(0xFF1B4F72), width: 1.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnTable() {
    const cols = [
      ('role',           'admin / stockist / end_user',       true,  'All'),
      ('email',          'User email address',                 true,  'All'),
      ('password',       'Min 6 characters',                   true,  'All'),
      ('name',           'Stockist name OR company name',      true,  'Stockist, End User'),
      ('sequential_id',  'Display ID e.g. 001, 002',           true,  'Stockist'),
      ('contact_person', 'Contact person name',                true,  'End User'),
      ('phone',          'Phone number',                       false, 'All'),
      ('city',           'City',                               false, 'All'),
      ('state',          'State',                              false, 'Stockist'),
      ('address',        'Full address',                       false, 'Stockist'),
      ('gst_number',     'GST number',                         false, 'End User'),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1B4F72).withValues(alpha: 0.07),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: const Row(
              children: [
                Expanded(flex: 3, child: Text('Column', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                Expanded(flex: 4, child: Text('Description', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                Expanded(flex: 2, child: Text('For role', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                SizedBox(width: 56, child: Text('Req?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              ],
            ),
          ),
          ...cols.map((c) => Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey.shade100)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  children: [
                    Expanded(flex: 3,
                      child: Text(c.$1,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Color(0xFF1B4F72),
                              fontWeight: FontWeight.w600))),
                    Expanded(flex: 4,
                        child: Text(c.$2,
                            style: const TextStyle(fontSize: 11, color: Colors.black87))),
                    Expanded(flex: 2,
                        child: Text(c.$4,
                            style: const TextStyle(fontSize: 10, color: Colors.grey))),
                    SizedBox(
                      width: 56,
                      child: c.$3
                          ? const Icon(Icons.check_circle_rounded,
                              color: Color(0xFF2E7D32), size: 16)
                          : Text('optional',
                              style: TextStyle(
                                  fontSize: 9, color: Colors.grey.shade500)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _sampleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Sample rows', style: TextStyle(
            fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: Colors.grey.shade200, width: 0.5),
            children: [
              _sampleHeader(),
              _sampleRow(['admin',    'admin@co.com',    'Admin@123', 'Admin',       '', '', '', '', '',    '',        '']),
              _sampleRow(['stockist', 'raj@tiles.com',   'Stock@123', 'Raj Tiles',   '9876543210', 'Morbi', 'Gujarat', 'GIDC Area', '001', '',        '']),
              _sampleRow(['end_user', 'buyer@acme.com',  'Buy@1234',  'Acme Corp',   '9876543211', 'Ahmedabad', '', '', '',     'John Doe', '27ABC123']),
            ],
          ),
        ),
      ],
    );
  }

  TableRow _sampleHeader() {
    const headers = ['role','email','password','name','phone','city','state','address','sequential_id','contact_person','gst_number'];
    return TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade100),
      children: headers.map((h) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(h, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
      )).toList(),
    );
  }

  TableRow _sampleRow(List<String> cells) {
    return TableRow(
      children: cells.map((c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(c, style: const TextStyle(fontSize: 10, color: Colors.black87)),
      )).toList(),
    );
  }

  // ── Preview screen ────────────────────────────────────────────────────────

  Widget _buildPreview() {
    final valid   = _rows.where((r) => r.isValid).length;
    final invalid = _rows.length - valid;
    final allDone = _doneCount == valid && valid > 0 && !_importing;

    return Column(
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          child: Row(
            children: [
              _summaryChip('${_rows.length}', 'Total',   Colors.grey),
              const SizedBox(width: 10),
              _summaryChip('$valid',   'Valid',   const Color(0xFF2E7D32)),
              if (invalid > 0) ...[
                const SizedBox(width: 10),
                _summaryChip('$invalid', 'Errors',  Colors.red),
              ],
              if (_importing) ...[
                const SizedBox(width: 10),
                _summaryChip('$_doneCount/$valid', 'Done', const Color(0xFF1B4F72)),
              ],
              const Spacer(),
              if (!_importing && !allDone && valid > 0)
                ElevatedButton.icon(
                  onPressed: _startImport,
                  icon: const Icon(Icons.upload_rounded, size: 16),
                  label: Text('Import $valid user${valid == 1 ? '' : 's'}'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B4F72),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              if (allDone)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2E7D32).withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: Color(0xFF2E7D32), size: 16),
                      SizedBox(width: 6),
                      Text('Import complete',
                          style: TextStyle(
                              color: Color(0xFF2E7D32),
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Row list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _rows.length,
            itemBuilder: (_, i) => _buildRowCard(_rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _summaryChip(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ],
  );

  Widget _buildRowCard(_UserRow row) {
    final Color borderColor;
    final Color bgColor;
    final Widget statusWidget;

    switch (row.status) {
      case 'success':
        borderColor = const Color(0xFF2E7D32);
        bgColor     = const Color(0xFFE8F5E9);
        statusWidget = const Icon(Icons.check_circle_rounded,
            color: Color(0xFF2E7D32), size: 20);
      case 'failed':
        borderColor = Colors.red;
        bgColor     = const Color(0xFFFFEBEE);
        statusWidget = const Icon(Icons.error_rounded, color: Colors.red, size: 20);
      case 'importing':
        borderColor = const Color(0xFF1B4F72);
        bgColor     = const Color(0xFFE3F2FD);
        statusWidget = const SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2));
      default:
        if (!row.isValid) {
          borderColor = Colors.orange;
          bgColor     = const Color(0xFFFFF3E0);
          statusWidget = const Icon(Icons.warning_amber_rounded,
              color: Colors.orange, size: 20);
        } else {
          borderColor = Colors.grey.shade200;
          bgColor     = Colors.white;
          statusWidget = const Icon(Icons.pending_outlined,
              color: Colors.grey, size: 20);
        }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Role badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _roleColor(row.role).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(row.role,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: _roleColor(row.role))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(row.email,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text('Row ${row.rowNum}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(width: 8),
              statusWidget,
            ],
          ),
          if (row.name.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              row.role == 'stockist'
                  ? '${row.name}  ·  ID: ${row.sequentialId}  ·  ${row.city}'
                  : '${row.name}  ·  ${row.contactPerson}  ·  ${row.city}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (!row.isValid) ...[
            const SizedBox(height: 4),
            Text('Validation error: ${row.validationError}',
                style: const TextStyle(
                    fontSize: 11, color: Colors.orange,
                    fontWeight: FontWeight.w600)),
          ],
          if (row.status == 'failed' && row.resultMessage != null) ...[
            const SizedBox(height: 4),
            Text(row.resultMessage!,
                style: const TextStyle(
                    fontSize: 11, color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'admin':    return const Color(0xFF6A1B9A);
      case 'stockist': return const Color(0xFF1B4F72);
      default:         return const Color(0xFF2E7D32);
    }
  }
}
