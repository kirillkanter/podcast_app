<?php
/**
 * Basic Caster: книги — место в книге и текстовые книги целиком.
 *
 * Отдельный файл рядом с oPodSync и bcaster.php: код oPodSync не меняется,
 * используются только его настройки, база и учётные записи. Свои таблицы:
 * bcaster_books (текстовые книги на сервере) и bcaster_book_progress
 * (место в книге — и в аудио, и в текстовой). Файлы книг лежат в
 * DATA_ROOT/books/<id пользователя>/ — папка data закрыта от прямого доступа.
 *
 * Вход — как в API gPodder: логин и пароль в заголовке Authorization (Basic).
 *
 * GET    /books.php?since=N
 *        → {"rev": M, "used": байт, "limit": байт,
 *           "books": [...], "progress": [...]} — изменения после ревизии N.
 * GET    /books.php?progress=ID
 *        → {"progress": {...} | null} — место в одной книге (перед запуском).
 * POST   /books.php   {"progress": [...]}
 *        → {"rev": M, "progress": [...]} — в ответе записи, которые
 *          на сервере новее присланных (их надо применить у себя).
 * PUT    /books.php?upload=ID&title=..&author=..&format=..   тело — файл
 *        (или POST с тем же адресом) → {"rev": M, "used": байт};
 *        507 — не хватает места, 422 — файл не совпал с id (оборвалась загрузка).
 * GET    /books.php?download=ID → файл книги.
 * DELETE /books.php?id=ID (или POST /books.php?delete=ID)
 *        → {"rev": M} — книга удаляется на всех устройствах.
 *
 * Книга: {"id": "t:<sha1 файла>", "title", "author", "format", "size",
 *         "deleted": bool, "changed": мс}
 * Место: {"id": ключ книги, "locator": строка, "position": мс (аудио),
 *         "percent": 0..1, "device": имя устройства, "changed": мс}
 *
 * Конфликты места: побеждает более позднее изменение по полю changed.
 */

namespace OPodSync;

require_once __DIR__ . '/_inc.php';

/** Сколько места под книги на одного пользователя. */
const BOOKS_QUOTA = 2 * 1024 * 1024 * 1024;

/** Самый большой файл книги. */
const BOOKS_MAX_FILE = 200 * 1024 * 1024;

const BOOKS_FORMATS = ['epub', 'fb2', 'fbz', 'txt'];
const BOOKS_MAX_ITEMS = 2000;

function books_reply(int $code, array $data): void
{
	http_response_code($code);
	header('Content-Type: application/json; charset=utf-8');
	header('Cache-Control: no-store');
	echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
	exit;
}

function books_user(DB $db): int
{
	$login = $_SERVER['PHP_AUTH_USER'] ?? '';
	$password = $_SERVER['PHP_AUTH_PW'] ?? '';

	if ($login === '' || $password === '') {
		header('WWW-Authenticate: Basic realm="Basic Caster"');
		books_reply(401, ['message' => 'No username or password provided']);
	}

	$user = $db->firstRow('SELECT id, password FROM users WHERE name = ?;', $login);

	if (!$user || !password_verify($password, $user->password ?? '')) {
		header('WWW-Authenticate: Basic realm="Basic Caster"');
		books_reply(401, ['message' => 'Invalid username/password']);
	}

	return (int) $user->id;
}

function books_install(DB $db): void
{
	$db->exec('CREATE TABLE IF NOT EXISTS bcaster_books (
		user INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
		id TEXT NOT NULL,
		title TEXT NOT NULL,
		author TEXT NULL,
		format TEXT NOT NULL,
		size INTEGER NOT NULL DEFAULT 0,
		deleted INTEGER NOT NULL DEFAULT 0,
		changed INTEGER NOT NULL,
		rev INTEGER NOT NULL,
		PRIMARY KEY (user, id)
	);
	CREATE INDEX IF NOT EXISTS bcaster_books_rev ON bcaster_books (user, rev);
	CREATE TABLE IF NOT EXISTS bcaster_book_progress (
		user INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
		id TEXT NOT NULL,
		locator TEXT NOT NULL,
		position INTEGER NOT NULL DEFAULT 0,
		percent REAL NOT NULL DEFAULT 0,
		device TEXT NULL,
		changed INTEGER NOT NULL,
		rev INTEGER NOT NULL,
		PRIMARY KEY (user, id)
	);
	CREATE INDEX IF NOT EXISTS bcaster_book_progress_rev ON bcaster_book_progress (user, rev);');
}

