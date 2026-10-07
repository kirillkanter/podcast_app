<?php

namespace OPodSync;

require_once __DIR__ . '/_inc.php';

if (!$gpodder->user) {
	header('Location: ./login.php');
	exit;
}

if (DISABLE_USER_METADATA_UPDATE) {
	throw new UserException('Обновление сведений о подкастах на сервере отключено.');
}

if (!empty($_POST['update'])) {
	$gpodder->updateAllFeeds();
	exit;
}

$tpl->display('update.tpl');
