import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/sync/credentials.dart';

class MemoryStore implements PasswordStore {
  String? value;
  bool broken = false;

  @override
  Future<String?> read() async {
    if (broken) throw Exception('Keystore недоступен');
    return value;
  }

  @override
  Future<void> write(String? password) async {
    if (broken) throw Exception('Keystore недоступен');
    value = password;
  }
}

void main() {
  late AppDatabase db;
  late MemoryStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = MemoryStore();
  });

  tearDown(() => db.close());

  test('пароль из базы прежних версий переезжает в хранилище', () async {
    await db.setSetting(SyncPassword.legacyKey, 'secret123');
    final password = SyncPassword(db, store);
    expect(await password.read(), 'secret123');
    expect(store.value, 'secret123');
    expect(await db.setting(SyncPassword.legacyKey), '', reason: 'открытым текстом больше не лежит');
    expect(await password.read(), 'secret123');
  });

  test('новый пароль — только в хранилище; выход стирает его', () async {
    final password = SyncPassword(db, store);
    await password.write('another');
    expect(store.value, 'another');
    expect(await db.setting(SyncPassword.legacyKey), '');
    await password.write(null);
    expect(store.value, isNull);
    expect(await password.read(), anyOf(isNull, isEmpty));
  });

  test('хранилище недоступно — синхронизация работает по-старому', () async {
    store.broken = true;
    final password = SyncPassword(db, store);
    await password.write('fallback');
    expect(await db.setting(SyncPassword.legacyKey), 'fallback');
    expect(await password.read(), 'fallback');
  });
}
