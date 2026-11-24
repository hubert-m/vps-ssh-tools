#!/usr/bin/env bash
# Regresja: mawk 1.3.4 (Debian 12) nie obsługuje {n}/{n,m} w regex — jawne powtórzenia.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# Blokada [klasa]{n} w plikach z awk (poza komentarzami / bash [[ =~ ]] / grep -E).
files=(
  commands/logs/main.sh
  commands/mail/spam.sh
  commands/traffic/main.sh
  commands/dns/watch.sh
  commands/ols/vhost.sh
)
for f in "${files[@]}"; do
  bad_lines="$(
    grep -nE '(\[[^]]+\]|\[:[^]]+:\])\{[0-9]' "${f}" 2>/dev/null \
      | grep -vE '[[:space:]]*#|grep -E|[[:space:]]*\[\[|=\~' \
      || true
  )"
  if [[ -z "${bad_lines}" ]]; then
    ok "no-interval:${f##*/}"
  else
    bad "interval-in-awk:${f##*/}"
    printf '%s\n' "${bad_lines}" >&2
  fi
done

# shellcheck disable=SC1091
source commands/logs/main.sh

line='9.9.9.9 - - [16/Nov/2026:10:04:00 +0000] "GET /x HTTP/1.1" 503 1'
out="$(printf '%s\n' "${line}" | hm_logs_search_awk "x.test" "" "" "5xx" "0" "0")"
printf '%s\n' "${out}" | grep -q '503' && ok logs-5xx-unit || bad "logs-5xx-unit got='${out}'"

out2="$(printf '%s\n' "${line}" | hm_logs_search_awk "x.test" "" "" "5xx" "20261116100000" "0")"
printf '%s\n' "${out2}" | grep -q '503' && ok logs-since-unit || bad "logs-since-unit got='${out2}'"

if printf '503\n' | awk '/^5[0-9][0-9]$/{print "ok"}' | grep -q ok; then
  ok awk-digit-repeat
else
  bad awk-digit-repeat
fi

exit "${fail}"
