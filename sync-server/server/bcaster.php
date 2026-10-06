<?php
/**
 * Basic Caster: синхронизация очереди и архива между устройствами.
 *
 * В протоколе gPodder нет ни очереди, ни архива, поэтому это отдельный
 * файл рядом с oPodSync: код oPodSync не меняется, используются только его
 * настройки, база и таблица пользователей. Данные лежат в своей таблице
 * bcaster_state той же базы.
 *
 * Вход — как в API gPodder: логин и пароль в заголовке Authorization (Basic).
 *
 * GET  /bcaster.php?since=N
 *      → {"rev": M, "items": [...]} — записи, изменённые после ревизии N.
 * POST /bcaster.php   {"items": [...]}
 *      → {"rev": M}
 *
 * Запись: {"kind": "queue"|"archive", "podcast": адрес фида,
 *          "episode": адрес аудиофайла, "value": число (порядок в очереди),
 *          "removed": bool (убран из очереди / возвращён из архива),
 *          "changed": время изменения на устройстве, мс}
 *
 * Конфликты: побеждает более позднее изменение по полю changed.
 */

namespace OPodSync;

require_once __DIR__ . '/_inc.php';

const BCASTER_MAX_ITEMS = 2000;
const BCASTER_KINDS = ['queue', 'archive'];

function bcaster_reply(int $code, array $data): void
{
	http_response_code($code);
	header('Content-Type: application/json; charset=utf-8');
	header('Cache-Control: no-store');
	echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
	exit;
}

function bcaster_user(DB $db): int
{
	$login = $_SERVER['PHP_AUTH_USER'] ?? '';
	$password = $_SERVER['PHP_AUTH_PW'] ?? '';

	if ($login === '' || $password === '') {
		header('WWW-Authenticate: Basic realm="Basic Caster"');
		bcaster_reply(401, ['message' => 'No username or password provided']);
	}

	$user = $db->firstRow('SELECT id, password FROM users WHERE name = ?;', $login);

	if (!$user || !password_verify($password, $user->password ?? '')) {
		header('WWW-Authenticate: Basic realm="Basic Caster"');
		bcaster_reply(401, ['message' => 'Invalid username/password']);
	}

	return (int) $user->id;
}

function bcaster_install(DB $db): void
{
	$db->exec('CREATE TABLE IF NOT EXISTS bcaster_state (
		user INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
		kind TEXT NOT NULL,
		podcast TEXT NOT NULL,
		episode TEXT NOT NULL,
		value REAL NULL,
		removed INTEGER NOT NULL DEFAULT 0,
		changed INTEGER NOT NULL,
		rev INTEGER NOT NULL,
		PRIMARY KEY (user, kind, episode)
	);
	CREATE INDEX IF NOT EXISTS bcaster_state_rev ON bcaster_state (user, rev);');
}

function bcaster_rev(DB $db, int $user): int
{
	return (int) $db->firstColumn('SELECT COALESCE(MAX(rev), 0) FROM bcaster_state WHERE user = ?;', $user);
}

function bcaster_get(DB $db, int $user): void
{
	$since = (int) ($_GET['since'] ?? 0);
	$items = [];

	foreach ($db->iterate('SELECT kind, podcast, episode, value, removed, changed FROM bcaster_state
		WHERE user = ? AND rev > ? ORDER BY rev;', $user, $since) as $row) {
		$items[] = [
			'kind'    => $row->kind,
			'podcast' => $row->podcast,
			'episode' => $row->episode,
			'value'   => $row->value === null ? null : (float) $row->value,
			'removed' => (bool) $row->removed,
			'changed' => (int) $row->changed,
		];
	}

	bcaster_reply(200, ['rev' => bcaster_rev($db, $user), 'items' => $items]);
}

function bcaster_post(DB $db, int $user): void
{
	$body = json_decode(file_get_contents('php://input'), true);

	if (!is_array($body) || !isset($body['items']) || !is_array($body['items'])) {
		bcaster_reply(400, ['message' => 'Expected {"items": [...]}']);
	}

	if (count($body['items']) > BCASTER_MAX_ITEMS) {
		bcaster_reply(413, ['message' => 'Too many items, max ' . BCASTER_MAX_ITEMS]);
	}

	$db->exec('BEGIN IMMEDIATE;');
	$rev = bcaster_rev($db, $user);

	foreach ($body['items'] as $item) {
		if (!is_array($item)
			|| !in_array($item['kind'] ?? null, BCASTER_KINDS, true)
			|| !is_string($item['podcast'] ?? null)
			|| !is_string($item['episode'] ?? null)
			|| $item['episode'] === ''
			|| !is_numeric($item['changed'] ?? null)) {
			continue;
		}

		$changed = (int) $item['changed'];
		$current = $db->firstColumn('SELECT changed FROM bcaster_state WHERE user = ? AND kind = ? AND episode = ?;',
			$user, $item['kind'], $item['episode']);

		// Более раннее изменение не затирает более позднее.
		if ($current !== null && $current !== false && (int) $current >= $changed) {
			continue;
		}

		$rev++;
		$db->simple('INSERT OR REPLACE INTO bcaster_state (user, kind, podcast, episode, value, removed, changed, rev)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
			$user,
			$item['kind'],
			mb_substr($item['podcast'], 0, 2000),
			mb_substr($item['episode'], 0, 2000),
			is_numeric($item['value'] ?? null) ? (float) $item['value'] : null,
			!empty($item['removed']) ? 1 : 0,
			$changed,
			$rev
		);
	}

	$db->exec('COMMIT;');
	bcaster_reply(200, ['rev' => $rev]);
}

try {
	$db = DB::getInstance();
	bcaster_install($db);
	$user = bcaster_user($db);

	switch ($_SERVER['REQUEST_METHOD'] ?? 'GET') {
		case 'GET':
			bcaster_get($db, $user);
			break;
		case 'POST':
			bcaster_post($db, $user);
			break;
		default:
			bcaster_reply(405, ['message' => 'Method not allowed']);
	}
}
catch (\Throwable $e) {
	error_log('bcaster.php: ' . $e->getMessage());
	bcaster_reply(500, ['message' => 'Server error']);
}
