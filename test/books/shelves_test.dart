import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podcast_app/data/db/database.dart';
import 'package:podcast_app/data/db/shelves_dao.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('полки: порядок, книги, переименование и удаление', () async {
    final a = await db.createShelf(' Отпуск ');
    final b = await db.createShelf('Перечитать');
    expect((await db.shelves()).map((s) => s.name), ['Отпуск', 'Перечитать']);

    await db.setBookOnShelf(a, 't:1', true);
    await db.setBookOnShelf(a, 't:2', true);
    await db.setBookOnShelf(b, 't:1', true);
    await db.setBookOnShelf(a, 't:2', false);
    expect(await db.watchShelfBooks().first, {a: {'t:1'}, b: {'t:1'}});
    expect(await db.watchShelvesOfBook('t:1').first, {a, b});

    await db.reorderShelves([b, a]);
    expect((await db.shelves()).map((s) => s.uid), [b, a]);

    await db.renameShelf(a, 'Лето');
    await db.deleteShelf(b);
    expect((await db.shelves()).map((s) => s.name), ['Лето']);
    expect((await db.dirtyShelves()).length, 2, reason: 'изменения ждут отправки');
  });

  test('полка с сервера: побеждает более позднее изменение', () async {
    final uid = await db.createShelf('Здесь');
    final local = (await db.shelves()).single;
    await db.applyRemoteShelf(
        uid: uid, name: 'Старое', position: 0, deleted: false, updatedAt: local.updatedAt.subtract(const Duration(minutes: 1)));
    expect((await db.shelves()).single.name, 'Здесь');
    await db.applyRemoteShelf(
        uid: uid, name: 'Новое', position: 0, deleted: false, updatedAt: local.updatedAt.add(const Duration(minutes: 1)));
    expect((await db.shelves()).single.name, 'Новое');

    await db.applyRemoteShelfBook(shelfUid: uid, bookKey: 't:9', deleted: false, updatedAt: DateTime.now());
    expect(await db.watchShelfBooks().first, {uid: {'t:9'}});
    expect(await db.dirtyShelfBooks(), isEmpty, reason: 'пришедшее с сервера не отправляется обратно');
  });
}
