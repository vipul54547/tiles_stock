import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A slim, single-line "Gemini-style" glowing bar that cycles the video TITLES
/// one at a time (no list). Each title slides in right→left, holds, slides out,
/// and the next takes its place every ~6 seconds. Tapping the bar plays the
/// video whose title is currently showing.
///
/// The border is an animated 4-colour gradient ring whose hue sweeps around the
/// rounded rectangle with a soft outer glow. Background is a low-saturation tint
/// so the title text stays crisp.
///
/// Used on the buyer home (admin learning videos) and the supplier portfolio
/// (that supplier's videos + admin). Empty list = renders nothing.
class LearningVideoStrip extends StatefulWidget {
  const LearningVideoStrip({
    super.key,
    required this.videos,
    required this.onPlay,
    // Kept for call-site compatibility; the ticker shows per-video titles now,
    // so this is only a fallback if a video has no title.
    this.title = 'Watch',
  });

  final List<Map<String, dynamic>> videos;
  final void Function(Map<String, dynamic> video) onPlay;
  final String title;

  @override
  State<LearningVideoStrip> createState() => _LearningVideoStripState();
}

class _LearningVideoStripState extends State<LearningVideoStrip>
    with TickerProviderStateMixin {
  // Drives the hue sweep + glow of the animated border (continuous loop).
  late final AnimationController _glow;

  // Drives one 6s title cycle: slide-in (1.5s) → hold (3.5s) → slide-out (1s).
  late final AnimationController _cycle;

  int _index = 0;

  static const _navy = Color(0xFF1B4F72);
  static const _bg = Color(0xFFF5F7FC);
  static const _cycleMs = 6000;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
    _cycle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _cycleMs),
    )..addStatusListener(_onCycleDone);
    if (widget.videos.isNotEmpty) _cycle.forward();
  }

  void _onCycleDone(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // Only advance / re-run when there's more than one title to rotate.
    if (widget.videos.length > 1 && mounted) {
      setState(() => _index = (_index + 1) % widget.videos.length);
      _cycle.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant LearningVideoStrip old) {
    super.didUpdateWidget(old);
    // Video set changed (loaded / switched supplier) — restart the ticker.
    if (old.videos.length != widget.videos.length) {
      _index = 0;
      if (widget.videos.isEmpty) {
        _cycle.stop();
      } else {
        _cycle.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _glow.dispose();
    _cycle.dispose();
    super.dispose();
  }

  void _playCurrent() {
    if (widget.videos.isEmpty) return;
    final i = _index.clamp(0, widget.videos.length - 1);
    widget.onPlay(widget.videos[i]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videos.isEmpty) return const SizedBox.shrink();
    final multi = widget.videos.length > 1;

    return Padding(
      // Extra outer room so the glow can bleed past the bar.
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        height: 46,
        child: AnimatedBuilder(
          animation: _glow,
          builder: (_, child) => CustomPaint(
            foregroundPainter: _GlowBorderPainter(_glow.value),
            child: child,
          ),
          child: Material(
            color: _bg,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _playCurrent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    // Prominent filled play button so the bar clearly reads as
                    // "tap to watch".
                    Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: _navy,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          size: 22, color: Colors.white),
                    ),
                    const SizedBox(width: 11),
                    Expanded(child: _ticker(multi)),
                    if (multi) ...[
                      const SizedBox(width: 8),
                      _dots(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The scrolling title. Slides in from the right, holds, then slides out left
  // (only when there are multiple titles to rotate through).
  Widget _ticker(bool multi) {
    final v = widget.videos[_index.clamp(0, widget.videos.length - 1)];
    var title = (v['title'] ?? '').toString().trim();
    if (title.isEmpty) title = widget.title;

    return ClipRect(
      child: AnimatedBuilder(
        animation: _cycle,
        builder: (_, __) {
          final t = _cycle.value;
          double dx, opacity;
          // Slide in: 0.00–0.25  (~1.5s)
          if (t < 0.25) {
            final p = Curves.easeOut.transform(t / 0.25);
            dx = 1.0 - p;
            opacity = (t / 0.2).clamp(0.0, 1.0);
          } else if (t < 0.83 || !multi) {
            // Hold: 0.25–0.83 (~3.5s) — single video stays here forever.
            dx = 0.0;
            opacity = 1.0;
          } else {
            // Slide out: 0.83–1.00 (~1s)
            final p = Curves.easeIn.transform((t - 0.83) / 0.17);
            dx = -p;
            opacity = (1.0 - (t - 0.83) / 0.15).clamp(0.0, 1.0);
          }
          return FractionalTranslation(
            translation: Offset(dx, 0),
            child: Opacity(
              opacity: opacity,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _navy,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // Tiny position dots so the buyer senses there are several videos.
  Widget _dots() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(widget.videos.length.clamp(0, 6), (i) {
        final active = i == _index % widget.videos.length;
        return Container(
          width: active ? 7 : 5,
          height: active ? 7 : 5,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: active ? _navy : _navy.withValues(alpha: 0.28),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}

/// Paints the animated 4-colour gradient border with a soft outer glow.
/// [t] is the sweep phase in [0,1) — rotating it sweeps the colours around the
/// rounded rectangle (the "Gemini" shimmer).
class _GlowBorderPainter extends CustomPainter {
  _GlowBorderPainter(this.t);

  final double t;

  static const _radius = 14.0;
  // Softer, lower-saturation 4-stop palette (muted blue → lavender → rose →
  // teal), wrapped for a seamless sweep — a tasteful shimmer, not a neon ring.
  static const _colors = [
    Color(0xFF7FA8D9), // muted blue
    Color(0xFFA98BD1), // lavender
    Color(0xFFD99BB0), // dusty rose
    Color(0xFF8CC5D6), // soft teal
    Color(0xFF7FA8D9), // wrap back to blue
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1.2),
      const Radius.circular(_radius),
    );
    final shader = SweepGradient(
      colors: _colors,
      transform: GradientRotation(t * 2 * math.pi),
    ).createShader(rect);

    // Soft, restrained glow underneath the crisp ring.
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..shader = shader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawRRect(rrect, glow);

    // Thin, gentle animated border.
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = shader;
    canvas.drawRRect(rrect, border);
  }

  @override
  bool shouldRepaint(covariant _GlowBorderPainter old) => old.t != t;
}
