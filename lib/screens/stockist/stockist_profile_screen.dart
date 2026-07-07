import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        TextInputFormatter,
        FilteringTextInputFormatter,
        LengthLimitingTextInputFormatter;
import 'package:image_picker/image_picker.dart';
import '../../services/supabase_data_service.dart';
import '../../services/cloudinary_service.dart';
import '../../utils/account_actions.dart';
import '../../utils/india_geo.dart';

/// Self-service stockist profile — the public identity used on the share-card,
/// the /s/ catalogue, and (later) SEO location pages. Fields save through the
/// auth-scoped `stockist_update_profile` RPC. Pincode auto-fills state/district/
/// city (India Post API); state & district are canonical dropdowns so the SEO
/// slugs stay clean. (project: stockist profile + share-card identity)
class StockistProfileScreen extends StatefulWidget {
  const StockistProfileScreen({super.key});
  @override
  State<StockistProfileScreen> createState() => _State();
}

class _State extends State<StockistProfileScreen> {
  static const Color _navy = Color(0xFF1B4F72);
  // Curated brand-colour palette (drives the auto-generated share card + accent).
  static const List<String> _swatches = [
    '#1B4F72', '#B5613F', '#2E7D55', '#5A4B8A',
    '#0F6E6E', '#7A2E3A', '#20222A',
  ];

  final _data = SupabaseDataService();
  final _picker = ImagePicker();

  final _name = TextEditingController();
  final _tagline = TextEditingController();
  final _city = TextEditingController();
  final _pincode = TextEditingController();
  final _hexCtl = TextEditingController();

  List<String> _states = [];
  List<String> _districts = [];
  String _state = '';
  String _district = '';
  String _logoUrl = '';
  String _brandColor = '#1B4F72';

