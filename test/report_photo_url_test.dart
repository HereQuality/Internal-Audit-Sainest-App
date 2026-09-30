import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/report_photo_utils.dart';

/// The pure helpers behind the report PDF's photo handling (see
/// lib/utils/report_photo_utils.dart): the Cloudinary shrink URL, the JPEG/PNG
/// magic-byte checks that replaced a full decode of every photo, and the
/// bounded download pool.
void main() {
  const t = reportPhotoTransformation;

  group('optimizedReportPhotoUrl', () {
    test('the transformation is the agreed one', () {
      expect(t, 'w_800,q_70,f_jpg,c_limit');
    });

    test('inserts the transformation after /upload/ of a versioned Cloudinary URL', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1712345678/audit_evidence/abc.jpg'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1712345678/audit_evidence/abc.jpg',
      );
    });

    test('also handles a URL with no version segment', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/sample.jpg'),
        'https://res.cloudinary.com/demo/image/upload/$t/sample.jpg',
      );
    });

    test('a png/webp/jpeg extension is swapped to .jpg so f_jpg is not contradicted', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b.png'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1/a/b.jpg',
      );
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b.webp'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1/a/b.jpg',
      );
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b.JPEG'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1/a/b.jpg',
      );
    });

    test('a query string is kept and only the path is touched', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b.png?_a=xyz'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1/a/b.jpg?_a=xyz',
      );
    });

    test('an extension-less public id is left as it is', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b'),
        'https://res.cloudinary.com/demo/image/upload/$t/v1/a/b',
      );
    });

    test('a folder that merely contains an underscore is not mistaken for a transformation', () {
      expect(
        optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/audit_evidence/b.jpg'),
        'https://res.cloudinary.com/demo/image/upload/$t/audit_evidence/b.jpg',
      );
    });

    test('a URL that already carries a transformation is returned unchanged', () {
      const withComma = 'https://res.cloudinary.com/demo/image/upload/w_500,c_limit/v1/a/b.jpg';
      const single = 'https://res.cloudinary.com/demo/image/upload/f_auto/v1/a/b.jpg';
      const named = 'https://res.cloudinary.com/demo/image/upload/t_thumb/v1/a/b.jpg';
      expect(optimizedReportPhotoUrl(withComma), withComma);
      expect(optimizedReportPhotoUrl(single), single);
      expect(optimizedReportPhotoUrl(named), named);
    });

    test('a signed delivery URL is returned unchanged (inserting would break the signature)', () {
      const signed = 'https://res.cloudinary.com/demo/image/upload/s--AbCdEfGh--/v1/a/b.jpg';
      expect(optimizedReportPhotoUrl(signed), signed);
    });

    test('is idempotent', () {
      final once = optimizedReportPhotoUrl('https://res.cloudinary.com/demo/image/upload/v1/a/b.png');
      expect(optimizedReportPhotoUrl(once), once);
    });

    test('non-Cloudinary hosts are returned unchanged', () {
      const other = 'https://example.com/image/upload/v1/a/b.jpg';
      const s3 = 'https://bucket.s3.amazonaws.com/evidence/b.png';
      expect(optimizedReportPhotoUrl(other), other);
      expect(optimizedReportPhotoUrl(s3), s3);
    });

    test('Cloudinary URLs that are not /image/upload/ are returned unchanged', () {
      const video = 'https://res.cloudinary.com/demo/video/upload/v1/a/b.mp4';
      const raw = 'https://res.cloudinary.com/demo/raw/upload/v1/a/b.pdf';
      const fetch = 'https://res.cloudinary.com/demo/image/fetch/https://example.com/b.jpg';
      const bare = 'https://res.cloudinary.com/demo/image/upload/';
      expect(optimizedReportPhotoUrl(video), video);
      expect(optimizedReportPhotoUrl(raw), raw);
      expect(optimizedReportPhotoUrl(fetch), fetch);
      expect(optimizedReportPhotoUrl(bare), bare);
    });

    test('garbage never throws and comes back unchanged', () {
      for (final junk in ['', 'not a url', '://', 'cloudinary', 'http://']) {
        expect(optimizedReportPhotoUrl(junk), junk);
      }
    });
  });

  group('image magic bytes', () {
    test('JPEG', () {
      expect(looksLikeJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), isTrue);
      expect(looksLikeJpeg(Uint8List.fromList([0xFF, 0xD8])), isFalse);
      expect(looksLikeJpeg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), isFalse);
      expect(looksLikeJpeg(Uint8List(0)), isFalse);
    });

    test('PNG', () {
      expect(looksLikePng(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])), isTrue);
      expect(looksLikePng(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
      expect(looksLikePng(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), isFalse);
      expect(looksLikePng(Uint8List(0)), isFalse);
    });

    test('WebP (RIFF....WEBP) is neither', () {
      final webp = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
      expect(looksLikeJpeg(webp), isFalse);
      expect(looksLikePng(webp), isFalse);
    });
  });

  group('mapWithConcurrency', () {
    test('returns results in input order regardless of finish order', () async {
      final out = await mapWithConcurrency<int, int>([30, 5, 20, 1], 2, (ms) async {
        await Future<void>.delayed(Duration(milliseconds: ms));
        return ms;
      });
      expect(out, [30, 5, 20, 1]);
    });

    test('never has more than `limit` tasks in flight', () async {
      var inFlight = 0;
      var peak = 0;
      final out = await mapWithConcurrency<int, int>(List.generate(40, (i) => i), 6, (i) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 3));
        inFlight--;
        return i * 2;
      });
      expect(peak, lessThanOrEqualTo(6));
      expect(peak, greaterThan(1), reason: 'it should actually run in parallel');
      expect(out, List.generate(40, (i) => i * 2));
    });

    test('a task that throws gives null for that item and does not stop the rest', () async {
      final out = await mapWithConcurrency<int, String>([1, 2, 3, 4], 2, (i) async {
        if (i == 2) throw StateError('boom');
        return 'ok$i';
      });
      expect(out, ['ok1', null, 'ok3', 'ok4']);
    });

    test('a task may return null itself', () async {
      final out = await mapWithConcurrency<int, int>([1, 2, 3], 2, (i) async => i.isOdd ? i : null);
      expect(out, [1, null, 3]);
    });

    test('an empty list is fine, and a limit larger than the list is too', () async {
      expect(await mapWithConcurrency<int, int>([], 6, (i) async => i), isEmpty);
      expect(await mapWithConcurrency<int, int>([7], 6, (i) async => i + 1), [8]);
    });
  });
}
