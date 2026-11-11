#!/usr/bin/env bash
# dns expiry, drift, dnssec — fixture .pl/.com/.eu, cache i dedup.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1
export HM_DNS_TODAY=2026-11-11

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_run() { "$@"; }
hm_file_log() { :; }
hm_help_topic() { :; }
hm_notify() { printf 'notify %s\n' "$3" >> "${root}/notify"; }
hm_mail_check_cmd() { printf 'called %s\n' "$1" >> "${root}/mail"; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/rdap" "${root}/cache" "${root}/base" "${root}/pub" "${root}/dnssec"
export HM_DNS_RDAP_DIR="${root}/rdap"
export HM_DNS_EXPIRY_CACHE="${root}/cache"
export HM_DNS_RDAP_HITS="${root}/hits"
export HM_DNS_DEDUP="${root}/dedup"
export HM_DNS_DOMAINS="${root}/domains"
export HM_DNS_BASELINE="${root}/base"
export HM_DNS_PUBLIC="${root}/pub"
export HM_DNS_DNSSEC="${root}/dnssec"
: > "${HM_DNS_RDAP_HITS}"
printf '%s\n' example.pl example.com example.eu > "${HM_DNS_DOMAINS}"
printf 'renewal date: 2026.11.20 12:00:00\n' > "${root}/rdap/example.pl"
printf '"eventAction":"expiration","eventDate":"2026-12-01T00:00:00Z"\n' > "${root}/rdap/example.com"
printf 'Expiry Date: 2026-11-15\n' > "${root}/rdap/example.eu"
printf '%s\n' 'A example.pl 203.0.113.10' 'MX example.pl 10 mail.example.pl' > "${root}/base/example.pl"
printf '%s\n' 'A example.pl 203.0.113.11' 'MX example.pl 10 mail.example.pl' > "${root}/pub/example.pl"
printf '%s\n' 'DS yes' 'DNSKEY no' 'valid no' > "${root}/dnssec/example.pl"
printf '%s\n' 'DS yes' 'DNSKEY yes' 'valid yes' > "${root}/dnssec/example.com"

# shellcheck disable=SC1091
source commands/dns/main.sh
# shellcheck disable=SC1091
source commands/report/main.sh

out="$(cmd_dns expiry --all 2>"${root}/exp.err")"
printf '%s\n' "${out}" | grep -q $'example.pl\t9' && ok pl || bad pl
printf '%s\n' "${out}" | grep -q $'example.com\t20' && ok com || bad com
printf '%s\n' "${out}" | grep -q $'example.eu\t4' && ok eu || bad eu
[[ "$(grep -c . "${HM_DNS_RDAP_HITS}")" -eq 3 ]] && ok hits-first || bad hits-first
cmd_dns expiry --all >/dev/null 2>&1
[[ "$(grep -c . "${HM_DNS_RDAP_HITS}")" -eq 3 ]] && ok cache || bad cache
[[ "$(grep -c notify "${root}/notify")" -eq 3 ]] && ok dedup-first || bad dedup-first
cmd_dns expiry --all >/dev/null 2>&1
[[ "$(grep -c notify "${root}/notify")" -eq 3 ]] && ok dedup-second || bad dedup-second
touch -d '2020-01-01' "${root}/cache/example.pl"
cmd_dns expiry example.pl >/dev/null 2>&1
[[ "$(grep -c '^example.pl$' "${HM_DNS_RDAP_HITS}")" -eq 2 ]] && ok cache-stale || bad cache-stale

drift="$(cmd_dns drift example.pl)"
printf '%s\n' "${drift}" | grep -q $'oczekiwane\tA example.pl 203.0.113.10' && ok drift-exp || bad drift-exp
printf '%s\n' "${drift}" | grep -q $'publiczne\tA example.pl 203.0.113.11' && ok drift-pub || bad drift-pub
printf '%s\n' "${drift}" | grep -q 'mail.example.pl' && bad drift-same || ok drift-same
cmd_dns drift baseline example.pl >/dev/null
same="$(cmd_dns drift example.pl)"
printf '%s\n' "${same}" | grep -q $'brak dryfu\texample.pl' && ok drift-base || bad drift-base

if cmd_dns dnssec example.pl >/dev/null 2>"${root}/sec.err"; then bad dnssec-bad; else ok dnssec-bad; fi
grep -q 'rozjechany' "${root}/sec.err" && ok dnssec-msg || bad dnssec-msg
cmd_dns dnssec example.com >/dev/null && ok dnssec-ok || bad dnssec-ok

alerts="$(hm_health_dns_alerts)"
printf '%s\n' "${alerts}" | grep -q 'dns:expiry:example.eu:4' && ok health || bad health
grep -q 'hm_health_dns_alerts' commands/health/main.sh && ok health-wired || bad health-wired

text="$(cmd_report weekly 2>/dev/null || true)"
printf '%s\n' "${text}" | grep -q '## Domeny' && ok report || bad report
printf '%s\n' "${text}" | grep -q 'mail diag: example.pl' && ok mail-diag || bad mail-diag
[[ "$(grep -c called "${root}/mail")" -eq 3 ]] && ok mail-called || bad mail-called

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
