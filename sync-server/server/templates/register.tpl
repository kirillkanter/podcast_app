{include file="_head.tpl"}

{if $error}
	<p class="error center">{$error}</p>
{/if}

<form method="post" action="">
	<fieldset>
		<legend>Новый аккаунт</legend>
		<dl>
			<dt><label for="login">Имя пользователя</label></dt>
			<dd><input type="text" name="login" required id="login" /></dd>
			<dt><label for="password">Пароль (не короче 8 символов)</label></dt>
			<dd><input type="password" minlength="8" required name="password" id="password" /></dd>
			<dt>Проверка</dt>
			<dd class="ca"><label for="captcha">Введите это число: {$captcha|raw}</label></dd>
			<dd><input type="text" name="captcha" required id="captcha" /></dd>
		</dl>
		<p><button type="submit" class="btn">Создать аккаунт <svg aria-hidden="true" width="40px" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><circle cx="32" cy="32" fill="#4bd37b" r="30"/><path d="m46 14-21 21.6-7-7.2-7 7.2 14 14.4 28-28.8z" fill="#fff"/></svg></button></p>
	</fieldset>
</form>

{include file="_foot.tpl"}