import 'package:xml/xml.dart';

import 'text_book.dart';

/// Дочерние элементы с локальным именем [local] (без учёта пространства имён).
Iterable<XmlElement> kids(XmlElement e, String local) => e.childElements.where((c) => c.name.local == local);

XmlElement? kid(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

/// Значение атрибута по локальному имени (`l:href`, `xlink:href`, `href`).
String? attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/// Весь текст элемента одной строкой.
String textOf(XmlElement e) => e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Текст узла, если это текст или CDATA.
String? dataOf(XmlNode n) => switch (n) {
      XmlText(:final value) => value,
      XmlCDATA(:final value) => value,
      _ => null,
    };

/// Добавить в [b] текст элемента с начертанием: [italicTags] и [boldTags] —
/// локальные имена тегов, [skipTags] — что пропустить целиком.
void addInline(
  BlockBuilder b,
  XmlNode node, {
  required Set<String> italicTags,
  required Set<String> boldTags,
  Set<String> skipTags = const {},
  bool bold = false,
  bool italic = false,
  String? note,
  String? Function(XmlElement link)? noteRef,
}) {
  for (final c in node.children) {
    final text = dataOf(c);
    if (text != null) {
      b.add(text, bold: bold, italic: italic, note: note);
    } else if (c is XmlElement) {
      final n = c.name.local.toLowerCase();
      if (skipTags.contains(n)) continue;
      if (n == 'br') {
        b.add(' ', bold: bold, italic: italic, note: note);
        continue;
      }
      addInline(
        b,
        c,
        italicTags: italicTags,
        boldTags: boldTags,
        skipTags: skipTags,
        bold: bold || boldTags.contains(n),
        italic: italic || italicTags.contains(n),
        note: note ?? (n == 'a' && noteRef != null ? noteRef(c) : null),
        noteRef: noteRef,
      );
    }
  }
}
