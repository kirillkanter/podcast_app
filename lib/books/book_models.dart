/// Найденные и разобранные книги — до записи в базу.
library;

class ScannedTrack {
  const ScannedTrack({required this.path, required this.durationMs, required this.sizeBytes, this.title});

  final String path;
  final int durationMs;
  final int sizeBytes;
  final String? title;
}

class ScannedChapter {
  const ScannedChapter({required this.title, required this.trackIdx, required this.startMs});

  final String title;
  final int trackIdx;

  /// Начало главы внутри файла [trackIdx].
  final int startMs;
}

/// Аудиокнига: папка с файлами или один файл (m4b).
class ScannedAudioBook {
  const ScannedAudioBook({
    required this.key,
    required this.title,
    required this.path,
    required this.format,
    required this.tracks,
    required this.chapters,
    this.author,
    this.narrator,
    this.description,
    this.cover,
    this.coverFile,
  });

  final String key;
  final String title;
  final String? author;
  final String? narrator;
  final String? description;

  /// Папка книги или её единственный файл.
  final String path;
  final String format;
  final List<ScannedTrack> tracks;
  final List<ScannedChapter> chapters;

  /// Обложка из тегов.
  final List<int>? cover;

  /// Картинка из папки книги (cover.jpg и т. п.).
  final String? coverFile;

  int get durationMs => tracks.fold(0, (s, t) => s + t.durationMs);
  int get sizeBytes => tracks.fold(0, (s, t) => s + t.sizeBytes);
}

/// Метаданные текстовой книги для базы.
class TextBookInfo {
  const TextBookInfo({
    required this.key,
    required this.title,
    required this.format,
    required this.sizeBytes,
    this.author,
    this.language,
    this.description,
  });

  final String key;
  final String title;
  final String? author;
  final String? language;
  final String? description;
  final String format;
  final int sizeBytes;
}
