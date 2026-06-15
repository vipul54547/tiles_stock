import 'package:flutter/material.dart';
import '../../models/end_user.dart';
import '../../services/supabase_data_service.dart';
import '../../widgets/phone_field.dart';
import '../../utils/stockist_tiers.dart';
import 'excel_import_screen.dart';

// Admin screen to view end users (companies) and add a single new one. The
// unique ID (01A, 02A … 01B) is generated automatically by the backend.
class ManageEndUsersScreen extends StatefulWidget {
  const ManageEndUsersScreen({super.key});
  @override
  State<ManageEndUsersScreen> createState() => _ManageEndUsersScreenState();
}

class _ManageEndUsersScreenState extends State<ManageEndUsersScreen> {
  final _dataSvc = SupabaseDataService();

  List<EndUser> _users = [];
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

  List<EndUser> get _filtered {
    if (_query.isEmpty) return _users;
    final q = _query.toLowerCase();
    return _users
        .where((u) =>
            u.companyName.toLowerCase().contains(q) ||
            u.id.toLowerCase().contains(q) ||
            u.contactPerson.toLowerCase().contains(q) ||
            u.city.toLowerCase().contains(q) ||
            u.phone.contains(q) ||
            u.email.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _openEditForm(EndUser u) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AddEndUserSheet(existing: u),
    );
    if (saved == true) _load();
  }

  Future<void> _confirmDelete(EndUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete end user?'),
        content: Text(
            'Permanently delete ${u.companyName} (${u.id})?\n\nThis removes '
            'their login and saved choices/inquiries. This cannot be undone.'),
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
      await _dataSvc.deleteEndUser(u.uuid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${u.companyName} deleted.'),
          backgroundColor: Colors.red));
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
    final list = await _dataSvc.getAllEndUsers(activeOnly: false);
    if (!mounted) return;
    setState(() {
      _users = list;
      _loading = false;
    });
  }

  Future<void> _toggleActive(EndUser u, bool active) async {
    final ok = await _dataSvc.setEndUserActive(u.uuid, active);
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
        title: const Text('End Users'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Import from Excel',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ExcelImportScreen(role: 'end_user')));
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
        label: const Text('Add End User'),
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
                      hintText: 'Search company, ID, contact, city, phone…',
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
                              _users.isEmpty
                                  ? 'No end users yet. Tap "Add End User".'
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
                            itemBuilder: (_, i) => _userTile(_filtered[i]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _userTile(EndUser u) => InkWell(
        onTap: () => _openEditForm(u),
        borderRadius: BorderRadius.circular(8),
        child: Opacity(
        opacity: u.isActive ? 1 : 0.55,
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
                backgroundColor: const Color(0xFF6A1B9A).withValues(alpha: 0.1),
                child: Text(u.id,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6A1B9A))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(u.companyName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (u.endUserType.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6A1B9A)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(u.endUserType,
                                style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF6A1B9A))),
                          ),
                        ],
                      ],
                    ),
                    if (u.email.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(u.email,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF1B4F72)),
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (u.contactPerson.isNotEmpty) u.contactPerson,
                        if (u.city.isNotEmpty) u.city,
                        if (u.phone.isNotEmpty) u.phone,
                      ].join('  ·  '),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    // At-a-glance toggle state + active device count.
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _dot('Private links', u.canClaimPrivate),
                        _deviceChip(u.deviceCount, u.deviceLimit),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Switch(
                    value: u.isActive,
                    onChanged: (v) => _toggleActive(u, v),
                    activeThumbColor: const Color(0xFF2E7D32),
                  ),
                  if (!u.isActive)
                    InkWell(
                      onTap: () => _confirmDelete(u),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete_outline,
                                size: 16, color: Colors.red),
                            SizedBox(width: 2),
                            Text('Delete',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.red)),
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

  // A small on/off status dot + label (● green = on, ○ grey = off).
  Widget _dot(String label, bool on) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(on ? Icons.circle : Icons.circle_outlined,
              size: 9,
              color: on ? const Color(0xFF2E7D32) : Colors.grey.shade400),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: on ? const Color(0xFF2E7D32) : Colors.grey.shade500)),
        ],
      );

  // Active devices / allowed limit (0 limit = unlimited → ∞).
  Widget _deviceChip(int count, int limit) {
    final lim = limit == 0 ? '∞' : '$limit';
    final over = limit > 0 && count > limit;
    final color = over
        ? Colors.red
        : (count > 0 ? const Color(0xFF1565C0) : Colors.grey.shade500);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.devices, size: 11, color: color),
        const SizedBox(width: 4),
        Text('$count/$lim',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }

  Future<void> _openAddForm() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => const _AddEndUserSheet(),
    );
    if (created == true) _load();
  }
}

// ── Add / edit-end-user bottom sheet ─────────────────────────────────────────
class _AddEndUserSheet extends StatefulWidget {
  /// When non-null the sheet edits this end user instead of creating one.
  final EndUser? existing;
  const _AddEndUserSheet({this.existing});
  @override
  State<_AddEndUserSheet> createState() => _AddEndUserSheetState();
}

class _AddEndUserSheetState extends State<_AddEndUserSheet> {
  final _dataSvc = SupabaseDataService();
  final _formKey = GlobalKey<FormState>();

