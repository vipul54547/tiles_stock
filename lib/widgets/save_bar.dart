import 'package:flutter/material.dart';

/// A pinned bottom action bar holding a primary save/commit button, so the
/// action is ALWAYS visible and never lost below a scrolling form.
///
/// The button is emphasised (brand colour) when there are unsaved changes
/// ([dirty]) and muted otherwise, and shows a spinner while [saving]. Place it
/// in `Scaffold.bottomNavigationBar`.
///
/// A Scaffold does NOT lift its bottomNavigationBar above the keyboard —
/// `resizeToAvoidBottomInset` only shrinks the body — so the bar would sit
/// behind an open number-pad, hiding Save exactly when the last quantity has
/// just been typed. Padding the bar by the keyboard's height lifts the button
/// to rest on top of it instead.
class SaveBar extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool saving;
  final bool dirty;
  final IconData icon;
  /// Active (dirty) button colour. Defaults to the brand blue; pass e.g. red
  /// for destructive commits like dispatch.
  final Color? color;

  const SaveBar({
    super.key,
    required this.label,
    required this.onPressed,
    this.saving = false,
    this.dirty = true,
    this.icon = Icons.check_rounded,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // With the keyboard up, the gesture bar is behind it — pad for one or the
    // other, never both.
    final safeArea =
        keyboard > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + safeArea + keyboard),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2)),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: saving ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: dirty
                ? (color ?? const Color(0xFF1B4F72))
                : Colors.grey.shade400,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Text(label, style: const TextStyle(fontSize: 16)),
                  ],
                ),
        ),
      ),
    );
  }
}
