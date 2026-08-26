import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/utils/formatters.dart';

class AvatarCircle extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double radius;

  const AvatarCircle({
    super.key,
    required this.name,
    this.imageUrl,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: scheme.primaryContainer,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: imageUrl!,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            placeholder: (context, url) => _initials(scheme),
            errorWidget: (context, url, error) => _initials(scheme),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        Formatters.initials(name),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }

  Widget _initials(ColorScheme scheme) => Center(
        child: Text(
          Formatters.initials(name),
          style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700),
        ),
      );
}