/** Общая ревизия книг и мест: одна последовательность на пользователя. */
function books_rev(DB $db, int $user): int
{
	return (int) $db->firstColumn('SELECT MAX(r) FROM (
		SELECT COALESCE(MAX(rev), 0) AS r FROM bcaster_books WHERE user = ?
		UNION ALL SELECT COALESCE(MAX(rev), 0) FROM bcaster_book_progress WHERE user = ?);', $user, $user);
}

function books_used(DB $db, int $user): int
{
	return (int) $db->firstColumn('SELECT COALESCE(SUM(size), 0) FROM bcaster_books WHERE user = ? AND deleted = 0;', $user);
}

function books_dir(int $user): string
{
	return DATA_ROOT . '/books/' . $user;
}

/** Путь к файлу книги. id проверен books_valid_id, в имени файла безопасен. */
function books_file(int $user, string $id): string
{
	return books_dir($user) . '/' . str_replace(':', '_', $id) . '.book';
}

/** Текстовая книга: «t:» и sha1 содержимого. */
function books_valid_id(string $id): bool
{
	return (bool) preg_match('/^t:[0-9a-f]{40}$/', $id);
}

/** Ключ места: текстовая книга или аудиокнига («a:» и отпечаток). */
function books_valid_key(string $id): bool
{
	return (bool) preg_match('/^[at]:[0-9a-f]{16,64}$/', $id);
}

function books_progress_row(object $row): array
{
	return [
		'id'       => $row->id,
		'locator'  => $row->locator,
		'position' => (int) $row->position,
		'percent'  => (float) $row->percent,
		'device'   => $row->device,
		'changed'  => (int) $row->changed,
	];
}

