// Обложки с кэшем на диске: скачиваются один раз и живут между запусками.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/disk_cache.dart';

/// Скачанные обложки. Через [maxAge] обложка перекачивается в фоне
/// (подкаст мог сменить картинку по тому же адресу), а пока показывается
/// сохранённая. Без сети — сохранённая любой давности.
class CoverCache {
  CoverCache({
    Future<Directory?> Function()? directory,
    http.Client? client,
    this.maxAge = const Duration(days: 14),
    this.maxBytes = 300 * 1024 * 1024,
  })  : _client = client ?? http.Client(),
        _disk = DiskCache(directory ?? _defaultDirectory),
        // В тестах интерфейса обложки не нужны: без сети и без таймеров.
        _offline = directory == null && Platform.environment.containsKey('FLUTTER_TEST');

  static CoverCache instance = CoverCache();

  final http.Client _client;
  final DiskCache _disk;
  final Duration maxAge;
  final int maxBytes;
  final _inflight = <String, Future<Uint8List>>{};
  final bool _offline;
  bool _pruned = false;

  static Future<Directory?> _defaultDirectory() async {
    return Directory(p.join((await getApplicationCacheDirectory()).path, 'covers'));
  }

  /// Байты картинки: из кэша или из сети. Одновременные запросы
  /// одного адреса (обложка в двух размерах) качают файл один раз.
  Future<Uint8List> bytes(String url) => _offline
      ? Future.error(const HttpException('Обложки в тестах не загружаются'))
      : _inflight.putIfAbsent(url, () => _bytes(url).whenComplete(() => _inflight.remove(url)));

  Future<Uint8List> _bytes(String url) async {
    if (!_pruned) {
      _pruned = true;
      unawaited(_disk.prune(maxBytes));
    }
    final cached = await _disk.read(url);
    if (cached != null) {
      if (DateTime.now().difference(cached.saved) > maxAge) {
        unawaited(_download(url).then((_) {}, onError: (Object _) {}));
      }
      return cached.bytes;
    }
    return _download(url);
  }

  Future<Uint8List> _download(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: {'user-agent': 'BasicCaster/0.8 (+https://bcaster.ru)'})
        .timeout(const Duration(seconds: 30));
    final type = response.headers['content-type'] ?? '';
    if (response.statusCode != 200 ||
        response.bodyBytes.isEmpty ||
        (type.isNotEmpty && !type.startsWith('image/') && !type.contains('octet-stream'))) {
      throw HttpException('Обложка не загрузилась (код ${response.statusCode})', uri: Uri.tryParse(url));
    }
    await _disk.write(url, response.bodyBytes);
    return response.bodyBytes;
  }
}

/// Картинка по адресу через [CoverCache].
@immutable
class CachedCoverImage extends ImageProvider<CachedCoverImage> {
  const CachedCoverImage(this.url);

  final String url;

  @override
  Future<CachedCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedCoverImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: url,
        informationCollector: () => [DiagnosticsProperty<String>('Адрес', url)],
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final bytes = await CoverCache.instance.bytes(url);
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // Неудачу не запоминаем: в следующий раз — новая попытка.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is CachedCoverImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'CachedCoverImage("$url")';
}
