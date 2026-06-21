import 'dart:async';
import 'package:flutter/material.dart';

/// Reveals [text] one character at a time (a "type-on" effect) so the reader's
/// eye is paced through the instruction instead of skimming past it — used on the
/// critical instruction text at each importer step to nudge the stockist to
/// actually read before deciding.
///
/// • Plays once when the text first appears, and again only when the [text]
///   itself changes (e.g. moving to the next step). Rebuilds with the SAME text
///   (e.g. tapping an option) do NOT replay it.
/// • Tap anywhere on the text to reveal the rest instantly.
/// • Honours the platform "reduce motion" setting (shows the full text at once).
/// • Reserves the final size up-front so surrounding widgets never jump as lines
///   appear.
class TypewriterText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// Delay between each character. Smaller = faster.
  final Duration charDuration;

  /// Wait this long before the first character appears (lets a heading lead).
  final Duration startDelay;

  const TypewriterText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.charDuration = const Duration(milliseconds: 16),
    this.startDelay = Duration.zero,
  });

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  int _shown = 0;
  Timer? _timer;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion) _revealAll();
  }

  @override
  void didUpdateWidget(TypewriterText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _start();
  }

  void _start() {
    _timer?.cancel();
    _shown = 0;
    if (_reduceMotion || widget.text.isEmpty) {
      _shown = widget.text.length;
      return;
    }
    Future.delayed(widget.startDelay, () {
      if (!mounted) return;
      _timer = Timer.periodic(widget.charDuration, (t) {
        if (!mounted || _shown >= widget.text.length) {
          t.cancel();
          return;
        }
        setState(() => _shown++);
      });
    });
  }

  void _revealAll() {
    _timer?.cancel();
    if (!mounted) {
      _shown = widget.text.length;
      return;
    }
    setState(() => _shown = widget.text.length);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown.clamp(0, widget.text.length);
    final done = shown >= widget.text.length;
    return GestureDetector(
      onTap: done ? null : _revealAll,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          // Invisible full text reserves the final size so layout never jumps.
          Opacity(
            opacity: 0,
            child: Text(widget.text,
                style: widget.style, textAlign: widget.textAlign),
          ),
          Text(widget.text.substring(0, shown),
              style: widget.style, textAlign: widget.textAlign),
        ],
      ),
    );
  }
}