  final _company  = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  final _contact  = TextEditingController();
  final _phone    = TextEditingController();
  final _code     = TextEditingController(text: '+91');
  final _city     = TextEditingController();
  final _gst      = TextEditingController();
  final _priority = TextEditingController(text: '0.00');
  String _tier = ''; // '' = none; else Platinum/Gold/Silver (enduser_type)
  final _deviceLimit = TextEditingController(text: '1'); // concurrent devices
  int _deviceCount = 0; // devices currently registered for this user
  bool _canClaimPrivate = false; // may add (claim) catalog links

  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final u = widget.existing;
    if (u != null) {
      _company.text  = u.companyName;
      _contact.text  = u.contactPerson;
      _phone.text    = u.phone;
      _code.text     = u.countryCode.isEmpty ? '+91' : u.countryCode;
      _city.text     = u.city;
      _gst.text      = u.gstNumber;
      _priority.text = u.priority.toStringAsFixed(2);
      _tier = kStockistTiers.contains(u.endUserType) ? u.endUserType : '';
      _deviceLimit.text = '${u.deviceLimit}';
      _canClaimPrivate = u.canClaimPrivate;
      _loadDeviceCount();
    }
  }

  Future<void> _loadDeviceCount() async {
    final n = await _dataSvc.userDeviceCount('end_user', widget.existing!.uuid);
    if (mounted) setState(() => _deviceCount = n);
  }

  @override
  void dispose() {
    for (final c in [
      _company, _email, _password, _contact, _phone, _code, _city, _gst,
      _priority, _deviceLimit
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _clearDevices() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear registered devices?'),
        content: const Text(
            'This logs the user out of all their devices on next app open and '
            'frees every slot, so they can sign in fresh. Use this when they '
            'changed/reinstalled their phone and are locked out.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await _dataSvc.clearUserDevices('end_user', widget.existing!.uuid);
    if (!mounted) return;
    setState(() => _deviceCount = 0);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Cleared $n device${n == 1 ? '' : 's'}.'),
      backgroundColor: const Color(0xFF2E7D32),
    ));
  }

  Widget _deviceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        const Text('Device Limit',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            'How many devices this login can be active on at once. 0 = unlimited. '
            'Currently $_deviceCount registered.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 90,
              child: TextFormField(
                controller: _deviceLimit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Devices',
                    isDense: true,
                    border: OutlineInputBorder()),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  final n = int.tryParse(t);
                  if (n == null || n < 0) return 'Invalid';
                  return null;
                },
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _deviceCount == 0 ? null : _clearDevices,
              icon: const Icon(Icons.phonelink_erase, size: 16),
              label: Text('Clear devices ($_deviceCount)'),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final String msg;
      if (_isEdit) {
        await _dataSvc.updateEndUser(
          uuid:          widget.existing!.uuid,
          companyName:   _company.text.trim(),
          contactPerson: _contact.text.trim(),
          phone:         _phone.text.trim(),
          countryCode:   _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:          _city.text.trim(),
          gstNumber:     _gst.text.trim(),
          endUserType:   _tier,
          priority:      double.tryParse(_priority.text.trim()) ?? 0,
          canClaimPrivate: _canClaimPrivate,
        );
        await _dataSvc.setDeviceLimit('end_user', widget.existing!.uuid,
            int.tryParse(_deviceLimit.text.trim()) ?? 1);
        msg = 'End user updated.';
      } else {
        final id = await _dataSvc.addEndUser(
          companyName:   _company.text.trim(),
          email:         _email.text.trim(),
          password:      _password.text,
          contactPerson: _contact.text.trim(),
          phone:         _phone.text.trim(),
          countryCode:   _code.text.trim().isEmpty ? '+91' : _code.text.trim(),
          city:          _city.text.trim(),
          gstNumber:     _gst.text.trim(),
          endUserType:   _tier,
          priority:      double.tryParse(_priority.text.trim()) ?? 0,
        );
        msg = 'End user created${id.isNotEmpty ? ' · ID $id' : ''}.';
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
    final mq = MediaQuery.of(context);
    // Keyboard inset + the system navigation-bar inset, so the Save button
    // clears the on-screen nav buttons (and the keyboard when open).
    final bottom = mq.viewInsets.bottom + mq.viewPadding.bottom;
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
              Text(_isEdit ? 'Edit End User' : 'Add End User',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 2),
              Text(
                  _isEdit
                      ? 'ID ${widget.existing!.id} · login email/password unchanged here.'
                      : 'The ID is generated automatically (e.g. 01A).',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              const SizedBox(height: 14),

              _field(_company, 'Company name *', required: true),
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
              _field(_contact, 'Contact person'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PhoneField(
                    codeController: _code,
                    phoneController: _phone,
                    label: 'WhatsApp Number'),
              ),
              _field(_city, 'City'),
              _field(_gst, 'GST number (optional)'),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String>(
                  initialValue: _tier,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: 'Tier (for future stock-timing)',
                    isDense: true,
                    border:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
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
                    if (t.isEmpty) return null;
                    return double.tryParse(t) == null ? 'Enter a number' : null;
                  }),
              if (_isEdit)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _canClaimPrivate,
                    activeThumbColor: Colors.deepPurple,
                    title: const Text('Allow private links'),
                    subtitle: Text(
                        _canClaimPrivate
                            ? 'Can save stock catalogue links — sees the Public / Private / Both tabs and the add-link button.'
                            : 'No link feature shown. Buyer browses the public market only and never sees these options.',
                        style: const TextStyle(fontSize: 11)),
                    onChanged: (v) => setState(() => _canClaimPrivate = v),
                  ),
                ),
              if (_isEdit) _deviceSection(),

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
                      : Text(_isEdit ? 'Save Changes' : 'Create End User',
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          validator: validator ??
              (required
                  ? (v) => (v ?? '').trim().isEmpty ? '$label required' : null
                  : null),
        ),
      );
}
