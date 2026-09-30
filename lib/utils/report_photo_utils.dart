import 'dart:math' as math;
import 'dart:typed_data';

/// utils/report_photo_utils.dart
/// ─────────────────────────────────
/// Small, pure helpers the report PDF builder (report_pdf_builder.dart) uses
/// to keep a very large report (hundreds of evidence photos) light on memory,
/// network and CPU. Kept free of Flutter/pdf/http imports so each one is unit-
/// testable on its own (test/report_photo_url_test.dart).

/// The Cloudinary transformation applied to every evidence photo before it is
/// embedded: at most 800px on the long edge, quality 70, always delivered as a
/// JPEG. The PDF draws a photo in a 100pt square, so 800px is already several
/// times what a printout can show; the original (up to ~1600px, sometimes a
/// PNG/WebP) made every embedded photo — and the whole file pushed through the
/// share sheet — several times larger for nothing. JPEG in particular is
/// embedded by the `pdf` package as-is (no decode, no re-encode), while a PNG
/// is fully decoded at paint time.
const reportPhotoTransformation = 'w_800,q_70,f_jpg,c_limit';

final _transformationSegment = RegExp(r'^[a-z]{1,3}_');
final _rasterExtension = RegExp(r'\.(png|webp|jpeg|jpg)$', caseSensitive: false);

/// The URL to actually download for an evidence photo: for a Cloudinary image
/// URL of the form `.../image/upload/<version or public id>...` it is that URL
/// with [reportPhotoTransformation] inserted right after `/upload/` (and a
/// trailing `.png`/`.webp`/`.jpeg` extension swapped to `.jpg` so the format
/// request cannot be contradicted by the extension). Anything else — another
/// host, a URL that isn't `/image/upload/`, a URL that already carries a
/// transformation (or a signed delivery signature, which inserting in front of
/// would invalidate) — is returned UNCHANGED. Never throws.
///
/// Idempotent: the output already carries a transformation, so running it
/// again returns it as-is.
String optimizedReportPhotoUrl(String url) {
  try {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority || !uri.host.toLowerCase().contains('cloudinary')) {
      return url;
    }
    const marker = '/image/upload/';
    final at = url.indexOf(marker);
    if (at < 0) return url;

    final head = url.substring(0, at + marker.length);
    final rest = url.substring(at + marker.length);
    if (rest.isEmpty) return url;

    // The first path segment after /upload/ is either a transformation
    // ("w_500,c_limit", "f_auto", "t_named"), a signature ("s--…--"), a
    // version ("v1712345678") or the public id / its first folder. Only the
    // last two are safe to prepend a transformation to.
    final slash = rest.indexOf('/');
    final first = slash < 0 ? rest : rest.substring(0, slash);
    if (first.contains(',') || first.startsWith('s--') || _transformationSegment.hasMatch(first)) {
      return url;
    }

    // Split off a query string / fragment so the extension swap only touches
    // the path.
    final tailStart = rest.indexOf(RegExp(r'[?#]'));
    final path = tailStart < 0 ? rest : rest.substring(0, tailStart);
    final tail = tailStart < 0 ? '' : rest.substring(tailStart);
    final jpgPath = path.replaceFirst(_rasterExtension, '.jpg');

    return '$head$reportPhotoTransformation/$jpgPath$tail';
  } catch (_) {
    return url;
  }
}

/// JPEG magic: FF D8 FF.
bool looksLikeJpeg(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

/// PNG magic: 89 'P' 'N' 'G' 0D 0A 1A 0A.
bool looksLikePng(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[4] == 0x0D &&
    bytes[5] == 0x0A &&
    bytes[6] == 0x1A &&
    bytes[7] == 0x0A;

/// Runs [task] over every item with at most [limit] in flight at once and
/// returns the results in the SAME order as [items] — a bounded replacement
/// for `Future.wait(items.map(task))`, which starts every request together
/// (hundreds of photos at once starves each connection into a timeout on a
/// slow network). A [task] that throws yields `null` for that item rather than
/// failing the whole batch, so callers should make [task] handle its own
/// errors when they need to tell the cause apart.
Future<List<R?>> mapWithConcurrency<T, R>(
  List<T> items,
  int limit,
  Future<R?> Function(T item) task,
) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      try {
        results[i] = await task(items[i]);
      } catch (_) {
        results[i] = null;
      }
    }
  }

  final workers = math.max(1, math.min(limit, items.length));
  await Future.wait([for (var w = 0; w < workers; w++) worker()]);
  return results;
}
