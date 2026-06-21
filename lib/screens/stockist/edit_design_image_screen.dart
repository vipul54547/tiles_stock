import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/cloudinary_service.dart';

const _navy = Color(0xFF1B4F72);

/// Full-screen "change the design's image" window. Shows the PRESENT image and a
/// tappable "Add New Image" card side by side; once a new photo is picked
/// (camera / gallery, uploaded to Cloudinary) the two sit side by side with an
/// arrow so the stockist compares before committing. Returns the NEW image URL on
/// Save, or null on Cancel. Persisting it to the master is the caller's job.
class EditDesignImageScreen extends StatefulWidget {
  final String presentImageUrl;
  final String designName;
  final String size;

  const EditDesignImageScreen({
    super.key,
    required this.presentImageUrl,
    this.designName = '',
    this.size = '',
  });

  @override
  State<EditDesignImageScreen> createState() => _EditDesignImageScreenState();
}

class _EditDesignImageScreenState extends State<EditDesignImageScreen> {
  final _picker = ImagePicker();
  String _newUrl = '';
  bool _uploading = false;
  String? _error;

  bool get _hasNew => _newUrl.isNotEmpty;

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: _navy),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: _navy),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x =
        await _picker.pickImage(source: source, maxWidth: 1600, imageQuality: 88);
    if (x == null) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    final url = await CloudinaryService.uploadImage(x.path);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      if (url != null) {
        _newUrl = url;
      } else {
        _error = 'Image upload failed. Try again.';
      }
    });
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasNew) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard new image?'),
        content:
            const Text('You picked a new image but have not saved it yet.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await _confirmDiscard()) return;
        if (context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Change design image')),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.designName.isNotEmpty)
                      Text(widget.designName,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    if (widget.size.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(widget.size.replaceAll(' mm', ''),
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 13)),
                      ),
                    const SizedBox(height: 18),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: _card(
                              title: 'Present Image',
                              child: _imageBox(widget.presentImageUrl,
                                  placeholder: 'No image yet'),
                            ),
                          ),
                          _arrow(),
                          Expanded(
                            child: _card(
                              title: 'New Image',
                              child: _newImageBox(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      _hasNew
                          ? 'Saving replaces the present image for this design '
                              'everywhere it appears.'
                          : 'Tap “Add New Image” to take a photo or choose one '
                              'from your gallery.',
                      style: TextStyle(
                          fontSize: 12.5, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) => Column(
        children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          AspectRatio(aspectRatio: 1, child: child),
        ],
      );

  Widget _arrow() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(Icons.arrow_forward,
            size: 26, color: _hasNew ? _navy : Colors.grey.shade300),
      );

  Widget _imageBox(String url, {required String placeholder}) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.grey.shade100,
          child: url.isEmpty
              ? Center(
                  child: Text(placeholder,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.grey.shade400, fontSize: 12)))
              : CachedNetworkImage(
                  imageUrl: CloudinaryService.thumbUrl(url, width: 600),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey.shade200),
                  errorWidget: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.grey)),
                ),
        ),
      );

  Widget _newImageBox() {
    if (_uploading) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.grey.shade100,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_hasNew) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _imageBox(_newUrl, placeholder: ''),
          Positioned(
            right: 6,
            bottom: 6,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _pickImage,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.refresh, color: Colors.white, size: 18),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return InkWell(
      onTap: _pickImage,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _navy, width: 1.5),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, color: _navy, size: 32),
            SizedBox(height: 8),
            Text('Add New Image',
                style:
                    TextStyle(color: _navy, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _uploading
                      ? null
                      : () async {
                          if (!await _confirmDiscard()) return;
                          if (mounted) Navigator.pop(context);
                        },
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_hasNew && !_uploading)
                      ? () => Navigator.pop(context, _newUrl)
                      : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _navy,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      );
}
