import 'package:flutter/material.dart';
import '../../models/stockist.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/phone_field.dart';
import '../../utils/stockist_tiers.dart';
import 'excel_import_screen.dart';

// Admin screen to view existing stockists and add a single new one. The
// sequential ID (A01, A02, … B01) is generated automatically by the backend —
// there is no ID field on the form.
class ManageStockistsScreen extends StatefulWidget {
  const ManageStockistsScreen({super.key});
  @override
  State<ManageStockistsScreen> createState() => _ManageStockistsScreenState();
}

class _ManageStockistsScreenState extends State<ManageStockistsScreen> {
  final _dataSvc = SupabaseDataService();

  List<Stockist> _stockists = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Search + listing order (tier → priority → name), so this screen also shows
  // the buyer-facing order (Listing Order is merged in here).
  List<Stockist> get _filtered {
    var list = _stockists;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.id.toLowerCase().contains(q) ||
              s.city.toLowerCase().contains(q) ||
              s.phone.contains(q))
          .toList();
    }
    list = [...list]..sort((a, b) {
        final t = stockistTierRank(b.stockistType)
            .compareTo(stockistTierRank(a.stockistType));
        if (t != 0) return t;
        final p = b.priority.compareTo(a.priority);
        if (p != 0) return p;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  Future<void> _openEditForm(Stockist s) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddStockistSheet(existing: s),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(Stockist s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete stockist?'),
        content: Text(
            'Permanently delete ${s.name} (${s.id})?\n\nThis removes their login '
            'and ALL their designs & stock. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _dataSvc.deleteStockist(s.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${s.name} deleted.'), backgroundColor: Colors.red));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$e'.replaceAll('PostgrestException:', '').trim()),
          backgroundColor: Colors.red));
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _dataSvc.getAllStockists(activeOnly: false);
    if (!mounted) return;
    setState(() {
      _stockists = list;
      _loading = false;
    });
  }

  Future<void> _toggleActive(Stockist s, bool active) async {
    final ok = await _dataSvc.setStockistActive(s.id, active);
    if (!mounted) return;
    if (ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update status.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Stockists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import from Excel',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ExcelImportScreen(role: 'stockist')));
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddForm,
        backgroundColor: const Color(0xFF1B4F72),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Stockist'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search name, ID, city, phone…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              }),
                    ),
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? Center(
                          child: Text(
                              _stockists.isEmpty
                                  ? 'No stockists yet. Tap "Add Stockist".'
                                  : 'No matches.',
                              style: const TextStyle(color: Colors.grey)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding:
                                const EdgeInsets.fromLTRB(12, 8, 12, 90),
                            itemCount: _filtered.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, i) => _stockistTile(_filtered[i]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _stockistTile(Stockist s) => InkWell(
        onTap: () => _openEditForm(s),
        borderRadius: BorderRadius.circular(8),
        child: Opacity(
        opacity: s.isActive ? 1 : 0.55,
        child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: const Color(0xFF1B4F72).withValues(alpha: 0.1),
              child: Text(s.id,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B4F72))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(s.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14),
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (s.stockistType.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB8860B).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(s.stockistType,
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF8A6D00))),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (s.city.isNotEmpty) s.city,
                      if (s.phone.isNotEmpty) s.phone,
                    ].join('  ·  '),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Priority ${s.priority.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                Switch(
                  value: s.isActive,
                  onChanged: (v) => _toggleActive(s, v),
                  activeThumbColor: const Color(0xFF2E7D32),
                ),
                // Delete is only offered once the stockist is deactivated.
                if (!s.isActive)
                  InkWell(
                    onTap: () => _confirmDelete(s),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delete_outline,
                              size: 16, color: Colors.red),
                          SizedBox(width: 2),
                          Text('Delete',
                              style:
                                  TextStyle(fontSize: 11, color: Colors.red)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      ),
    );

  Future<void> _openAddForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AddStockistSheet(),
    );
    if (created == true) _load();
  }
}

// ── Add / edit-stockist bottom sheet ─────────────────────────────────────────
class _AddStockistSheet extends StatefulWidget {
  /// When non-null the sheet edits this stockist instead of creating one.
  final Stockist? existing;
  const _AddStockistSheet({this.existing});
  @override
  State<_AddStockistSheet> createState() => _AddStockistSheetState();
}