function books_get(DB $db, int $user): void
{
	if (isset($_GET['progress'])) {
		$id = (string) $_GET['progress'];
		if (!books_valid_key($id)) {
			books_reply(400, ['message' => 'Bad book id']);
		}
		$row = $db->firstRow('SELECT id, locator, position, percent, device, changed FROM bcaster_book_progress
			WHERE user = ? AND id = ?;', $user, $id);
		books_reply(200, ['progress' => $row ? books_progress_row($row) : null]);
	}

	if (isset($_GET['download'])) {
		books_download($db, $user, (string) $_GET['download']);
	}

	$since = (int) ($_GET['since'] ?? 0);
	$books = [];
	$progress = [];

	foreach ($db->iterate('SELECT id, title, author, format, size, deleted, changed FROM bcaster_books
		WHERE user = ? AND rev > ? ORDER BY rev;', $user, $since) as $row) {
		$books[] = [
			'id'      => $row->id,
			'title'   => $row->title,
			'author'  => $row->author,
			'format'  => $row->format,
			'size'    => (int) $row->size,
			'deleted' => (bool) $row->deleted,
			'changed' => (int) $row->changed,
		];
	}

	foreach ($db->iterate('SELECT id, locator, position, percent, device, changed FROM bcaster_book_progress
		WHERE user = ? AND rev > ? ORDER BY rev;', $user, $since) as $row) {
		$progress[] = books_progress_row($row);
	}

	books_reply(200, [
		'rev'      => books_rev($db, $user),
		'used'     => books_used($db, $user),
		'limit'    => BOOKS_QUOTA,
		'books'    => $books,
		'progress' => $progress,
	]);
}

function books_post(DB $db, int $user): void
{
	$body = json_decode(file_get_contents('php://input'), true);

	if (!is_array($body) || !isset($body['progress']) || !is_array($body['progress'])) {
		books_reply(400, ['message' => 'Expected {"progress": [...]}']);
	}

	if (count($body['progress']) > BOOKS_MAX_ITEMS) {
		books_reply(413, ['message' => 'Too many items, max ' . BOOKS_MAX_ITEMS]);
	}

	$db->exec('BEGIN IMMEDIATE;');
	$rev = books_rev($db, $user);
	$newer = [];

	foreach ($body['progress'] as $item) {
		if (!is_array($item)
			|| !is_string($item['id'] ?? null)
			|| !books_valid_key($item['id'])
			|| !is_string($item['locator'] ?? null)
			|| !is_numeric($item['changed'] ?? null)) {
			continue;
		}

		$changed = (int) $item['changed'];
		$current = $db->firstRow('SELECT id, locator, position, percent, device, changed FROM bcaster_book_progress
			WHERE user = ? AND id = ?;', $user, $item['id']);

		// Более раннее изменение не затирает более позднее — отдаём
		// устройству то, что новее.
		if ($current && (int) $current->changed >= $changed) {
			if ((int) $current->changed > $changed) {
				$newer[] = books_progress_row($current);
			}
			continue;
		}

		$rev++;
		$db->simple('INSERT OR REPLACE INTO bcaster_book_progress (user, id, locator, position, percent, device, changed, rev)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
			$user,
			$item['id'],
			mb_substr($item['locator'], 0, 500),
			is_numeric($item['position'] ?? null) ? max(0, (int) $item['position']) : 0,
			is_numeric($item['percent'] ?? null) ? min(1, max(0, (float) $item['percent'])) : 0,
			is_string($item['device'] ?? null) ? mb_substr($item['device'], 0, 100) : null,
			$changed,
			$rev
		);
	}

	$db->exec('COMMIT;');
	books_reply(200, ['rev' => $rev, 'progress' => $newer]);
}

function books_put(DB $db, int $user): void
{
	$id = (string) ($_GET['upload'] ?? '');
	$format = strtolower((string) ($_GET['format'] ?? ''));
	$title = trim((string) ($_GET['title'] ?? ''));
	$author = trim((string) ($_GET['author'] ?? ''));

	if (!books_valid_id($id) || !in_array($format, BOOKS_FORMATS, true) || $title === '') {
		books_reply(400, ['message' => 'Bad book id, format or title']);
	}

	$existing = $db->firstRow('SELECT size, deleted FROM bcaster_books WHERE user = ? AND id = ?;', $user, $id);

	// Уже есть — второе устройство с той же книгой: файл не нужен.
	if ($existing && !$existing->deleted && is_file(books_file($user, $id))) {
		books_reply(200, ['rev' => books_rev($db, $user), 'used' => books_used($db, $user), 'exists' => true]);
	}

	$declared = (int) ($_SERVER['CONTENT_LENGTH'] ?? 0);
	if ($declared > BOOKS_MAX_FILE) {
		books_reply(413, ['message' => 'File too large, max ' . BOOKS_MAX_FILE]);
	}
	if (books_used($db, $user) + $declared > BOOKS_QUOTA) {
		books_reply(507, ['message' => 'Quota exceeded', 'used' => books_used($db, $user), 'limit' => BOOKS_QUOTA]);
	}

	$dir = books_dir($user);
	if (!is_dir($dir) && !mkdir($dir, 0700, true) && !is_dir($dir)) {
		throw new \RuntimeException('Cannot create ' . $dir);
	}

	// Пишем во временный файл и проверяем содержимое: id — это sha1 файла,
	// так оборванная загрузка не превратится в испорченную книгу.
	$tmp = $dir . '/upload-' . bin2hex(random_bytes(8)) . '.tmp';
	$in = fopen('php://input', 'rb');
	$out = fopen($tmp, 'wb');
	$hash = hash_init('sha1');
	$size = 0;

	while (!feof($in)) {
		$chunk = fread($in, 1024 * 1024);
		if ($chunk === false) {
			break;
		}
		$size += strlen($chunk);
		if ($size > BOOKS_MAX_FILE) {
			fclose($in);
			fclose($out);
			unlink($tmp);
			books_reply(413, ['message' => 'File too large, max ' . BOOKS_MAX_FILE]);
		}
		hash_update($hash, $chunk);
		fwrite($out, $chunk);
	}

	fclose($in);
	fclose($out);

	if ('t:' . hash_final($hash) !== $id) {
		unlink($tmp);
		books_reply(422, ['message' => 'Content does not match book id']);
	}

	$db->exec('BEGIN IMMEDIATE;');

	if (books_used($db, $user) + $size > BOOKS_QUOTA) {
		$db->exec('ROLLBACK;');
		unlink($tmp);
		books_reply(507, ['message' => 'Quota exceeded', 'used' => books_used($db, $user), 'limit' => BOOKS_QUOTA]);
	}

	rename($tmp, books_file($user, $id));
	$rev = books_rev($db, $user) + 1;
	$db->simple('INSERT OR REPLACE INTO bcaster_books (user, id, title, author, format, size, deleted, changed, rev)
		VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?);',
		$user, $id, mb_substr($title, 0, 500), $author === '' ? null : mb_substr($author, 0, 500),
		$format, $size, (int) round(microtime(true) * 1000), $rev);
	$db->exec('COMMIT;');

	books_reply(200, ['rev' => $rev, 'used' => books_used($db, $user)]);
}

function books_download(DB $db, int $user, string $id): void
{
	if (!books_valid_id($id)) {
		books_reply(400, ['message' => 'Bad book id']);
	}

	$row = $db->firstRow('SELECT format, deleted FROM bcaster_books WHERE user = ? AND id = ?;', $user, $id);
	$path = books_file($user, $id);

	if (!$row || $row->deleted || !is_file($path)) {
		books_reply(404, ['message' => 'Book not found']);
	}

	http_response_code(200);
	header('Content-Type: application/octet-stream');
	header('Content-Length: ' . filesize($path));
	header('Cache-Control: no-store');
	readfile($path);
	exit;
}

function books_delete(DB $db, int $user): void
{
	$id = (string) ($_GET['id'] ?? '');

	if (!books_valid_id($id)) {
		books_reply(400, ['message' => 'Bad book id']);
	}

	$db->exec('BEGIN IMMEDIATE;');
	$rev = books_rev($db, $user) + 1;
	$now = (int) round(microtime(true) * 1000);
	$row = $db->firstRow('SELECT title FROM bcaster_books WHERE user = ? AND id = ?;', $user, $id);

	// Запись остаётся с пометкой deleted — так удаление дойдёт до всех
	// устройств; размер обнуляется, место освобождается.
	if ($row) {
		$db->simple('UPDATE bcaster_books SET deleted = 1, size = 0, changed = ?, rev = ? WHERE user = ? AND id = ?;',
			$now, $rev, $user, $id);
	}
	else {
		$db->simple('INSERT INTO bcaster_books (user, id, title, author, format, size, deleted, changed, rev)
			VALUES (?, ?, ?, NULL, ?, 0, 1, ?, ?);', $user, $id, '', 'txt', $now, $rev);
	}

	$db->simple('DELETE FROM bcaster_book_progress WHERE user = ? AND id = ?;', $user, $id);
	$db->exec('COMMIT;');

	$path = books_file($user, $id);
	if (is_file($path)) {
		unlink($path);
	}

	books_reply(200, ['rev' => $rev]);
}

try {
	$db = DB::getInstance();
	books_install($db);
	$user = books_user($db);

	switch ($_SERVER['REQUEST_METHOD'] ?? 'GET') {
		case 'GET':
			books_get($db, $user);
			break;
		case 'POST':
			// Некоторые хостинги не пропускают PUT и DELETE, поэтому то же
			// самое можно сделать через POST.
			if (isset($_GET['upload'])) {
				books_put($db, $user);
			}
			elseif (isset($_GET['delete'])) {
				$_GET['id'] = $_GET['delete'];
				books_delete($db, $user);
			}
			books_post($db, $user);
			break;
		case 'PUT':
			books_put($db, $user);
			break;
		case 'DELETE':
			books_delete($db, $user);
			break;
		default:
			books_reply(405, ['message' => 'Method not allowed']);
	}
}
catch (\Throwable $e) {
	error_log('books.php: ' . $e->getMessage());
	books_reply(500, ['message' => 'Server error']);
}
