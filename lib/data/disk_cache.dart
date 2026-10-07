// Простой кэш файлов на диске: ключ (адрес) → файл в папке кэша.
// Свежесть — по времени записи файла.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

class DiskCache {
  /// [directory] может вернуть null или бросить исключение (например, в
  /// тестах без платформы) — тогда кэш просто ничего не хранит.
  DiskCache(this._directory, {this.extension = ''});

  final Future<Directory?> Function() _directory;
  final String extension;
  Future<Directory?>? _dir;

  Future<Directory?> get directory => _dir ??= () async {
        try {
          final d = await _directory();
          if (d == null) return null;
          await d.create(recursive: true);
          return d;
        } catch (_) {
          return null;
        }
      }();

  Future<File?> _file(String key) async {
    final dir = await directory;
    return dir == null ? null : File(p.join(dir.path, '${hash(key)}$extension'));
  }

  /// Содержимое и время записи; null — в кэше нет.
  Future<({Uint8List bytes, DateTime saved})?> read(String key) async {
    try {
      final file = await _file(key);
      if (file == null || !await file.exists()) return null;
      final saved = await file.lastModified();
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return (bytes: bytes, saved: saved);
    } catch (_) {
      return null;
    }
  }

  /// Записать через временный файл: оборванная запись не испортит кэш.
  Future<void> write(String key, List<int> bytes) async {
    try {
      final file = await _file(key);
      if (file == null) return;
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Кэш — не главное: без него всё работает, только медленнее.
    }
  }

  /// Удалить старые файлы, если кэш больше [maxBytes]: остаётся 80%.
  Future<void> prune(int maxBytes) async {
    try {
      final dir = await directory;
      if (dir == null) return;
      final files = <(File, int, DateTime)>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        files.add((e, stat.size, stat.modified));
        total += stat.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (file, size, _) in files) {
        if (total <= maxBytes * 0.8) break;
        try {
          await file.delete();
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Имя файла по ключу: 64-битный FNV-1a в шестнадцатеричном виде.
  static String hash(String key) {
    var h = 0xcbf29ce484222325;
    for (final unit in key.codeUnits) {
      h ^= unit;
      h *= 0x100000001b3;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}
