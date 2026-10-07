{include file="_head.tpl"}

<p class="center">
	<a href="./subscriptions.php" class="btn sm" aria-label="Назад">&larr; Назад</a>
	<a href="?id={$id}&amp;actions" class="btn sm">История синхронизации</a>
</p>

{if isset($feed->url, $feed->title, $feed->description)}
	<article class="feed">
		{if $feed.image_url}
			<figure><img src="{$feed.image_url}" alt="" /></figure>
		{/if}
		<h2><a href="{$feed.url}">{$feed.title}</a></h2>
		<p>{$feed.description|raw|format_description}</p>
	</article>
{else}
	<p class="help">Сведений об этом подкасте нет.</p>
{/if}

{if count($episodes)}
<h2>Эпизоды ({$episodes|count})</h2>
<table>
	<thead>
		<tr>
			<td></td>
			<th scope="col">Название</th>
			<th scope="col">Дата</th>
			<th scope="col">Прогресс</th>
		</tr>
	</thead>
	<tbody>
		{foreach from=$episodes item="episode"}
			<?php
			$title = $episode->title ?: basename(parse_url($episode->media_url, PHP_URL_PATH));
			$iso_date = $episode->pubdate ? date(DATE_ISO8601, strtotime($episode->pubdate)) : '';
			$date = $episode->pubdate ? date('d.m.Y', strtotime($episode->pubdate)) : '';
			$position = min($episode->duration, $episode->position);
			$left = $episode->duration - $position;
			?>
			<tr class="{if $episode.duration && !$left}disabled{/if}" data-media="{$episode.media_url}" data-podcast="{$feed.feed_url}" data-title="{$title}" data-pos="{$episode.position}" data-total="{$episode.duration}">
				<td><button type="button" class="episode-btn" title="Слушать в браузере">Слушать</button></td>
				<th scope="row"><a href="{$episode.media_url}" class="episode-link">{$title}</a></th>
				<td><time datetime="{$iso_date}">{$date}</time></td>
				<td>
					{if $position}
					<span class="progress">
						{$position|format_duration}
						<progress max="{$episode.duration}" value="{$position}"></progress>
						-{$left|format_duration}
					</span>
					{else}
					<span class="duration">
						{$episode.duration|format_duration}
					</span>
					{/if}
				</td>
			</tr>
		{/foreach}
	</tbody>
</table>
{/if}

<div id="player-bar" hidden>
	<div id="pb-meta">
		<div id="pb-title"></div>
		<div id="pb-status" class="help"></div>
	</div>
	<audio id="pb-audio" controls preload="metadata"></audio>
	<button type="button" id="pb-close" title="Закрыть плеер">&#10005;</button>
</div>
<script src="player.js"></script>

{include file="_foot.tpl"}
