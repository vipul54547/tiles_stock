import 'package:flutter/material.dart';

/// Non-web fallback: 360 bundles embed only on the web build. The app opens the
/// hosted bundle in the browser instead (see the viewer's link-out).
Widget panoEmbed(String indexUrl) => const SizedBox.shrink();
