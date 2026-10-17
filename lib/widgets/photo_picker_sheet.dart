import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/utils/snackbar.dart';

/// The server shrinks every evidence photo to 1600 px on its longest side, so
/// there is nothing to gain from keeping more on the phone.
const double _kMaxPhotoSide = 1600;

/// Bottom sheet offering "Take Photo" (camera) or "Choose from Gallery"
/// (multi-select) for evidence photos — used by both the audit checklist
/// (checkpoint_card.dart) and the NC response form (nc_response_screen.dart)
/// so a checkpoint's evidence isn't gallery-only.
///
/// Both sources are shrunk to [_kMaxPhotoSide]. The camera always was; the
/// gallery was not, so a 50-megapixel photo came back at full size — a
/// 15 MB file the server refused ("5 MB or smaller"), and on a phone short of
/// memory a bitmap big enough to crash the picker before any photo was
/// returned. A tester's emulator gallery holds tiny pictures, which is why it
/// never showed there.
///
/// [recoveryKey] (the checkpoint's own id) lets a photo survive Android
/// killing this app while the camera is open — see [recoverLostEvidencePhotos].
Future<List<File>> pickEvidencePhotos(BuildContext context, {String? recoveryKey}) async {
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
  try {
    // Written BEFORE the camera/gallery opens and cleared once it hands back:
    // if Android kills this app in between, the marker is what tells the
    // checkpoint it was waiting for a photo (see recoverLostEvidencePhotos).
    await _markPickPending(recoveryKey);
    if (source == _PhotoSource.camera) {
      final shot = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: _kMaxPhotoSide,
        maxHeight: _kMaxPhotoSide,
      );
      return shot == null ? [] : [File(shot.path)];
    }

    final picked = await picker.pickMultiImage(
      imageQuality: 80,
      maxWidth: _kMaxPhotoSide,
      maxHeight: _kMaxPhotoSide,
    );
    // No limit on how many: a checkpoint takes as many photos as the auditor has (each goes up on its own).
    return picked.map((x) => File(x.path)).toList();
  } on PlatformException catch (e) {
    // Camera permission off, no camera, the picker app missing…: say so. This
    // used to throw straight out of the tap handler, so nothing happened and
    // nothing was said.
    if (context.mounted) {
      final camera = source == _PhotoSource.camera;
      showErrorSnackBar(
        context,
        e.code.contains('denied')
            ? (camera ? 'Camera permission is off. Allow it in Settings to take photos.' : 'Photo access is off. Allow it in Settings to pick photos.')
            : (camera ? 'Could not open the camera.' : 'Could not open your photos.'),
      );
    }
    return [];
  } finally {
    // Only a marker THIS pick wrote — another checkpoint's may still be waiting on a lost photo.
    if (recoveryKey != null) await _clearPickPending();
  }
}

enum _PhotoSource { camera, gallery }

// ── A photo Android took away from the app ──────────────────────────────
// Opening the camera puts this app in the background, and a phone short of memory
// (common among field devices — never an emulator with a laptop's RAM behind it)
// may destroy the app's Activity or the whole process while the camera is up. The
// photo is then delivered to an app that no longer remembers asking for it: the
// auditor takes the shot, comes back, and it is simply gone. image_picker keeps
// such a result and hands it out through retrieveLostData() — but only to someone
// who asks, and the checkpoint has to know it was the one that asked.
const String _pendingPickKey = 'evidence_pick_pending';

Future<void> _markPickPending(String? recoveryKey) async {
  if (recoveryKey == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingPickKey, recoveryKey);
  } catch (_) {
    // Best effort — only the recovery below depends on it.
  }
}

Future<void> _clearPickPending() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingPickKey);
  } catch (_) {
    // Best effort.
  }
}

/// The photo(s) Android took the camera/gallery result away from, if THIS
/// checkpoint ([recoveryKey], the same one [pickEvidencePhotos] was given) was
/// the one waiting for it. Empty on every other platform, for every other
/// checkpoint, and when nothing was lost. Call once from the checkpoint's
/// initState: a normal run never has a marker left over (it is cleared as the
/// picker returns), so a marker found here means the app died mid-pick.
Future<List<File>> recoverLostEvidencePhotos(String recoveryKey) async {
  if (!Platform.isAndroid) return const [];
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_pendingPickKey) != recoveryKey) return const [];
    await prefs.remove(_pendingPickKey);
    final lost = await ImagePicker().retrieveLostData();
    if (lost.isEmpty) return const [];
    final files = lost.files ?? [if (lost.file != null) lost.file!];
    return files.map((x) => File(x.path)).where((f) => f.existsSync()).toList();
  } catch (_) {
    return const [];
  }
}
