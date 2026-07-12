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
  static Future<Map<String, dynamic>?> _newCustomerForm(
      BuildContext context, SupabaseDataService svc) async {
    final nameCtl = TextEditingController();
    final phoneCtl = TextEditingController();
    final pinCtl = TextEditingController();
    final cityCtl = TextEditingController();
    String state = '';
    String district = '';
    bool looking = false;
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
          setSheet(() {
            looking = false;
            if (r != null) {
              state = r.state;
              district = r.district;
              if (cityCtl.text.trim().isEmpty) cityCtl.text = r.city;
            }
          });
        }

        InputDecoration dec(String l) => InputDecoration(
            labelText: l,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)));
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('New customer',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(controller: nameCtl, decoration: dec('Name *')),
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
              if (state.isNotEmpty || district.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('$district, $state',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade700)),
                ),
              const SizedBox(height: 10),
              TextField(controller: cityCtl, decoration: dec('City')),
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
                    onPressed: () async {
                      if (nameCtl.text.trim().isEmpty) return;
                      try {
                        final id = await svc.upsertCustomer(
                          name: nameCtl.text.trim(),
                          phone: phoneCtl.text.trim().isEmpty
                              ? null
                              : phoneCtl.text.trim(),
                          state: state.isEmpty ? null : state,
                          district: district.isEmpty ? null : district,
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
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('$e'), backgroundColor: _red));
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _green, foregroundColor: Colors.white),
                    child: const Text('Save'),
                  ),
                ),
              ]),
            ],
          ),
        );
      }),
    );
    return created;
  }
}
