{include file="_head.tpl"}

<nav class="center">
	<ul>
		<li><a href="./" class="btn sm" aria-label="Назад">&larr; Назад</a></li>
		<li><a href="./subscriptions/{$user.name}.opml" class="btn sm">Скачать OPML</a></li>
		{if $can_update_feeds}
			<li><a href="./update.php" class="btn sm">Обновить сведения о подкастах</a></li>
		{/if}
	</ul>
</nav>

{if $error}
	<p class="error center">{$error}</p>
{/if}

{if $success}
	<p class="success center">{$success}</p>
{/if}

<form method="post" action="">
	<fieldset>
		<legend>Подписаться на подкаст</legend>
		<p class="center help">Вставьте адрес RSS-фида подкаста:</p>
		<p class="center"><input type="url" name="feed_url" class="url" placeholder="https://example.com/feed.xml" required /> <button type="submit" class="btn sm">Подписаться</button></p>
	</fieldset>
</form>

<table>
	<thead>
		<tr>
			<th scope="col">Подкаст</th>
			<th scope="col">Последнее действие</th>
			<th scope="col">Действий</th>
			<th scope="col"></th>
		</tr>
	</thead>
	<tbody>

	{foreach from=$subscriptions item="row"}
		<?php
		$iso_date = date(DATE_ISO8601, $row->last_change);
		$title = $row->title ?? strtr($row->url, ['http://' => '', 'https://' => '', '/' => ' / ']);
		?>
		<tr>
			<th scope="row"><a href="./feed.php?id={$row.id}">{$title}</a></th>
			<td><time datetime="{$iso_date}">{$row.last_change|relative_date} назад</time></td>
			<td>{$row.count}</td>
			<td>
				<form method="post" action="" class="inline-form" onsubmit="return confirm('Отписаться от этого подкаста?');">
					<input type="hidden" name="unsubscribe" value="{$row.id}" />
					<button type="submit" class="btn sm btn-danger" title="Отписаться">✕</button>
				</form>
			</td>
		</tr>
	{/foreach}
	</tbody>
</table>

{include file="_foot.tpl"}
