import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ImagePreviewScreen extends StatelessWidget {
  final String imageUrl;
  final String heroTag;
  final Map<String, String>? headers;

  const ImagePreviewScreen({
    super.key,
    required this.imageUrl,
    required this.heroTag,
    this.headers,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Center(
          child: Hero(
            tag: heroTag,
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                httpHeaders: headers,
                fit: BoxFit.contain,
                placeholder: (context, _) => const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                errorWidget: (context, _, __) => const Center(
                  child: Icon(Icons.broken_image, size: 64, color: Colors.white54),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
