import 'dart:io';

import 'package:dio/dio.dart';

/// A photo the server cannot take (see server/config/auditEvidenceUpload.js — JPEG, PNG or WebP). [message] is
/// written for the person holding the phone.
class UnsupportedPhotoException implements Exception {
  final String message;
  const UnsupportedPhotoException(this.message);
  @override
  String toString() => message;
}

/// The picture formats evidence takes, by what is INSIDE the file.
enum EvidenceImageType {
  jpeg('jpg', 'jpeg'),
  png('png', 'png'),
  webp('webp', 'webp');

  const EvidenceImageType(this.extension, this.subtype);
  final String extension;
  final String subtype;
}

/// What the first bytes of a picture say it is. null when it is none of the three evidence takes (a HEIC from an
/// iPhone, a GIF, a PDF, junk).
EvidenceImageType? imageTypeOfHeader(List<int> h) {
  bool startsWith(List<int> sig, [int at = 0]) {
    if (h.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (h[at + i] != sig[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF])) return EvidenceImageType.jpeg;
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return EvidenceImageType.png;
  // RIFF....WEBP
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return EvidenceImageType.webp;
  return null;
}

/// True for an HEIC/HEIF picture (`....ftyp` + a heic-family brand) — only to say so plainly in the error.
bool _isHeic(List<int> h) {
  if (h.length < 12 || h[4] != 0x66 || h[5] != 0x74 || h[6] != 0x79 || h[7] != 0x70) return false;
  final brand = String.fromCharCodes(h.sublist(8, 12));
  return const ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'].contains(brand);
}

/// The multipart part for one evidence photo — labelled with what the file REALLY is, not what its name claims.
///
/// Dio guesses a part's type from the file NAME alone. A phone's gallery hands over names that lie: Android keeps a
/// `.heic` name on a picture it has already re-encoded to JPEG, and some pickers give none at all. The server then
/// saw `image/heic` (or `application/octet-stream`), and — until it was fixed to say so — quietly dropped the photo
/// while answering "accepted". Sniffing the bytes makes the label right every time; the file name is rewritten to
/// match, so nothing downstream trusts a wrong extension either.
///
/// Throws [UnsupportedPhotoException] for a file that is not one of the three types (or can no longer be read), so
/// the caller can say so instead of sending something the server will refuse.
Future<MultipartFile> evidencePhotoPart(File file) async {
  final List<int> header;
  try {
    final handle = await file.open();
    try {
      header = await handle.read(16);
    } finally {
      await handle.close();
    }
  } on FileSystemException {
    throw const UnsupportedPhotoException('This photo can no longer be read. Please pick it again.');
  }
  final type = imageTypeOfHeader(header);
  if (type == null) {
    throw UnsupportedPhotoException(
      _isHeic(header)
          ? 'This photo is in HEIC format, which cannot be uploaded. Take it with the camera, or pick a JPEG or PNG photo.'
          : 'This file is not a JPEG, PNG or WebP photo, so it cannot be uploaded.',
    );
  }
  final name = file.path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  final base = (dot > 0 ? name.substring(0, dot) : name).trim();
  return MultipartFile.fromFile(
    file.path,
    filename: '${base.isEmpty ? 'photo' : base}.${type.extension}',
    contentType: DioMediaType('image', type.subtype),
  );
}
