import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import '../../main.dart';

// Role-scoped Excel importer. Opened from Manage Stockists (role 'stockist') or
// End Users (role 'end_user'). The role is fixed here — the sheet does NOT need
// a 'role' column. The sequential_id / unique id is auto-generated when blank.
class ExcelImportScreen extends StatefulWidget {
  final String role; // 'stockist' | 'end_user'
  const ExcelImportScreen({super.key, required this.role});

  @override
  State<ExcelImportScreen> createState() => _ExcelImportScreenState();
}

class _ImportRow {
  final int rowNum;
  final Map<String, String> v;
  String? validationError;
  String status = 'pending'; // pending | importing | success | failed
  String? resultMessage;
  _ImportRow(this.rowNum, this.v, this.validationError);
  bool get isValid => validationError == null;
}

class _ExcelImportScreenState extends State<ExcelImportScreen> {
  List<_ImportRow> _rows = [];
  bool _parsed = false;
  bool _importing = false;
  int _doneCount = 0;
  final _pathCtrl = TextEditingController();

  bool get _isStockist => widget.role == 'stockist';
  String get _roleLabel => _isStockist ? 'Stockists' : 'End Users';

  // Columns shown in the instructions (name, description, required).
  List<(String, String, bool)> get _cols => _isStockist
      ? const [
          ('email', 'Login email', true),
          ('password', 'Min 6 characters', true),
          ('name', 'Stockist name', true),
          ('sequential_id', 'Blank = auto (A01…)', false),
          ('priority', 'Boost weight e.g. 0.00', false),
          ('stockist_type', 'Tier label e.g. Gold', false),
          ('phone', 'Phone', false),
          ('city', 'City', false),
          ('state', 'State', false),
          ('address', 'Address', false),
          ('gst_number', 'GST number', false),
        ]
      : const [
          ('email', 'Login email', true),
          ('password', 'Min 6 characters', true),
          ('company_name', 'Company name (or "name")', true),
          ('contact_person', 'Contact person', false),
          ('sequential_id', 'Blank = auto (01A…)', false),
          ('priority', 'Boost weight e.g. 0.00', false),
          ('enduser_type', 'Tier label e.g. Gold', false),
          ('phone', 'Phone', false),
          ('city', 'City', false),
          ('gst_number', 'GST number', false),
        ];

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  // ── Loading ───────────────────────────────────────────────────────────────
  Future<void> _loadFromPath() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) return _snack('Please enter a file path.');
    final file = File(path);
    if (!await file.exists()) return _snack('File not found:\n$path');
    await _parseBytes(await file.readAsBytes());
  }

  Future<void> _pickAndParse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
    if (result == null || result.files.single.bytes == null) return;
    _pathCtrl.text = result.files.single.path ?? '';
    await _parseBytes(result.files.single.bytes!);
  }

  Future<void> _parseBytes(List<int> bytes) async {
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel.tables[excel.tables.keys.first];
    if (sheet == null) return _snack('Could not read sheet from the file.');
    final rows = sheet.rows;
    if (rows.isEmpty) return _snack('The sheet is empty.');

    final header = rows.first
        .map((c) => c?.value?.toString().trim().toLowerCase() ?? '')
        .toList();
    int col(String name) => header.indexOf(name);
    String cell(List<Data?> row, String name) {
      final i = col(name);
      if (i < 0 || i >= row.length) return '';
      return row[i]?.value?.toString().trim() ?? '';
    }

    final parsed = <_ImportRow>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) =>
          c == null || c.value == null || c.value.toString().trim().isEmpty)) {
        continue;
      }
      final v = <String, String>{
        'email':          cell(row, 'email'),
        'password':       cell(row, 'password'),
        'name':           cell(row, 'name'),
        'company_name':   cell(row, 'company_name'),
        'contact_person': cell(row, 'contact_person'),
        'sequential_id':  cell(row, 'sequential_id'),
        'priority':       cell(row, 'priority'),
        'stockist_type':  cell(row, 'stockist_type'),
        'enduser_type':   cell(row, 'enduser_type'),
        'phone':          cell(row, 'phone'),
        'city':           cell(row, 'city'),
        'state':          cell(row, 'state'),
        'address':        cell(row, 'address'),
        'gst_number':     cell(row, 'gst_number'),
      };
      parsed.add(_ImportRow(r + 1, v, _validate(v)));
    }

    if (parsed.isEmpty) return _snack('No data rows found (only header?).');
    setState(() { _rows = parsed; _parsed = true; _doneCount = 0; });
  }

  String? _validate(Map<String, String> v) {
    if (v['email']!.isEmpty) return 'email is required';
    if (!v['email']!.contains('@')) return 'invalid email';
    if (v['password']!.length < 6) return 'password must be ≥ 6 chars';
    final priority = v['priority']!;
    if (priority.isNotEmpty && double.tryParse(priority) == null) {
      return 'priority must be a number (e.g. 0.00)';
    }
    if (_isStockist) {
      if (v['name']!.isEmpty) return 'name is required';
    } else {
      if (v['company_name']!.isEmpty && v['name']!.isEmpty) {
        return 'company_name is required';
      }
    }
    return null;
  }

  // ── Import ────────────────────────────────────────────────────────────────
  Future<void> _startImport() async {
    final valid = _rows.where((r) => r.isValid).toList();
    if (valid.isEmpty) return _snack('No valid rows to import.');
    setState(() { _importing = true; _doneCount = 0; });

    for (final row in valid) {
      setState(() => row.status = 'importing');
      final v = row.v;
      final params = <String, dynamic>{
        'p_email':         v['email'],
        'p_password':      v['password'],
        'p_role':          widget.role,
        'p_sequential_id': v['sequential_id']!.isEmpty ? null : v['sequential_id'],
        'p_phone':         v['phone'],
        'p_city':          v['city'],
        'p_priority':      v['priority']!.isEmpty ? 0 : (double.tryParse(v['priority']!) ?? 0),
        'p_gst_number':    v['gst_number']!.isEmpty ? null : v['gst_number'],
      };
      if (_isStockist) {
        params['p_name']          = v['name'];
        params['p_state']         = v['state'];
        params['p_address']       = v['address'];
        params['p_stockist_type'] = v['stockist_type']!.isEmpty ? null : v['stockist_type'];
      } else {
        params['p_company_name']  = v['company_name']!.isEmpty ? v['name'] : v['company_name'];
        params['p_contact_person'] = v['contact_person'];
        params['p_enduser_type']  = v['enduser_type']!.isEmpty ? null : v['enduser_type'];
      }
      try {
        await supabase.rpc('create_user_from_excel', params: params);
        setState(() { row.status = 'success'; _doneCount++; });
      } catch (e) {
        setState(() {
          row.status = 'failed';
          row.resultMessage =
              e.toString().replaceAll('PostgrestException:', '').trim();
          _doneCount++;
        });
      }
    }
    setState(() => _importing = false);
  }

  void _reset() => setState(() {
        _rows = []; _parsed = false; _importing = false; _doneCount = 0;
      });

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Import $_roleLabel from Excel'),
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

  Widget _buildInstructions() => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1B4F72), Color(0xFF2E86C1)]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.upload_file_rounded,
                      color: Colors.white, size: 36),
                  const SizedBox(height: 8),
                  Text('Import $_roleLabel',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Upload an .xlsx file. The ID is generated '
                      'automatically when left blank.',
                      style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text('Columns',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 10),
            _columnTable(),
            const SizedBox(height: 24),
            const Text('Option 1 — paste the file path',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  decoration: InputDecoration(
                    hintText: r'e.g. C:\path\to\file.xlsx',
                    hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                    prefixIcon: const Icon(Icons.insert_drive_file_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
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
                          borderRadius: BorderRadius.circular(10))),
                  child: const Text('Load',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: Divider(color: Colors.grey.shade300)),
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR', style: TextStyle(color: Colors.grey))),
              Expanded(child: Divider(color: Colors.grey.shade300)),
            ]),
            const SizedBox(height: 14),
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

  Widget _columnTable() => Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade200),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: _cols
              .map((c) => Container(
                    decoration: BoxDecoration(
                        border: Border(
                            top: BorderSide(color: Colors.grey.shade100))),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Row(
                      children: [
                        Expanded(
                            flex: 3,
                            child: Text(c.$1,
                                style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: Color(0xFF1B4F72),
                                    fontWeight: FontWeight.w600))),
                        Expanded(
                            flex: 5,
                            child: Text(c.$2,
                                style: const TextStyle(fontSize: 11))),
                        SizedBox(
                          width: 64,
                          child: c.$3
                              ? const Icon(Icons.check_circle_rounded,
                                  color: Color(0xFF2E7D32), size: 16)
                              : Text('optional',
                                  style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.grey.shade500)),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      );

  Widget _buildPreview() {
    final valid = _rows.where((r) => r.isValid).length;
    final invalid = _rows.length - valid;
    final allDone = _doneCount == valid && valid > 0 && !_importing;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: const Color(0xFF1B4F72).withValues(alpha: 0.06),
          child: Row(
            children: [
              _chip('${_rows.length}', 'Total', Colors.grey),
              const SizedBox(width: 10),
              _chip('$valid', 'Valid', const Color(0xFF2E7D32)),
              if (invalid > 0) ...[
                const SizedBox(width: 10),
                _chip('$invalid', 'Errors', Colors.red),
              ],
              if (_importing) ...[
                const SizedBox(width: 10),
                _chip('$_doneCount/$valid', 'Done', const Color(0xFF1B4F72)),
              ],
              const Spacer(),
              if (!_importing && !allDone && valid > 0)
                ElevatedButton.icon(
                  onPressed: _startImport,
                  icon: const Icon(Icons.upload_rounded, size: 16),
                  label: Text('Import $valid'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white),
                ),
              if (allDone)
                const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_rounded,
                      color: Color(0xFF2E7D32), size: 18),
                  SizedBox(width: 6),
                  Text('Done', style: TextStyle(
                      color: Color(0xFF2E7D32), fontWeight: FontWeight.bold)),
                ]),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _rows.length,
            itemBuilder: (_, i) => _rowCard(_rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _chip(String value, String label, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

  Widget _rowCard(_ImportRow row) {
    final Color border;
    final Color bg;
    final Widget status;
    switch (row.status) {
      case 'success':
        border = const Color(0xFF2E7D32); bg = const Color(0xFFE8F5E9);
        status = const Icon(Icons.check_circle_rounded,
            color: Color(0xFF2E7D32), size: 20);
      case 'failed':
        border = Colors.red; bg = const Color(0xFFFFEBEE);
        status = const Icon(Icons.error_rounded, color: Colors.red, size: 20);
      case 'importing':
        border = const Color(0xFF1B4F72); bg = const Color(0xFFE3F2FD);
        status = const SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2));
      default:
        if (!row.isValid) {
          border = Colors.orange; bg = const Color(0xFFFFF3E0);
          status = const Icon(Icons.warning_amber_rounded,
              color: Colors.orange, size: 20);
        } else {
          border = Colors.grey.shade200; bg = Colors.white;
          status = const Icon(Icons.pending_outlined,
              color: Colors.grey, size: 20);
        }
    }
    final title = _isStockist
        ? (row.v['name']!.isEmpty ? row.v['email']! : row.v['name']!)
        : ((row.v['company_name']!.isEmpty ? row.v['name']! : row.v['company_name']!)
            .isEmpty
            ? row.v['email']!
            : (row.v['company_name']!.isEmpty ? row.v['name']! : row.v['company_name']!));
    final id = row.v['sequential_id']!.isEmpty ? 'auto' : row.v['sequential_id']!;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(row.v['email']!,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                  overflow: TextOverflow.ellipsis),
            ),
            Text('Row ${row.rowNum}',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
            const SizedBox(width: 8),
            status,
          ]),
          const SizedBox(height: 4),
          Text('$title  ·  ID: $id  ·  ${row.v['city']}',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
              overflow: TextOverflow.ellipsis),
          if (!row.isValid) ...[
            const SizedBox(height: 4),
            Text('Validation error: ${row.validationError}',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.orange,
                    fontWeight: FontWeight.w600)),
          ],
          if (row.status == 'failed' && row.resultMessage != null) ...[
            const SizedBox(height: 4),
            Text(row.resultMessage!,
                style: const TextStyle(fontSize: 11, color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
