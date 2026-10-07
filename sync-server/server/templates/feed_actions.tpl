{include file="_head.tpl"}

<p class="center">
	<a href="./subscriptions.php" class="btn sm" aria-label="Назад">&larr; Назад</a>
</p>

<h2>История синхронизации</h2>
<p class="help">Названия некоторых эпизодов могут не отображаться: часть подкастов отдаёт аудио через рекламные и счётные сервисы.</p>
<table>
	<thead>
		<tr>
			<th scope="col">Действие</th>
			<th scope="col">Устройство</th>
			<th scope="col">Дата</th>
			<th scope="col">Эпизод</th>
			<th scope="col">Подробности</th>
		</tr>
	</thead>
	<tbody>
		{foreach from=$actions item="row"}
			<?php
			$url = basename(parse_url($row->url, PHP_URL_PATH));
			$title = $row->title ?? $url;
			$iso_date = date(DATE_ISO8601, $row->changed);
			$date = date('d.m.Y H:i', $row->changed);
			?>
			<tr>
				<th scope="row">{if $row.action === 'play'}Прослушивание{elseif $row.action === 'new'}Не начат{elseif $row.action === 'download'}Загрузка{elseif $row.action === 'delete'}Удаление{else}{$row.action}{/if}</th>
				<td>{$row.device_name}</td>
				<td><time datetime="{$iso_date}">{$date}</time></td>
				<td><a href="{$row.url}">{$title}</a></td>
				<td>{if $row.action === 'play'}Позиция: {$row.position|format_duration}{/if}</td>
			</tr>
		{/foreach}
	</tbody>
</table>

{include file="_foot.tpl"}
