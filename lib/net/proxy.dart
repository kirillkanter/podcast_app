/// Прокси для подкастов, чьи сайты недоступны напрямую (личная версия).
///
/// Свой посредник (например, Cloudflare Worker) принимает запрос вида
/// `<адрес прокси>?url=<исходный адрес>&key=<ключ>`, сам скачивает ленту,
/// аудио или картинку и отдаёт приложению. Сайт попадает в список
/// «через прокси», когда лента не загрузилась напрямую, а через прокси —
/// да; заодно туда попадают сайты аудио и обложек этой ленты.
library;

import '../data/db/database.dart';
import '../edition.dart';

abstract final class ProxySettings {
  static const url = 'proxy.url';
  static const key = 'proxy.key';

  /// Сайты, которые открываются только через прокси, по одному в строке.
  static const hosts = 'proxy.hosts';
}

class NetProxy {
  NetProxy._();

  static final instance = NetProxy._();

  AppDatabase? _db;
  Future<void>? _loaded;
  String? _base;
  String _key = '';
  final _hosts = <String>{};

  /// Подключить базу настроек; повторные вызовы ничего не делают.
  void attach(AppDatabase db) {
    if (_db != null) return;
    _db = db;
    _loaded = _load();
  }

  /// Настройки прочитаны из базы.
  Future<void> ready() => _loaded ?? Future<void>.value();

  Future<void> _load() async {
    final db = _db!;
    final url = (await db.setting(ProxySettings.url))?.trim() ?? '';
    _base = url.isEmpty ? null : url;
    _key = (await db.setting(ProxySettings.key))?.trim() ?? '';
    _hosts
      ..clear()
      ..addAll((await db.setting(ProxySettings.hosts) ?? '').split('\n').map((h) => h.trim()).where((h) => h.isNotEmpty));
  }

  /// Прокси задан (только в личной версии).
  bool get enabled => Edition.hasProxy && _base != null;

  String? get base => _base;
  String get key => _key;
  int get hostCount => _hosts.length;

  bool isBlocked(Uri uri) => _hosts.contains(uri.host.toLowerCase());

  /// Тот же адрес, но через прокси.
  Uri via(Uri target) {
    final base = Uri.parse(_base!);
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'url': target.toString(),
      if (_key.isNotEmpty) 'key': _key,
    });
  }

  /// Адрес для загрузки: через прокси, если сайт в списке, иначе как есть.
  String rewrite(String url) {
    if (!enabled) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || !isBlocked(uri)) return url;
    return via(uri).toString();
  }

  /// Запомнить сайты, которые открываются только через прокси.
  Future<void> markBlocked(Iterable<String> urls) async {
    var changed = false;
    for (final url in urls) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      if (host.isNotEmpty && _hosts.add(host)) changed = true;
    }
    if (changed) await _db?.setSetting(ProxySettings.hosts, _hosts.join('\n'));
  }

  /// Сохранить адрес и ключ прокси; пустой адрес — прокси выключен.
  Future<void> configure({required String url, required String key}) async {
    final db = _db;
    if (db == null) return;
    await db.setSetting(ProxySettings.url, url.trim());
    await db.setSetting(ProxySettings.key, key.trim());
    _base = url.trim().isEmpty ? null : url.trim();
    _key = key.trim();
  }

  /// Забыть список сайтов: снова пробовать их напрямую.
  Future<void> clearHosts() async {
    _hosts.clear();
    await _db?.setSetting(ProxySettings.hosts, '');
  }
}
