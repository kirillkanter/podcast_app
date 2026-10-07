{include file="_head.tpl"}

{if $oktoken}
	<p class="success center">Вход выполнен. Эту страницу можно закрыть и вернуться в приложение.</p>
{/if}

<p class="center"><img src="icon.svg" width="150" alt="" /></p>
<h2 class="center">Вы вошли как {$user.name}</h2>
<p class="center">Активных подписок: {$subscriptions_count}</p>
<nav class="center">
	<ul>
		<li><a href="subscriptions.php" class="btn sm">Мои подписки</a></li>
		{if !$user.external_user_id}
		<li><a href="login.php?logout" class="btn sm">Выйти</a></li>
		{/if}
	</ul>
</nav>

<form method="post" action="">
	<fieldset>
		<legend>Секретное имя для gPodder</legend>
	{if $gpodder_token}
		<h3 class="center">Ваше секретное имя для gPodder: <code>{$gpodder_token}</code></h3>
		<p class="center help">(Укажите его в программе gPodder для компьютера: она не поддерживает пароли.)</p>
		<input type="submit" name="disable_token" value="Отключить секретное имя" class="btn sm" />
	{else}
		<p class="center help">Программа gPodder для компьютера не поддерживает пароли.<br />
			Для неё можно создать секретное имя пользователя. Basic Caster оно не нужно.
		</p>
		<input type="submit" name="enable_token" value="Создать секретное имя" class="btn sm" />
	{/if}
	</fieldset>

	<fieldset>
		<legend>Адрес сервера</legend>
		<p class="center help">Укажите этот адрес в настройках синхронизации подкаст-плеера:</p>
		<p class="center"><input type="text" class="url" value="{$url}" style="field-sizing: content;" readonly="readonly" /> <button class="btn sm" onclick="var i = this.parentNode.firstChild; i.select(); document.execCommand('copy'); return false;">Скопировать</button></p>
	</fieldset>
</form>


{include file="_foot.tpl"}
