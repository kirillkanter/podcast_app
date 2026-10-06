<?php
/**
 * Настройки сервера синхронизации Basic Caster (oPodSync).
 * Полный список параметров с описанием — в config.dist.php проекта oPodSync.
 */

namespace OPodSync;

// Регистрация открыта для всех: каждый заводит свой аккаунт на сайте.
const ENABLE_SUBSCRIPTIONS = true;

const TITLE = 'Basic Caster Sync';

// Адрес сервера. Если сервер будет на другом адресе — поменять здесь.
const BASE_URL = 'https://sync.bcaster.ru/';

// Не загружать фиды на сервере: приложение делает это само, а хостинг
// не тратит ресурсы на чужие запросы.
const DISABLE_USER_METADATA_UPDATE = true;

// Посетителям — общее сообщение об ошибке, подробности — в data/error.log.
const ERRORS_SHOW = false;
