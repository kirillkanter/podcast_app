/// Время аудиокниги: файлы друг за другом, главы поверх них.
/// Место от начала книги ↔ файл и место в нём; глава по месту.
library;

class BookTimeline {
  BookTimeline(List<int> trackDurations, List<({int trackIdx, int startMs})> chapters)
      : durations = List.unmodifiable(trackDurations),
        starts = _starts(trackDurations),
        totalMs = trackDurations.fold(0, (s, d) => s + d) {
    chapterStarts = List.unmodifiable([
      for (final c in chapters)
        if (c.trackIdx >= 0 && c.trackIdx < durations.length) starts[c.trackIdx] + c.startMs,
    ]);
  }

  final List<int> durations;

  /// Начало каждого файла от начала книги.
  final List<int> starts;
  final int totalMs;

  /// Начало каждой главы от начала книги.
  late final List<int> chapterStarts;

  static List<int> _starts(List<int> d) {
    final out = <int>[];
    var at = 0;
    for (final x in d) {
      out.add(at);
      at += x;
    }
    return List.unmodifiable(out);
  }

  int globalOf(int track, int ms) {
    if (starts.isEmpty) return 0;
    final t = track.clamp(0, starts.length - 1);
    return starts[t] + ms;
  }

  /// Файл и место в нём для места [globalMs] от начала книги.
  ({int track, int ms}) locate(int globalMs) {
    if (durations.isEmpty) return (track: 0, ms: 0);
    final g = globalMs < 0 ? 0 : globalMs;
    for (var i = 0; i < durations.length; i++) {
      final end = starts[i] + durations[i];
      if (g < end || i == durations.length - 1) {
        final ms = g - starts[i];
        return (track: i, ms: ms < 0 ? 0 : ms);
      }
    }
    return (track: durations.length - 1, ms: 0);
  }

  /// Глава, в которой место [globalMs]. Без глав — 0.
  int chapterAt(int globalMs) {
    var idx = 0;
    for (var i = 0; i < chapterStarts.length; i++) {
      if (chapterStarts[i] <= globalMs) idx = i;
    }
    return idx;
  }

  int chapterStart(int idx) => chapterStarts.isEmpty ? 0 : chapterStarts[idx.clamp(0, chapterStarts.length - 1)];

  int chapterEnd(int idx) => idx + 1 < chapterStarts.length ? chapterStarts[idx + 1] : totalMs;

  int get chapterCount => chapterStarts.length;
}
