import 'package:flutter/material.dart';
import '../../models/choice_state.dart';
import '../../services/supabase_auth_service.dart';
import '../../services/supabase_data_service.dart';

/// Super-admin-only "go live" switch. The single [publicMarketLive] flag
/// (app_settings.public_market_enabled) gates BOTH the public market AND
/// stockist anonymity across the whole app. Off = the private-first runway:
/// stockists never see "public" or anonymity anywhere. On = launch day.
class GoLiveScreen extends StatefulWidget {
  const GoLiveScreen({super.key});
  @override
  State<GoLiveScreen> createState() => _GoLiveScreenState();
}

class _GoLiveScreenState extends State<GoLiveScreen> {
  final _svc = SupabaseDataService();
  bool _loading = true;
  bool _saving = false;
  bool _enabled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _svc.getPublicMarketEnabled();
      if (!mounted) return;
      setState(() {
        _enabled = v;
        publicMarketLive = v;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the switch: $e';
        _loading = false;
      });
    }
  }

  Future<void> _set(bool value) async {
    // Going LIVE is a one-way, app-wide reveal — confirm first.
    if (value) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Go live with the public market?'),
          content: const Text(
              'This reveals the public market and stockist anonymity controls '
              'across the whole app for every admin and buyer. Only do this on '
              'launch day. You can turn it back off here.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Go live')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final v = await _svc.setPublicMarketEnabled(value);
      if (!mounted) return;
      setState(() {
        _enabled = v;
        publicMarketLive = v;
        _saving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(v
                ? 'Public market is now LIVE.'
                : 'Public market is OFF (private-first).')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to change the switch: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hard backstop: only the super admin should ever reach this screen.
    if (!isSuperAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Public Market')),
        body: const Center(child: Text('Super admin only.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Public Market (Go Live)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
              children: [
                Card(
                  child: SwitchListTile(
                    value: _enabled,
                    activeThumbColor: const Color(0xFF1B4F72),
                    title: Text(
                      _enabled ? 'Public market is LIVE' : 'Public market is OFF',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(_enabled
                        ? 'Public listings + stockist anonymity controls are visible app-wide.'
                        : 'Private-first: stockists never see "public" or anonymity. '
                            'Buyers still reach stock through the share links they are sent.'),
                    onChanged: _saving ? null : _set,
                  ),
                ),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red)),
                  ),
                const SizedBox(height: 16),
                Text(
                  'This is the single launch switch. While OFF (the ~1-year '
                  'private runway) the public marketplace and per-stockist '
                  'anonymity stay dormant everywhere. Flip it ON only on launch '
                  'day. Visible to the super admin only.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }
}
