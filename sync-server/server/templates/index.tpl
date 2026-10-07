{include file="_head.tpl"}

<p class="center" aria-hidden="true">
	<img src="icon.svg" width="150" />
</p>

<p class="center">
	<a href="login.php" class="btn">Войти</a>
	{if $can_subscribe}
	<a href="register.php" class="btn">Создать аккаунт</a>
	{/if}
</p>

{include file="_foot.tpl"}
