import 'package:flutter/material.dart';
import '../services/cloudinary_service.dart';
import '../utils/banner_layout.dart';

/// The ONE stock-list banner renderer.
///
/// Used by BOTH the public `/s/` catalogue page and the stockist's banner
/// editor preview, so the editor example is proportion-for-proportion identical
/// to what buyers see — true WYSIWYG. It scales purely by available width
/// (LayoutBuilder + the same `width/2.5` height rule), so the same config yields
/// the same look at any size. Never fork these numbers into a second renderer:
/// if the preview and the output ever drift, editing becomes trial-and-error.
class BannerView extends StatelessWidget {
  /// pool | library | upload | custom | none
  final String source;

  /// Background image (Cloudinary public id or URL). Empty → [bgPlaceholder]
  /// (editor) or the brand gradient (public page).
  final String bgUrl;
  final String companyLogoUrl;

  /// Raw company position; coerced through [effectiveCompanyPos] internally.
  final String companyPos;
  final String tdPos;
  final bool tdShow;
  final String heading;
  final String message;

  /// Message text styling. size = 's'|'m'|'l' ('' = medium); colour = hex
  /// without '#' ('' = white); align = 'left'|'center' ('' = auto).
  final String headingSize;
  final String headingColor;
  final String msgSize;
  final String msgColor;
  final String textAlign;
  final String textValign; // 'top' | 'middle' | 'bottom' ('' = middle)

  /// Stockist/brand name — used for the big-name overlay and the welcome strip.
  final String name;

  /// Gradient fallback colour when no background image is set.
  final Color brandColor;

  /// The public page shows a "Welcome to …" strip for pool/plain library
  /// banners; the editor turns it off to keep the preview uncluttered.
  final bool showWelcomeStrip;

  /// Editor-only stand-in shown when no real background is loaded yet
  /// (e.g. the rotating pool, or an empty library/upload slot).
  final Widget? bgPlaceholder;

  const BannerView({
    super.key,
    required this.source,
    required this.bgUrl,
    required this.companyLogoUrl,
    required this.companyPos,
    required this.tdPos,
    required this.tdShow,
    required this.heading,
    required this.message,
    required this.name,
    this.headingSize = '',
    this.headingColor = '',
    this.msgSize = '',
    this.msgColor = '',
    this.textAlign = '',
    this.textValign = '',
    this.brandColor = const Color(0xFF1B4F72),
    this.showWelcomeStrip = true,
    this.bgPlaceholder,
  });

  // Hex ('RRGGBB' or '#RRGGBB') → Color; falls back to [fallback] when unset.
  static Color _hex(String s, Color fallback) {
    var h = s.trim().replaceAll('#', '');
    if (h.isEmpty) return fallback;
    if (h.length == 6) h = 'FF$h';
    final v = h.length == 8 ? int.tryParse(h, radix: 16) : null;
    return v == null ? fallback : Color(v);
  }