  bool _loading = true;
  bool _busy = false;
  bool _pinLooking = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _name.dispose();
    _tagline.dispose();
    _city.dispose();
    _pincode.dispose();
    _hexCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final states = await IndiaGeo.states();
    final p = await _data.getMyProfile();
    _states = states;
    if (p != null) {
      _name.text = (p['name'] ?? '').toString();
      _tagline.text = (p['tagline'] ?? '').toString();
      _city.text = (p['city'] ?? '').toString();
      _pincode.text = (p['pincode'] ?? '').toString();
      _logoUrl = (p['logo_url'] ?? '').toString();
      final bc = (p['brand_color'] ?? '').toString();
      if (bc.isNotEmpty) _brandColor = bc;
      _state = await IndiaGeo.canonicalState((p['state'] ?? '').toString());
      _district = (p['district'] ?? '').toString();
    }
    if (_state.isNotEmpty) _districts = await IndiaGeo.districts(_state);
    _hexCtl.text = _brandColor.replaceAll('#', '').toUpperCase();
    if (mounted) setState(() => _loading = false);
  }

  // Dropdown items must always contain the current value — insert an off-list
  // legacy value so Flutter doesn't assert.
  List<String> _withValue(List<String> list, String value) {
    if (value.isEmpty || list.contains(value)) return list;
    return [value, ...list];
  }

  Future<void> _onStateChanged(String? s) async {
    if (s == null) return;
    final d = await IndiaGeo.districts(s);
    setState(() {
      _state = s;
      _districts = d;
      if (!d.contains(_district)) _district = '';
    });
  }

  Future<void> _lookupPincode() async {
    final pin = _pincode.text.trim();
    if (pin.length != 6) {
      _snack('Enter a 6-digit pincode first.', error: true);
      return;
    }
    setState(() => _pinLooking = true);
    final r = await IndiaGeo.lookupPincode(pin);
    if (!mounted) return;
    setState(() => _pinLooking = false);
    if (r == null) {
      _snack('Couldn\'t find that pincode — pick state & district manually.',
          error: true);
      return;
    }
    final districts = await IndiaGeo.districts(r.state);
    if (!mounted) return;
    setState(() {
      _state = r.state;
      _districts = districts;
      _district = r.district;
      if (_city.text.trim().isEmpty) _city.text = r.city;
    });
    _snack('Filled ${r.district}, ${r.state}.');
  }

  Future<void> _pickLogo() async {
    final x = await _picker.pickImage(
        source: ImageSource.gallery, maxWidth: 600, imageQuality: 90);
    if (x == null) return;
    setState(() => _busy = true);
    final url = await CloudinaryService.uploadImage(x.path);
    if (mounted) setState(() => _busy = false);
    if (url == null) {
      _snack('Logo upload failed. Try again.', error: true);
      return;
    }
    setState(() => _logoUrl = url);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('Business name can\'t be empty.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _data.updateMyProfile(
        name: _name.text.trim(),
        logoUrl: _logoUrl,
        brandColor: _brandColor,
        tagline: _tagline.text.trim(),
        pincode: _pincode.text.trim(),
        state: _state,
        district: _district,
        city: _city.text.trim(),
      );
      if (!mounted) return;
      _snack('Profile saved.');
      Navigator.pop(context, true);
    } catch (e) {
      _snack('Save failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Hex → Color, tolerant of '#', 3-digit shorthand, and junk (falls back to navy
  // so a bad stored value never crashes the picker).
  Color _hex(String h) {
    var v = h.replaceAll('#', '').trim();
    if (v.length == 3) v = v.split('').map((c) => '$c$c').join();
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v)) return const Color(0xFF1B4F72);
    return Color(int.parse('FF$v', radix: 16));
  }

  String _toHex(Color c) {
    int f(double x) => (x * 255).round().clamp(0, 255);
    return [f(c.r), f(c.g), f(c.b)]
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }

  // Commit a colour chosen from the spectrum/box/preset and sync the hex field.
  void _setColor(Color c) {
    final hex = _toHex(c);
    setState(() => _brandColor = '#$hex');
    _hexCtl.value = TextEditingValue(
        text: hex, selection: TextSelection.collapsed(offset: hex.length));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : 'Save',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _logoField(),
                const SizedBox(height: 20),
                _label('Business name'),
                _text(_name, hint: 'e.g. Famous Ceramic'),
                const SizedBox(height: 18),
                _addressBlock(),
                const SizedBox(height: 18),
                _brandColorField(),
                const SizedBox(height: 18),
                _label('Tagline', optional: true),
                _text(_tagline, hint: 'e.g. Quality vitrified tiles since 1998'),
                const SizedBox(height: 26),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(
                      backgroundColor: _navy,
                      minimumSize: const Size.fromHeight(48)),
                  child: Text(_busy ? 'Saving…' : 'Save profile'),
                ),
                const SizedBox(height: 32),
                _dangerZone(),
              ],
            ),
    );
  }

  // Danger zone — account deletion lives in the profile (not the toolbar).
  Widget _dangerZone() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Danger zone',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700)),
          const SizedBox(height: 4),
          Text(
            'Permanently delete your account and all your data (profile, stock, '
            'lists, videos). This cannot be undone.',
            style: TextStyle(fontSize: 12, color: Colors.red.shade700),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => confirmDeleteAccount(context),
              icon: const Icon(Icons.delete_forever, size: 18),
              label: const Text('Delete account'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade400),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logoField() {
    return Row(
      children: [
        GestureDetector(
          onTap: _busy ? null : _pickLogo,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: _logoUrl.isEmpty ? _navy : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black12),
            ),
            clipBehavior: Clip.antiAlias,
            child: _logoUrl.isEmpty
                ? const Icon(Icons.add_a_photo_outlined, color: Colors.white)
                : Image.network(CloudinaryService.logoUrl(_logoUrl),
                    fit: BoxFit.contain),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your logo',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const Text('Shows on your catalogue & share cards.',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _pickLogo,
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: Text(_logoUrl.isEmpty ? 'Upload logo' : 'Change'),
                  ),
                  if (_logoUrl.isNotEmpty)
                    TextButton(
                      onPressed:
                          _busy ? null : () => setState(() => _logoUrl = ''),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: const Text('Remove',
                          style: TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _addressBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Pincode', trailing: 'fills state, district & city'),
        Row(
          children: [
            Expanded(
              child: _text(
                _pincode,
                hint: '6 digits',
                keyboard: TextInputType.number,
                formatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: (_busy || _pinLooking) ? null : _lookupPincode,
              child: _pinLooking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Auto-fill'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('State'),
                  _dropdown(
                    value: _state,
                    items: _withValue(_states, _state),
                    hint: 'Select state',
                    onChanged: _busy ? null : _onStateChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('District'),
                  _dropdown(
                    value: _district,
                    items: _withValue(_districts, _district),
                    hint: 'Select district',
                    onChanged: (_busy || _state.isEmpty)
                        ? null
                        : (v) => setState(() => _district = v ?? ''),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _label('City / area', trailing: 'editable'),
        _text(_city, hint: 'e.g. Morbi'),
      ],
    );
  }

  Widget _brandColorField() {
    final current = _hex(_brandColor);
    final hsv = HSVColor.fromColor(current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Brand colour', trailing: 'share card & accents'),
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: current,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Colors.black12),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 128,
              child: TextField(
                controller: _hexCtl,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                onChanged: (v) {
                  if (v.length == 6) {
                    setState(() => _brandColor = '#${v.toUpperCase()}');
                  }
                },
                decoration: InputDecoration(
                  prefixText: '#',
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.black12)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.black12)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _svBox(hsv),
        const SizedBox(height: 10),
        _hueBar(hsv),
        const SizedBox(height: 12),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: _swatches.map((h) {
            final on = _brandColor.toUpperCase() == h.toUpperCase();
            return GestureDetector(
              onTap: _busy ? null : () => _setColor(_hex(h)),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: _hex(h),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: on ? Colors.black : Colors.transparent, width: 2.5),
                ),
                child: on
                    ? const Icon(Icons.check, color: Colors.white, size: 16)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // Saturation (x) × brightness (y) box for the current hue.
  Widget _svBox(HSVColor hsv) {
    const h = 150.0;
    final hueColor = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      void handle(Offset p) {
        if (_busy) return;
        final s = (p.dx / w).clamp(0.0, 1.0);
        final v = (1 - p.dy / h).clamp(0.0, 1.0);
        _setColor(HSVColor.fromAHSV(1, hsv.hue, s, v).toColor());
      }

      return GestureDetector(
        onPanDown: (d) => handle(d.localPosition),
        onPanUpdate: (d) => handle(d.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: double.infinity,
            height: h,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: hueColor)),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [Colors.white, Colors.transparent],
                      ),
                    ),
                  ),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: (hsv.saturation * w - 7).clamp(0.0, w - 14),
                  top: ((1 - hsv.value) * h - 7).clamp(0.0, h - 14),
                  child: _thumb(circle: true),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  // Hue spectrum bar.
  Widget _hueBar(HSVColor hsv) {
    const h = 22.0;
    const hueColors = [
      Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00),
      Color(0xFF00FFFF), Color(0xFF0000FF), Color(0xFFFF00FF),
      Color(0xFFFF0000),
    ];
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      void handle(Offset p) {
        if (_busy) return;
        final hue = (p.dx / w * 360).clamp(0.0, 359.9);
        final s = hsv.saturation == 0 ? 1.0 : hsv.saturation;
        final v = hsv.value == 0 ? 1.0 : hsv.value;
        _setColor(HSVColor.fromAHSV(1, hue, s, v).toColor());
      }

      return GestureDetector(
        onPanDown: (d) => handle(d.localPosition),
        onPanUpdate: (d) => handle(d.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: double.infinity,
            height: h,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: hueColors),
                    ),
                  ),
                ),
                Positioned(
                  left: (hsv.hue / 360 * w - 6).clamp(0.0, w - 12),
                  top: 1,
                  child: _thumb(width: 12, height: h - 2),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _thumb({bool circle = false, double width = 14, double height = 14}) =>
      Container(
        width: circle ? 14 : width,
        height: circle ? 14 : height,
        decoration: BoxDecoration(
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(3),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 2)],
        ),
      );

  // ── small field helpers ────────────────────────────────────────────────────
  Widget _label(String t, {bool optional = false, String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Text(t,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
            if (optional)
              const Text('  — optional',
                  style: TextStyle(fontSize: 11.5, color: Colors.black45)),
            if (trailing != null)
              Text('  — $trailing',
                  style: const TextStyle(fontSize: 11.5, color: Colors.black45)),
          ],
        ),
      );

  Widget _text(TextEditingController c,
          {String hint = '',
          TextInputType? keyboard,
          List<TextInputFormatter>? formatters}) =>
      TextField(
        controller: c,
        keyboardType: keyboard,
        inputFormatters: formatters,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.black12)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.black12)),
        ),
      );

  Widget _dropdown({
    required String value,
    required List<String> items,
    required String hint,
    required ValueChanged<String?>? onChanged,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: onChanged == null ? const Color(0xFFF0F0F0) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.black12),
        ),
        child: DropdownButton<String>(
          value: value.isEmpty ? null : value,
          hint: Text(hint,
              style: const TextStyle(fontSize: 13.5, color: Colors.black45)),
          isExpanded: true,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: items
              .map((d) => DropdownMenuItem(
                  value: d,
                  child: Text(d,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5))))
              .toList(),
          onChanged: onChanged,
        ),
      );

  void _snack(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), backgroundColor: error ? Colors.red : null));
  }
}