class _AddStockistSheetState extends State<_AddStockistSheet> {
  final _dataSvc = SupabaseDataService();
  final _formKey = GlobalKey<FormState>();

  final _name     = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  final _phone    = TextEditingController();
  final _code     = TextEditingController(text: '+91');
  final _city     = TextEditingController();
  final _state    = TextEditingController();
  final _address  = TextEditingController();
  final _priority = TextEditingController(text: '0.00');
  final _gst      = TextEditingController();
  String _tier = ''; // '' = no tier; else Platinum/Gold/Silver

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s != null) {
      _name.text     = s.name;
      _phone.text    = s.phone;
      _code.text     = s.countryCode.isEmpty ? '+91' : s.countryCode;
      _city.text     = s.city;
      _state.text    = s.state;
      _address.text  = s.address;
      _gst.text      = s.gstNumber;
      _priority.text = s.priority.toStringAsFixed(2);
      _tier = kStockistTiers.contains(s.stockistType) ? s.stockistType : '';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name, _email, _password, _phone, _code, _city, _state, _address,
      _priority, _gst
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final String msg;
      if (_isEdit) {
        await _dataSvc.updateStockist(
          sequentialId: widget.existing!.id,
          name:     _name.text.trim(),
          phone:    _phone.text.trim(),
          countryCode: _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:     _city.text.trim(),
          state:    _state.text.trim(),
          address:  _address.text.trim(),
          priority: double.tryParse(_priority.text.trim()) ?? 0,
          gstNumber: _gst.text.trim(),
          stockistType: _tier,
        );
        msg = 'Stockist updated.';
      } else {
        final seqId = await _dataSvc.addStockist(
          name:     _name.text.trim(),
          email:    _email.text.trim(),
          password: _password.text,
          phone:    _phone.text.trim(),
          countryCode: _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:     _city.text.trim(),
          state:    _state.text.trim(),
          address:  _address.text.trim(),
          priority: double.tryParse(_priority.text.trim()) ?? 0,
          gstNumber: _gst.text.trim(),
          stockistType: _tier,
        );
        msg = 'Stockist created${seqId.isNotEmpty ? ' · ID $seqId' : ''}.';
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF2E7D32),
      ));
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString().replaceAll('PostgrestException:', '').trim();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text(_isEdit ? 'Edit Stockist' : 'Add Stockist',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 2),
              Text(
                  _isEdit
                      ? 'ID ${widget.existing!.id} · login email/password unchanged here.'
                      : 'The stockist ID is generated automatically (e.g. A01).',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 14),

              _field(_name, 'Name *', required: true),
              if (!_isEdit) ...[
                _field(_email, 'Email *',
                    keyboard: TextInputType.emailAddress,
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Email is required';
                      if (!t.contains('@')) return 'Invalid email';
                      return null;
                    }),
                _field(_password, 'Password *',
                    validator: (v) =>
                        (v ?? '').length < 6 ? 'Min 6 characters' : null),
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PhoneField(
                    codeController: _code,
                    phoneController: _phone,
                    label: 'Phone'),
              ),
              _field(_city, 'City'),
              _field(_state, 'State'),
              _field(_address, 'Address'),
              _field(_gst, 'GST number (optional)'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _tier,
                  decoration: const InputDecoration(
                      labelText: 'Tier (controls listing order)',
                      border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('None')),
                    ...kStockistTiers.map(
                        (t) => DropdownMenuItem(value: t, child: Text(t))),
                  ],
                  onChanged: (v) => setState(() => _tier = v ?? ''),
                ),
              ),
              _field(_priority, 'Priority (0.00)',
                  keyboard: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null; // defaults to 0
                    return double.tryParse(t) == null ? 'Enter a number' : null;
                  }),

              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B4F72),
                      foregroundColor: Colors.white),
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Text(_isEdit ? 'Save Changes' : 'Create Stockist',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool required = false,
    TextInputType? keyboard,
    String? hint,
    String? Function(String?)? validator,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          controller: c,
          keyboardType: keyboard,
          obscureText: label.startsWith('Password'),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          validator: validator ??
              (required
                  ? (v) => (v ?? '').trim().isEmpty ? '$label required' : null
                  : null),
        ),
      );
}
