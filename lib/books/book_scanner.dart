/// Поиск аудиокниг в папках: каждая подпапка папки-источника — книга,
/// файлы внутри (и во вложенных папках, например «CD1», «CD2») — по порядку
/// имён. Отдельный файл в корне источника (обычно m4b) — тоже книга.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'audio_tags.dart';
import 'book_models.dart';

const _imageNames = ['cover', 'folder', 'front', 'обложка', 'album'];
const _imageExtensions = {'jpg', 'jpeg', 'png', 'webp'};

String _ext(String path) => p.extension(path).replaceFirst('.', '').toLowerCase();

bool isAudioFile(String path) => audioExtensions.contains(_ext(path));

/// Сравнение имён «по-человечески»: «2» раньше «10».
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final ma = re.allMatches(a.toLowerCase()).toList();
  final mb = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = ma[i].group(0)!;
    final y = mb[i].group(0)!;
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return ma.length.compareTo(mb.length);
}

/// Отпечаток аудиокниги: имена и размеры файлов. Одинаков на устройствах,
/// куда книгу скопировали как есть, даже если папка названа иначе.
String audioBookKey(List<({String name, int size})> files) {
  final text = files.map((f) => '${f.name.toLowerCase()}:${f.size}').join('\n');
  return 'a:${sha1.convert(utf8.encode(text)).toString().substring(0, 32)}';
}

/// «01_glava_odin.mp3» → «01 glava odin».
String _cleanName(String name) =>
    p.basenameWithoutExtension(name).replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

class BookScanner {
  const BookScanner._();

  /// Все книги папки-источника. [onBook] — по мере нахождения (для индикатора).
  static Future<List<ScannedAudioBook>> scanRoot(String root, {void Function(String title)? onBook}) async {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    final entries = await dir.list(followLinks: false).toList();
    entries.sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
    final out = <ScannedAudioBook>[];
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      ScannedAudioBook? book;
      try {
        if (e is Directory) {
          book = await scanFolder(e.path);
        } else if (e is File && isAudioFile(e.path)) {
          book = await scanFile(e.path);
        }
      } catch (_) {
        // Нечитаемая папка — пропускаем, остальные книги важнее.
      }
      if (book != null) {
        out.add(book);
        onBook?.call(book.title);
      }
    }
    return out;
  }

  /// Книга из папки: все аудиофайлы внутри, включая вложенные папки.
  static Future<ScannedAudioBook?> scanFolder(String folder) async {
    final files = <File>[];
    final images = <File>[];
    await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: folder);
      if (p.split(rel).length > 4 || p.split(rel).any((s) => s.startsWith('.'))) continue;
      if (isAudioFile(e.path)) {
        files.add(e);
      } else if (_imageExtensions.contains(_ext(e.path))) {
        images.add(e);
      }
    }
    if (files.isEmpty) return null;
    files.sort((a, b) => naturalCompare(p.relative(a.path, from: folder), p.relative(b.path, from: folder)));
    return _build(path: folder, files: files, images: images, fallbackTitle: _cleanName(p.basename(folder)));
  }

  /// Книга из одного файла (m4b, mp3).
  static Future<ScannedAudioBook?> scanFile(String path) =>
      _build(path: path, files: [File(path)], images: const [], fallbackTitle: _cleanName(path));

  static Future<ScannedAudioBook?> _build({
    required String path,
    required List<File> files,
    required List<File> images,
    required String fallbackTitle,
  }) async {
    final tracks = <ScannedTrack>[];
    final tagsList = <AudioTags>[];
    final sizes = <({String name, int size})>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final size = await file.length();
      final tags = await readAudioTags(file.path, withCover: i == 0);
      tagsList.add(tags);
      sizes.add((name: p.basename(file.path), size: size));
      tracks.add(ScannedTrack(
        path: file.path,
        durationMs: tags.durationMs ?? 0,
        sizeBytes: size,
        title: tags.title,
      ));
    }
    if (tracks.isEmpty) return null;
    final first = tagsList.first;

    String? common(String? Function(AudioTags t) f) {
      final values = tagsList.map(f).whereType<String>().toSet();
      return values.length == 1 ? values.single : null;
    }

    final album = common((t) => t.album) ?? (files.length == 1 ? first.album : null);
    var title = album ?? (files.length == 1 ? first.title : null) ?? fallbackTitle;
    if (title.trim().isEmpty) title = fallbackTitle;
    final author = common((t) => t.albumArtist) ?? common((t) => t.artist) ?? first.albumArtist ?? first.artist;
    final composer = common((t) => t.composer);
    final narrator = composer != null && composer != author ? composer : null;

    // Главы: из тегов (m4b, mp3 с CHAP), иначе — по одной на файл.
    final chapters = <ScannedChapter>[];
    final titledTracks = tracks.map((t) => t.title).whereType<String>().toSet();
    for (var i = 0; i < tracks.length; i++) {
      final embedded = tagsList[i].chapters;
      if (embedded.length > 1) {
        for (var k = 0; k < embedded.length; k++) {
          final c = embedded[k];
          chapters.add(ScannedChapter(
            title: c.title.isEmpty ? 'Глава ${chapters.length + 1}' : c.title,
            trackIdx: i,
            startMs: c.startMs,
          ));
        }
      } else {
        // Название файла из тегов годится, если у файлов оно разное
        // (а не название книги на всех).
        final tagTitle = tracks[i].title;
        final useTag = tagTitle != null && titledTracks.length == tracks.length && tagTitle != title;
        chapters.add(ScannedChapter(
          title: useTag ? tagTitle : (files.length == 1 ? title : _cleanName(files[i].path)),
          trackIdx: i,
          startMs: 0,
        ));
      }
    }

    String? coverFile;
    if (first.cover == null && images.isNotEmpty) {
      images.sort((a, b) {
        int rank(File f) {
          final n = p.basenameWithoutExtension(f.path).toLowerCase();
          final i = _imageNames.indexWhere(n.contains);
          return i < 0 ? 100 : i;
        }

        return rank(a).compareTo(rank(b));
      });
      coverFile = images.first.path;
    }

    return ScannedAudioBook(
      key: audioBookKey(sizes),
      title: title.trim(),
      author: author,
      narrator: narrator,
      description: common((t) => t.comment),
      path: path,
      format: _ext(files.first.path),
      tracks: tracks,
      chapters: chapters,
      cover: first.cover,
      coverFile: coverFile,
    );
  }
}
