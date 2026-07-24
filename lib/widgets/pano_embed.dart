// Inline 360 embed — web renders the Pano2VR bundle in an iframe; other
// platforms fall back to a no-op (the viewer link-outs instead).
export 'pano_embed_stub.dart' if (dart.library.html) 'pano_embed_web.dart';
