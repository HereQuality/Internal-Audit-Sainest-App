import 'package:flutter/material.dart';

/// Full-screen, swipeable, pinch-to-zoom viewer for a set of evidence
/// photos — opened by tapping any thumbnail (checkpoint evidence, NC
/// response photos). Takes `ImageProvider`s rather than URLs/Files
/// directly so callers can pass either `CachedNetworkImageProvider` (an
/// already-uploaded photo) or `FileImage` (a freshly-picked, not-yet-
/// uploaded one) through the same API.
Future<void> openPhotoViewer(
  BuildContext context, {
  required List<ImageProvider> images,
  int initialIndex = 0,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PhotoViewerScreen(images: images, initialIndex: initialIndex),
    ),
  );
}

class _PhotoViewerScreen extends StatefulWidget {
  final List<ImageProvider> images;
  final int initialIndex;

  const _PhotoViewerScreen({required this.images, required this.initialIndex});

  @override
  State<_PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(child: Image(image: widget.images[i], fit: BoxFit.contain)),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 26),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  if (widget.images.length > 1) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                      child: Text(
                        '${_index + 1} / ${widget.images.length}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 40), // balances the close button so the counter stays centered
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
