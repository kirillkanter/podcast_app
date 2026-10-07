// Пароль синхронизации — в системном хранилище: на Android в Keystore,
// на Windows — зашифрованным средствами Windows (DPAPI), а не открытым
// текстом в базе приложения.
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/db/database.dart';

/// Где хранится пароль.
abstract class PasswordStore {
  Future<String?> read();
  Future<void> write(String? password);
}

/// Системное хранилище.
class SecurePasswordStore implements PasswordStore {
  SecurePasswordStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'sync.password';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String? password) =>
      password == null || password.isEmpty ? _storage.delete(key: _key) : _storage.write(key: _key, value: password);
}

/// Пароль в системном хранилище, а если оно недоступно (старая прошивка,
/// сбой Keystore, тесты) — в базе, как раньше: синхронизация не должна
/// ломаться из-за хранилища. Пароль, сохранённый в базе прежними версиями,
/// при первом чтении переезжает в хранилище.
class SyncPassword {
  SyncPassword(this._db, [PasswordStore? store]) : _store = store ?? SecurePasswordStore();

  final AppDatabase _db;
  final PasswordStore _store;

  /// Прежний ключ в базе.
  static const legacyKey = 'sync.password';

  Future<String?> read() async {
    final legacy = await _db.setting(legacyKey);
    try {
      final stored = await _store.read();
      if (stored != null && stored.isNotEmpty) {
        if (legacy != null && legacy.isNotEmpty) await _db.setSetting(legacyKey, '');
        return stored;
      }
      if (legacy != null && legacy.isNotEmpty) {
        await _store.write(legacy);
        // Убираем из базы, только когда хранилище точно его вернёт.
        if (await _store.read() == legacy) await _db.setSetting(legacyKey, '');
      }
    } catch (e) {
      debugPrint('Хранилище пароля недоступно: $e');
    }
    return legacy;
  }

  Future<void> write(String? password) async {
    try {
      await _store.write(password);
      if (password == null || password.isEmpty || await _store.read() == password) {
        await _db.setSetting(legacyKey, '');
        return;
      }
    } catch (e) {
      debugPrint('Хранилище пароля недоступно: $e');
    }
    await _db.setSetting(legacyKey, password ?? '');
  }
}
