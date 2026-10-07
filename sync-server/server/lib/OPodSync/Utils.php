<?php

namespace OPodSync;

class Utils
{
	static public function format_description(string $str): string
	{
		$str = str_replace('</p>', "\n\n", $str);
		$str = preg_replace_callback('!<a[^>]*href=(".*?"|\'.*?\'|\S+)[^>]*>(.*?)</a>!i', function ($match) {
			$url = trim($match[1], '"\'');
			if ($url === $match[2]) {
				return $match[1];
			}
			else {
				return '[' . $match[2] . '](' . $url . ')';
			}
		}, $str);
		$str = htmlspecialchars(strip_tags($str));
		$str = preg_replace("!(?:\r?\n){3,}!", "\n\n", $str);
		$str = preg_replace('!\[([^\]]+)\]\(([^\)]+)\)!', '<a href="$2">$1</a>', $str);
		$str = preg_replace(';(?<!")https?://[^<\s]+(?!");', '<a href="$0">$0</a>', $str);
		$str = nl2br($str);
		return $str;
	}

	static public function format_duration(?int $duration): string
	{
		if (!$duration) {
			return '0:00';
		}

		$h = floor($duration / 3600);
		$m = floor(($duration % 3600) / 60);
		$s = $duration % 60;

		$out = '';

		if ($h) {
			$out .= $h . ':';
		}

		$out .= sprintf('%02d:%02d', $m, $s);
		return $out;
	}

	static public function relative_date(int $ts): string
	{
		// Basic Caster: по-русски, с правильным склонением.
		$diff = (new \DateTime)->diff(new \DateTime('@' . $ts));

		$plural = function (int $n, string $one, string $few, string $many): string {
			$n10 = $n % 10;
			$n100 = $n % 100;
			$word = ($n10 === 1 && $n100 !== 11) ? $one : (($n10 >= 2 && $n10 <= 4 && ($n100 < 12 || $n100 > 14)) ? $few : $many);
			return $n . ' ' . $word;
		};

		if ($diff->y) {
			return $plural($diff->y, 'год', 'года', 'лет');
		}
		elseif ($diff->m) {
			return $plural($diff->m, 'месяц', 'месяца', 'месяцев');
		}
		elseif ($diff->d) {
			return $plural($diff->d, 'день', 'дня', 'дней');
		}
		elseif ($diff->h) {
			return $plural($diff->h, 'час', 'часа', 'часов');
		}
		else {
			return $plural(max(1, $diff->i), 'минуту', 'минуты', 'минут');
		}
	}
}
