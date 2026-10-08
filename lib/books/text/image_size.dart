/// Размер картинки по заголовку файла (PNG, JPEG, GIF, WebP, BMP) — без
/// декодирования: нужен для разбивки на страницы.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'text_book.dart';

({int width, int height})? imageSize(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  int le32(int i) => le16(i) | (le16(i + 2) << 16);

  if (b.length < 24) return null;
  // PNG: IHDR сразу после подписи.
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return (width: be32(16), height: be32(20));
  }
  // GIF.
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (width: le16(6), height: le16(8));
  }
  // BMP.
  if (b[0] == 0x42 && b[1] == 0x4D && b.length >= 26) {
    return (width: le32(18), height: le32(22).abs());
  }
  // WebP: VP8 / VP8L / VP8X.
  if (b.length >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8 ') return (width: le16(26) & 0x3FFF, height: le16(28) & 0x3FFF);
    if (chunk == 'VP8L') {
      final bits = le32(21);
      return (width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
    }
    if (chunk == 'VP8X') return (width: le24(24) + 1, height: le24(27) + 1);
    return null;
  }
  // JPEG: ищем маркер SOF.
  if (b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0xFF) {
        i += marker == 0xFF ? 1 : 2;
        continue;
      }
      final len = be16(i + 2);
      final sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (sof) return (width: be16(i + 7), height: be16(i + 5));
      i += 2 + len;
    }
  }
  return null;
}

/// Размер SVG по атрибутам width/height или viewBox корневого тега.
({int width, int height})? svgSize(Uint8List b) {
  final head = utf8.decode(b.length > 4000 ? b.sublist(0, 4000) : b, allowMalformed: true);
  final tag = RegExp(r'<svg\b[^>]*>', caseSensitive: false).firstMatch(head)?.group(0);
  if (tag == null) return null;
  double? dim(String name) {
    final m = RegExp('\\b$name\\s*=\\s*["\']\\s*([0-9.]+)\\s*(px)?\\s*["\']').firstMatch(tag);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  var w = dim('width');
  var h = dim('height');
  final vb = RegExp(r'viewBox\s*=\s*["\']\s*[-0-9.]+[\s,]+[-0-9.]+[\s,]+([0-9.]+)[\s,]+([0-9.]+)').firstMatch(tag);
  if ((w == null || h == null) && vb != null) {
    final vw = double.tryParse(vb.group(1)!);
    final vh = double.tryParse(vb.group(2)!);
    if (vw != null && vh != null && vw > 0 && vh > 0) {
      if (w != null) {
        h = w * vh / vw;
      } else if (h != null) {
        w = h * vw / vh;
      } else {
        w = vw;
        h = vh;
      }
    }
  }
  if (w == null || h == null || w < 1 || h < 1) return null;
  return (width: w.round(), height: h.round());
}

/// Картинка книги из байтов: растровая или SVG; `null` — не картинка.
BookImage? bookImageFrom(Uint8List bytes) {
  final raster = imageSize(bytes);
  if (raster != null) {
    return raster.width < 1 || raster.height < 1 ? null : BookImage(bytes, raster.width, raster.height);
  }
  final svg = svgSize(bytes);
  return svg == null ? null : BookImage(bytes, svg.width, svg.height, svg: true);
}