  @override
  Widget build(BuildContext context) {
    // 'none' = the stockist removed the banner: the catalogue starts at the tiles.
    if (source == 'none') return const SizedBox.shrink();

    final companyLogo = companyLogoUrl;
    // Big NAME (no logo) never uses the middle row — coerce legacy values down.
    final companyPosEff =
        effectiveCompanyPos(companyPos, hasLogo: companyLogo.isNotEmpty);
    final msg = message.trim();
    final msgHeading = heading.trim();
    final hasMsg = msg.isNotEmpty;
    final topRow = companyPosEff == 'top-left' ||
        companyPosEff == 'top-center' ||
        companyPosEff == 'top-right';
    // Welcome text: pool always; library only when the company is NOT on the top
    // row (top logo hides Welcome); upload never. Suppressed in message mode.
    final showWelcome = showWelcomeStrip &&
        !hasMsg &&
        (source == 'pool' || (source == 'library' && !topRow));
    // In message mode the message replaces the company NAME; keep only the logo.
    final showCompany = source == 'library' &&
        companyPosEff != 'none' &&
        (!hasMsg || companyLogo.isNotEmpty);

    // Text style: colour (default white), and alignment — explicit choice wins,
    // else auto (left beside a logo, centred without).
    final headingCol = _hex(headingColor, Colors.white);
    final msgCol = _hex(msgColor, Colors.white);
    final align = textAlign.isNotEmpty
        ? textAlign
        : (companyLogo.isNotEmpty ? 'left' : 'center');
    final alignLeft = align == 'left';
    // Vertical placement: top / bottom, else the default slightly-above-centre.
    final vy = switch (textValign) {
      'top' => -1.0,
      'bottom' => 1.0,
      _ => -0.12,
    };

    return LayoutBuilder(
      builder: (context, c) {
        final h = (c.maxWidth / 2.5).clamp(0.0, 200.0);
        // S/M/L → font size (proportional to banner height, with sane clamps).
        double headingFs() {
          switch (headingSize) {
            case 's':
              return (h * 0.085).clamp(11.0, 16.0);
            case 'l':
              return (h * 0.14).clamp(18.0, 26.0);
            default:
              return (h * 0.11).clamp(14.0, 20.0);
          }
        }

        double msgFs() {
          switch (msgSize) {
            case 's':
              return (h * 0.058).clamp(9.0, 12.0);
            case 'l':
              return (h * 0.092).clamp(12.0, 18.0);
            default:
              return (h * 0.072).clamp(10.0, 14.0);
          }
        }
        return SizedBox(
          width: double.infinity,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background
              if (bgUrl.isNotEmpty)
                Image.network(CloudinaryService.bannerUrl(bgUrl),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        bgPlaceholder ?? _gradient())
              else
                bgPlaceholder ?? _gradient(),
              // Message banner: legibility veil + heading + message.
              if (hasMsg)
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [Colors.black54, Colors.black26, Colors.black45],
                      ),
                    ),
                  ),
                ),
              if (hasMsg)
                Align(
                  // Horizontal: right of a left logo, else per align. Vertical:
                  // per the stockist's Top/Middle/Bottom choice.
                  alignment: Alignment(
                      companyLogo.isNotEmpty ? 1.0 : (alignLeft ? -1.0 : 0.0),
                      vy),
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: companyLogo.isNotEmpty
                            ? c.maxWidth * 0.30
                            : c.maxWidth * 0.06,
                        right: c.maxWidth * 0.06,
                        // Keep top/bottom text off the very edge.
                        top: textValign == 'top' ? h * 0.10 : 0,
                        bottom: textValign == 'bottom' ? h * 0.10 : 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: alignLeft
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        if (msgHeading.isNotEmpty) ...[
                          // Shown exactly as typed — the stockist chooses the
                          // case (ALL CAPS / lowercase / Title Case).
                          Text(msgHeading,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign:
                                  alignLeft ? TextAlign.left : TextAlign.center,
                              style: TextStyle(
                                  color: headingCol,
                                  fontSize: headingFs(),
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                  letterSpacing: 1.0,
                                  shadows: const [
                                    Shadow(blurRadius: 4, color: Colors.black87)
                                  ])),
                          Container(
                              margin: const EdgeInsets.only(top: 3, bottom: 5),
                              height: 2,
                              width: (h * 0.55).clamp(24.0, 64.0),
                              color: const Color(0xFFC1974A)),
                        ],
                        Text(msg,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            textAlign:
                                alignLeft ? TextAlign.left : TextAlign.center,
                            style: TextStyle(
                                color: msgCol,
                                fontSize: msgFs(),
                                fontWeight: FontWeight.w500,
                                height: 1.25,
                                shadows: const [
                                  Shadow(blurRadius: 5, color: Colors.black87)
                                ])),
                      ],
                    ),
                  ),
                ),
              // Company logo or big name (library path)
              if (showCompany)
                Align(
                  alignment: alignFor(companyPosEff),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _scrim(
                      companyLogo.isNotEmpty
                          ? ConstrainedBox(
                              constraints: BoxConstraints(
                                  maxWidth:
                                      hasMsg ? c.maxWidth * 0.22 : c.maxWidth),
                              child: Image.network(
                                  CloudinaryService.logoUrl(companyLogo),
                                  height: h * (hasMsg ? 0.34 : 0.40),
                                  fit: BoxFit.contain),
                            )
                          : Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: (h * 0.20).clamp(16.0, 34.0),
                                  fontWeight: FontWeight.bold,
                                  shadows: const [
                                    Shadow(blurRadius: 4, color: Colors.black87)
                                  ]),
                            ),
                    ),
                  ),
                ),
              // TilesDesign mark — shown only when admin enabled it for this
              // stockist (td_show), at the stockist's chosen position, any source.
              if (tdShow && tdPos != 'none')
                Align(
                  alignment: alignFor(tdPos),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: _scrim(Image.asset(
                        tdPos == 'footer'
                            ? 'assets/brand/tilesdesign_wide.png'
                            : 'assets/brand/tilesdesign_square.png',
                        height: tdPos == 'footer' ? h * 0.16 : h * 0.22)),
                  ),
                ),
              // Welcome trust strip
              if (showWelcome) _welcome(name),
            ],
          ),
        );
      },
    );
  }

  // A subtle translucent backing so an overlay stays legible on any art.
  Widget _scrim(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  // Brand-colour gradient shown when no banner image is configured.
  Widget _gradient() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [brandColor, Color.lerp(brandColor, Colors.black, 0.35)!],
          ),
        ),
      );

  // Centred "Welcome to [name]" over a dark scrim for generic/plain banners.
  Widget _welcome(String name) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xB3000000), Color(0x00000000)],
            ),
          ),
          child: Text(
            name.trim().isEmpty ? 'Welcome' : 'Welcome to $name',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(blurRadius: 4, color: Colors.black54)]),
          ),
        ),
      );
}
