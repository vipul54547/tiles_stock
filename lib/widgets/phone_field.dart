import 'package:flutter/material.dart';

/// Phone input with a small editable country-code box (default +91) on the
/// left and the number on the right. The parent owns both controllers; seed
/// [codeController] with '+91' (or the existing value for old data).
class PhoneField extends StatelessWidget {
  final TextEditingController codeController;
  final TextEditingController phoneController;
  final String label;
  final bool required;
  final IconData? icon;

  const PhoneField({
    super.key,
    required this.codeController,
    required this.phoneController,
    this.label = 'WhatsApp Number',
    this.required = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: TextFormField(
            controller: codeController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Code',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextFormField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            validator: required
                ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
                : null,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: icon != null ? Icon(icon) : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}
