import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Bottom sheet offering "Take Photo" (camera) or "Choose from Gallery"
/// (multi-select) for evidence photos — used by both the audit checklist
/// (checkpoint_card.dart) and the NC response form (nc_response_screen.dart)
/// so a checkpoint's evidence isn't gallery-only.
Future<List<File>> pickEvidencePhotos(BuildContext context) async {
  final source = await showModalBottomSheet<_PhotoSource>(
    context: context,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Theme.of(sheetContext).colorScheme.outlineVariant, borderRadius: BorderRadius.circular(999))),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Take Photo'),
            onTap: () => Navigator.pop(sheetContext, _PhotoSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from Gallery'),
            onTap: () => Navigator.pop(sheetContext, _PhotoSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (source == null) return [];

  final picker = ImagePicker();
  if (source == _PhotoSource.camera) {
    final shot = await picker.pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 1600);
    return shot == null ? [] : [File(shot.path)];
  }

  final picked = await picker.pickMultiImage(imageQuality: 80);
  return picked.map((x) => File(x.path)).toList();
}

enum _PhotoSource { camera, gallery }
