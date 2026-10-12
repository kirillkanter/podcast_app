// Свои полки с книгами: название, порядок и какие книги на полке.
// Синхронизируются через books.php?shelves=1 (см. BookSync.syncShelves).
import 'package:drift/drift.dart';

import 'books_dao.dart' show newUid;
import 'database.dart';

extension ShelvesDao on AppDatabase {
  /// Полки по порядку (без удалённых).
  Stream<List<UserShelf>> watchShelves() => (select(userShelves)
        ..where((s) => s.deleted.equals(false))
        ..orderBy([(s) => OrderingTerm.asc(s.position), (s) => OrderingTerm.asc(s.name)]))
      .watch();

  Future<List<UserShelf>> shelves() => (select(userShelves)
        ..where((s) => s.deleted.equals(false))
        ..orderBy([(s) => OrderingTerm.asc(s.position), (s) => OrderingTerm.asc(s.name)]))
      .get();

  /// Какие книги на каких полках: uid полки → ключи книг.
  Stream<Map<String, Set<String>>> watchShelfBooks() =>
      (select(userShelfBooks)..where((b) => b.deleted.equals(false))).watch().map((rows) {
        final out = <String, Set<String>>{};
        for (final r in rows) {
          out.putIfAbsent(r.shelfUid, () => <String>{}).add(r.bookKey);
        }
        return out;
      });

  /// Полки, на которых стоит книга.
  Stream<Set<String>> watchShelvesOfBook(String bookKey) => (select(userShelfBooks)
        ..where((b) => b.bookKey.equals(bookKey) & b.deleted.equals(false)))
      .watch()
      .map((rows) => {for (final r in rows) r.shelfUid});

  /// Новая полка в конце списка. Возвращает её uid.
  Future<String> createShelf(String name) async {
    final last = await customSelect(
      'SELECT COALESCE(MAX(position), -1) AS p FROM user_shelves WHERE deleted = 0',
      readsFrom: {userShelves},
    ).getSingle();
    final uid = newUid();
    await into(userShelves).insert(UserShelvesCompanion.insert(
      uid: uid,
      name: name.trim(),
      position: Value(last.read<int>('p') + 1),
      updatedAt: DateTime.now(),
    ));
    return uid;
  }

  Future<void> renameShelf(String uid, String name) =>
      (update(userShelves)..where((s) => s.uid.equals(uid))).write(UserShelvesCompanion(
        name: Value(name.trim()),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));

  /// Удалить полку (книги остаются в библиотеке).
  Future<void> deleteShelf(String uid) =>
      (update(userShelves)..where((s) => s.uid.equals(uid))).write(UserShelvesCompanion(
        deleted: const Value(true),
        updatedAt: Value(DateTime.now()),
        dirty: const Value(true),
      ));

  /// Новый порядок полок: [uids] сверху вниз.
  Future<void> reorderShelves(List<String> uids) => transaction(() async {
        final now = DateTime.now();
        for (var i = 0; i < uids.length; i++) {
          await (update(userShelves)..where((s) => s.uid.equals(uids[i]) & s.position.equals(i).not()))
              .write(UserShelvesCompanion(position: Value(i), updatedAt: Value(now), dirty: const Value(true)));
        }
      });

  /// Поставить книгу на полку или убрать с неё.
  Future<void> setBookOnShelf(String shelfUid, String bookKey, bool on) =>
      into(userShelfBooks).insertOnConflictUpdate(UserShelfBooksCompanion.insert(
        shelfUid: shelfUid,
        bookKey: bookKey,
        deleted: Value(!on),
        updatedAt: DateTime.now(),
        dirty: const Value(true),
      ));

  Future<List<UserShelf>> dirtyShelves() => (select(userShelves)..where((s) => s.dirty.equals(true))).get();

  Future<List<UserShelfBook>> dirtyShelfBooks() =>
      (select(userShelfBooks)..where((b) => b.dirty.equals(true))).get();

  /// Отправлено: снять пометку, если с тех пор не меняли.
  Future<void> markShelfSynced(String uid, DateTime updatedAt) => (update(userShelves)
        ..where((s) => s.uid.equals(uid) & s.updatedAt.equals(updatedAt)))
      .write(const UserShelvesCompanion(dirty: Value(false)));

  Future<void> markShelfBookSynced(String shelfUid, String bookKey, DateTime updatedAt) => (update(userShelfBooks)
        ..where((b) => b.shelfUid.equals(shelfUid) & b.bookKey.equals(bookKey) & b.updatedAt.equals(updatedAt)))
      .write(const UserShelfBooksCompanion(dirty: Value(false)));

  /// Полка с сервера: побеждает более позднее изменение.
  Future<void> applyRemoteShelf({
    required String uid,
    required String name,
    required int position,
    required bool deleted,
    required DateTime updatedAt,
  }) async {
    final local = await (select(userShelves)..where((s) => s.uid.equals(uid))).getSingleOrNull();
    if (local != null && !local.updatedAt.isBefore(updatedAt)) return;
    await into(userShelves).insertOnConflictUpdate(UserShelvesCompanion.insert(
      uid: uid,
      name: name,
      position: Value(position),
      deleted: Value(deleted),
      updatedAt: updatedAt,
      dirty: const Value(false),
    ));
  }

  /// Книга на полке с сервера: побеждает более позднее изменение.
  Future<void> applyRemoteShelfBook({
    required String shelfUid,
    required String bookKey,
    required bool deleted,
    required DateTime updatedAt,
  }) async {
    final local = await (select(userShelfBooks)
          ..where((b) => b.shelfUid.equals(shelfUid) & b.bookKey.equals(bookKey)))
        .getSingleOrNull();
    if (local != null && !local.updatedAt.isBefore(updatedAt)) return;
    await into(userShelfBooks).insertOnConflictUpdate(UserShelfBooksCompanion.insert(
      shelfUid: shelfUid,
      bookKey: bookKey,
      deleted: Value(deleted),
      updatedAt: updatedAt,
      dirty: const Value(false),
    ));
  }
}
