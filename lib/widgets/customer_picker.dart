import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/supabase_data_service.dart';
import '../utils/india_geo.dart';

/// The stockist's saved-customer picker (opt-in `customers_enabled`). Shared by
/// Dispatch and Add Order so the two cannot drift — same searchable sheet, same
/// "New customer" form that upserts and returns the created row like any other
/// pick. (project_customer_history · project_unified_dispatch_customers)
class CustomerPicker {
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);

  /// Show the picker. Returns the chosen customer map
  /// (`{id, name, city, district, phone, …}`), or null if dismissed.
  /// [customers] is the caller's current `listCustomers()` result; a freshly
  /// created customer is returned even though it is not yet in that list.
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required List<Map<String, dynamic>> customers,
    required SupabaseDataService svc,
  }) async {
    final action = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setSheet) {
          final ql = q.trim().toLowerCase();
          final res = customers
              .where((c) => (c['name'] ?? '').toString().toLowerCase().contains(ql))
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Text('Customer',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: TextField(
                    onChanged: (v) => setSheet(() => q = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search saved customers…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                ListTile(
                  leading: const CircleAvatar(
                      backgroundColor: _green,
                      child: Icon(Icons.person_add_alt, color: Colors.white)),
                  title: const Text('New customer'),
                  subtitle: const Text('Save name + location for next time'),
                  onTap: () => Navigator.pop(ctx, {'_new': true}),
                ),
                const Divider(height: 1),
                Expanded(
                  child: res.isEmpty
                      ? const Center(child: Text('No saved customers yet.'))
                      : ListView(
                          children: [
                            for (final c in res)
                              ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text((c['name'] ?? '').toString()),
                                subtitle: Text([
                                  (c['city'] ?? '').toString(),
                                  (c['district'] ?? '').toString(),
                                ].where((x) => x.isNotEmpty).join(', ')),
                                trailing: (c['phone'] ?? '').toString().isNotEmpty
                                    ? const Icon(Icons.call, size: 16)
                                    : null,
                                onTap: () => Navigator.pop(ctx, c),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          );
        });
      },
    );
    if (action == null) return null;
    if (action['_new'] == true) {
      if (!context.mounted) return null;
      return _newCustomerForm(context, svc);
    }
    return action;
  }

  /// The save-and-reuse form. Upserts the customer and returns the created row
  /// (`{id, name, phone, state, district, pincode, city}`), or null if cancelled.
  ///
  /// Name, **State and District are compulsory** — a saved customer without a
  /// place is useless in the directory, and the pincode lookup can't be relied
  /// on to supply it (it needs the network and a valid pin). So both are real
  /// dropdowns off the bundled offline list; the lookup only pre-fills them.
  static Future<Map<String, dynamic>?> _newCustomerForm(
      BuildContext context, SupabaseDataService svc) async {
    final nameCtl = TextEditingController();
    final phoneCtl = TextEditingController();
    final pinCtl = TextEditingController();
    final cityCtl = TextEditingController();
    final states = await IndiaGeo.states();
    if (!context.mounted) return null;
    List<String> districts = const [];
    String state = '';
    String district = '';
    bool looking = false;
    bool saving = false;
    Map<String, dynamic>? created;

    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> lookup() async {
          final pin = pinCtl.text.trim();
          if (pin.length != 6) return;
          setSheet(() => looking = true);
          final r = await IndiaGeo.lookupPincode(pin);
          final d = r == null ? const <String>[] : await IndiaGeo.districts(r.state);
          setSheet(() {
            looking = false;
            if (r != null) {
              state = r.state;
              districts = d;
              district = r.district;
              if (cityCtl.text.trim().isEmpty) cityCtl.text = r.city;
            }
          });
          if (r == null && ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                content: Text(
                    'Couldn\'t find that pincode — pick state & district below.')));
          }
        }

        Future<void> onState(String? s) async {
          if (s == null) return;
          final d = await IndiaGeo.districts(s);
          setSheet(() {
            state = s;
            districts = d;
            if (!d.contains(district)) district = '';
          });
        }

        InputDecoration dec(String l) => InputDecoration(
            labelText: l,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)));
        // A pincode lookup can return a district that isn't in the bundled list;
        // the dropdown must contain its own value or Flutter asserts.
        List<String> withValue(List<String> list, String v) =>
            (v.isEmpty || list.contains(v)) ? list : [v, ...list];
        final valid = nameCtl.text.trim().isNotEmpty &&
            state.isNotEmpty &&
            district.isNotEmpty;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              const Text('New customer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(
                  controller: nameCtl,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setSheet(() {}),
                  decoration: dec('Name *')),
              const SizedBox(height: 10),
              TextField(
                  controller: phoneCtl,
                  keyboardType: TextInputType.phone,
                  decoration: dec('Phone (optional)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                      controller: pinCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: dec('Pincode')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: looking ? null : lookup,
                  child: looking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Find'),
                ),
              ]),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: state.isEmpty ? null : state,
                isExpanded: true,
                decoration: dec('State *'),
                items: [
                  for (final s in withValue(states, state))
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: onState,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: district.isEmpty ? null : district,
                isExpanded: true,
                decoration: dec('District *'),
                items: [
                  for (final d in withValue(districts, district))
                    DropdownMenuItem(value: d, child: Text(d)),
                ],
                onChanged: state.isEmpty
                    ? null
                    : (d) => setSheet(() => district = d ?? ''),
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: cityCtl,
                  textCapitalization: TextCapitalization.words,
                  decoration: dec('City (optional)')),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (!valid || saving)
                        ? null
                        : () async {
                      setSheet(() => saving = true);
                      try {
                        final id = await svc.upsertCustomer(
                          name: nameCtl.text.trim(),
                          phone: phoneCtl.text.trim().isEmpty
                              ? null
                              : phoneCtl.text.trim(),
                          state: state,
                          district: district,
                          pincode: pinCtl.text.trim().isEmpty
                              ? null
                              : pinCtl.text.trim(),
                          city: cityCtl.text.trim().isEmpty
                              ? null
                              : cityCtl.text.trim(),
                        );
                        if (!ctx.mounted) return;
                        if (id != null) {
                          created = {
                            'id': id,
                            'name': nameCtl.text.trim(),
                            'phone': phoneCtl.text.trim(),
                            'state': state,
                            'district': district,
                            'pincode': pinCtl.text.trim(),
                            'city': cityCtl.text.trim(),
                          };
                        }
                        Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          setSheet(() => saving = false);
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('$e'), backgroundColor: _red));
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _green, foregroundColor: Colors.white),
                    child: Text(saving ? 'Saving…' : 'Save'),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Name, State and District are required.',
                  style:
                      TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
        );
      }),
    );
    return created;
  }
}
