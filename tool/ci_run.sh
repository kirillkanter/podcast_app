#!/usr/bin/env bash
# Запускает команду в CI. При ошибке выводит строки с ошибками аннотацией
# к запуску — её видно на странице Actions и через API без скачивания логов.
# Использование: tool/ci_run.sh "Название" команда аргументы...
title="$1"; shift
log="$(mktemp)"
if "$@" > "$log" 2>&1; then
  tail -5 "$log"
  exit 0
fi
cat "$log"
{ grep -n -i -E "error|fatal|failed|exception|cannot|could not|unresolved" "$log" | grep -v -i -E "^[0-9]+:\s*warning" ; } | head -80 > "$log.fail" || true
[ -s "$log.fail" ] || tail -80 "$log" > "$log.fail"
msg=$(sed -e 's/%/%25/g' -e 's/\r//g' "$log.fail" | cut -c1-400 | awk '{printf "%s%%0A", $0}')
echo "::error title=${title}::${msg}"
exit 1
