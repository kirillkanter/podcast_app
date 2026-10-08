/// Место в книге — одинаковая запись на всех устройствах.
library;

/// Аудиокнига: номер файла и место в нём.
class AudioLocator {
  const AudioLocator(this.track, this.ms);

  final int track;
  final int ms;

  String encode() => 't$track:$ms';

  static final _re = RegExp(r'^t(\d+):(\d+)$');

  static AudioLocator? parse(String? value) {
    final m = _re.firstMatch(value ?? '');
    if (m == null) return null;
    return AudioLocator(int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  @override
  bool operator ==(Object other) => other is AudioLocator && other.track == track && other.ms == ms;

  @override
  int get hashCode => Object.hash(track, ms);

  @override
  String toString() => encode();
}

/// Текстовая книга: глава, абзац в главе, символ в абзаце.
class TextLocator implements Comparable<TextLocator> {
  const TextLocator(this.chapter, this.block, this.offset);

  static const start = TextLocator(0, 0, 0);

  final int chapter;
  final int block;
  final int offset;

  String encode() => 'c$chapter:b$block:o$offset';

  static final _re = RegExp(r'^c(\d+):b(\d+):o(\d+)$');

  static TextLocator? parse(String? value) {
    final m = _re.firstMatch(value ?? '');
    if (m == null) return null;
    return TextLocator(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  @override
  int compareTo(TextLocator other) {
    if (chapter != other.chapter) return chapter.compareTo(other.chapter);
    if (block != other.block) return block.compareTo(other.block);
    return offset.compareTo(other.offset);
  }

  @override
  bool operator ==(Object other) =>
      other is TextLocator && other.chapter == chapter && other.block == block && other.offset == offset;

  @override
  int get hashCode => Object.hash(chapter, block, offset);

  @override
  String toString() => encode();
}
