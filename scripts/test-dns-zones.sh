#!/usr/bin/env bash
# Regresja: dns zones/check — exact domain, SQL quote, NS/SOA --force, dig mock
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    cyberpanel|dig|systemctl|hostname|ip) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_confirm_plan_critical() { return 0; }
hm_run_timeout() { shift; "$@"; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_detect_all() { PANEL=cyberpanel; }
hm_sql_quote() {
  local s="${1:-}"
  s="${s//\'/\'\'}"
  printf "'%s'" "${s}"
}
hm_run() {
  printf '%s\n' "$*" >> "${RUN_LOG}"
  return 0
}
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
RUN_LOG="${tmpdir}/run.log"
SQL_LOG="${tmpdir}/sql.log"
: > "${RUN_LOG}"
: > "${SQL_LOG}"

# Fake PowerDNS tables
ZONE_ID=7
DOMAIN="example.pl"
declare -A REC_NAME=([10]="example.pl" [11]="www.example.pl" [12]="example.pl" [13]="example.pl" [14]="ns1.example.pl")
declare -A REC_TYPE=([10]="A" [11]="A" [12]="MX" [13]="SOA" [14]="NS")
declare -A REC_CONTENT=([10]="203.0.113.10" [11]="203.0.113.10" [12]="mail.example.pl" [13]="ns1.example.pl hostmaster 2026010101 3600 600 1209600 3600" [14]="ns1.example.pl")
declare -A REC_TTL=([10]="3600" [11]="3600" [12]="3600" [13]="3600" [14]="3600")
declare -A REC_PRIO=([10]="0" [11]="0" [12]="10" [13]="0" [14]="0")
declare -A REC_DOM=([10]="$ZONE_ID" [11]="$ZONE_ID" [12]="$ZONE_ID" [13]="$ZONE_ID" [14]="$ZONE_ID")
NEXT_ID=20

hm_mysql_exec() {
  local sql="" i
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-e" ]]; then
      local j=$((i+1))
      sql="${!j}"
    fi
  done
  local sql1
  sql1="$(printf '%s' "${sql}" | tr '\n' ' ' | tr -s ' ')"
  printf '%s\n' "${sql1}" >> "${SQL_LOG}"

  if [[ "${sql1}" == *information_schema.tables* && "${sql1}" == *domains* ]]; then
    echo 1; return 0
  fi
  if [[ "${sql1}" == *information_schema.tables* && "${sql1}" == *records* ]]; then
    echo 1; return 0
  fi
  if [[ "${sql1}" == *"SELECT id FROM domains WHERE name="* ]]; then
    if [[ "${sql1}" == *"'example.pl'"* ]]; then
      echo "${ZONE_ID}"; return 0
    fi
    return 0
  fi
  if [[ "${sql1}" == *"SELECT id, name, type FROM domains"* ]]; then
    printf '%s\t%s\t%s\n' "${ZONE_ID}" "example.pl" "NATIVE"
    return 0
  fi
  if [[ "${sql1}" == *"FROM records WHERE id="* ]]; then
    local rid
    rid="$(printf '%s' "${sql1}" | sed -n "s/.*WHERE id='\([0-9]*\)'.*/\1/p")"
    [[ -n "${rid}" ]] || rid="$(printf '%s' "${sql1}" | sed -n 's/.*WHERE id=\([0-9]*\).*/\1/p')"
    if [[ -n "${rid}" && -n "${REC_TYPE[${rid}]:-}" && "${REC_DOM[${rid}]}" == "${ZONE_ID}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${rid}" "${REC_NAME[${rid}]}" "${REC_TYPE[${rid}]}" \
        "${REC_CONTENT[${rid}]}" "${REC_TTL[${rid}]}" "${REC_PRIO[${rid}]}"
    fi
    return 0
  fi
  if [[ "${sql1}" == *"FROM records WHERE domain_id="* ]]; then
    local id
    for id in 10 11 12 13 14; do
      [[ -n "${REC_TYPE[${id}]:-}" ]] || continue
      if [[ "${sql1}" == *" AND type="* ]]; then
        local want
        want="$(printf '%s' "${sql1}" | sed -n "s/.*type='\([A-Z]*\)'.*/\1/p")"
        [[ "${REC_TYPE[${id}]}" == "${want}" ]] || continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${id}" "${REC_TYPE[${id}]}" "${REC_NAME[${id}]}" \
        "${REC_TTL[${id}]}" "${REC_PRIO[${id}]}" "${REC_CONTENT[${id}]}"
    done
    return 0
  fi
  return 0
}

# dig mock — A points to VPS or foreign
DIG_MODE="${DIG_MODE:-match}"
dig() {
  # dig +short [ @server ] TYPE name   OR dig +short TYPE name
  local typ="" name="" a
  for a in "$@"; do
    case "${a}" in
      +short|@*|+*) ;;
      A|AAAA|MX|TXT|NS|CAA|SOA) typ="${a}" ;;
      *)
        if [[ -z "${typ}" ]]; then typ="A"; fi
        name="${a}"
        ;;
    esac
  done
  case "${typ}" in
    A)
      if [[ "${DIG_MODE}" == "match" ]]; then
        echo "203.0.113.10"
      else
        echo "198.51.100.1"
      fi
      ;;
    AAAA) ;;
    NS) echo "ns1.example.pl." ;;
    MX) echo "10 mail.example.pl." ;;
    TXT)
      if [[ "${name}" == _dmarc.* ]]; then
        echo '"v=DMARC1; p=none"'
      elif [[ "${name}" == default._domainkey.* ]]; then
        echo '"v=DKIM1; k=rsa; p=ABC"'
      else
        echo '"v=spf1 a mx -all"'
      fi
      ;;
    CAA) echo '0 issue "letsencrypt.org"' ;;
  esac
  return 0
}
hostname() {
  if [[ "${1:-}" == "-I" ]]; then
    echo "203.0.113.10"
    return 0
  fi
  command hostname "$@" 2>/dev/null || echo "testhost"
}
ip() { return 1; }
systemctl() {
  if [[ "${1:-}" == "is-active" ]]; then return 0; fi
  return 1
}

# shellcheck source=commands/dns/check.sh
source commands/dns/check.sh
# shellcheck source=commands/dns/main.sh
source commands/dns/main.sh

assert_contains() {
  local hay="$1" needle="$2" label="$3"
  if [[ "${hay}" != *"${needle}"* ]]; then
    echo "FAIL ${label}: expected contains '${needle}'"
    echo "GOT: ${hay}"
    fail=1
  else
    echo "PASS ${label}"
  fi
}
assert_run_contains() {
  local needle="$1" label="$2"
  if ! grep -qF -- "${needle}" "${RUN_LOG}"; then
    echo "FAIL ${label}: run log missing '${needle}'"
    cat "${RUN_LOG}"
    fail=1
  else
    echo "PASS ${label}"
  fi
}
assert_sql_quoted() {
  if grep -E "name=example\.pl[^']|name=\$|name=\"\"" "${SQL_LOG}" >/dev/null 2>&1; then
    echo "FAIL SQL injection risk / unquoted domain"
    fail=1
  else
    echo "PASS SQL uses quotes (no bare domain)"
  fi
  if ! grep -q "name='example.pl'" "${SQL_LOG}"; then
    echo "FAIL expected hm_sql_quote around example.pl"
    cat "${SQL_LOG}"
    fail=1
  else
    echo "PASS domain exact-quoted"
  fi
}

# --- zones overview ---
out="$(hm_dns_zones_overview 2>&1 || true)"
assert_contains "${out}" "example.pl" "zones list shows domain"

# --- list ---
HM_SITE_DOMAIN="example.pl"
out="$(hm_dns_list_records example.pl 2>&1)"
assert_contains "${out}" "203.0.113.10" "list A content"
assert_contains "${out}" "SOA" "list SOA"

out="$(hm_dns_list_records example.pl --type MX 2>&1)"
assert_contains "${out}" "mail.example.pl" "list --type MX"
if [[ "${out}" == *$'\tA\t'* ]] || [[ "${out}" == *" A "* && "${out}" == *"203.0.113"* && "${out}" != *"MX"* ]]; then
  : # soft
fi
if [[ "${out}" == *"SOA"* ]]; then
  echo "FAIL list --type MX leaked SOA"
  fail=1
else
  echo "PASS list --type MX filtered"
fi

# --- wrong domain exact match ---
if hm_dns_list_records "example.pl.evil" 2>/dev/null; then
  echo "FAIL substring domain should fail"
  fail=1
else
  echo "PASS exact domain match (evil rejected)"
fi

# --- add ---
: > "${RUN_LOG}"
HM_SITE_DOMAIN="example.pl"
hm_dns_add_record A www 203.0.113.99 --ttl 600 --yes
assert_run_contains "createDNSRecord" "add calls createDNSRecord"
assert_run_contains "--recordType A" "add type A"
assert_run_contains "www.example.pl" "add FQDN name"

# TXT with spaces
: > "${RUN_LOG}"
hm_dns_add_record TXT _dmarc 'v=DMARC1; p=quarantine' --yes
assert_run_contains "v=DMARC1; p=quarantine" "add TXT keeps spaces"

# bad A
if hm_dns_add_record A www not-an-ip --yes 2>/dev/null; then
  echo "FAIL bad A accepted"
  fail=1
else
  echo "PASS reject invalid A"
fi

# --- delete NS without --force ---
: > "${RUN_LOG}"
if hm_dns_delete_record 14 --yes 2>/dev/null; then
  echo "FAIL NS delete without --force"
  fail=1
else
  echo "PASS NS blocked without --force"
fi
if grep -q deleteDNSRecord "${RUN_LOG}"; then
  echo "FAIL NS delete should not call CLI without --force"
  fail=1
else
  echo "PASS no CLI on blocked NS delete"
fi

# --- delete NS with --force ---
: > "${RUN_LOG}"
hm_dns_delete_record 14 --force --yes
assert_run_contains "deleteDNSRecord --recordID 14" "NS delete with --force"

# --- delete A ---
: > "${RUN_LOG}"
hm_dns_delete_record 11 --yes
assert_run_contains "deleteDNSRecord --recordID 11" "delete A"

# --- edit = delete+create ---
: > "${RUN_LOG}"
hm_dns_edit_record 10 --value 203.0.113.50 --yes
assert_run_contains "deleteDNSRecord --recordID 10" "edit deletes old"
assert_run_contains "createDNSRecord" "edit creates new"
assert_run_contains "203.0.113.50" "edit new value"

# --- export ---
out="$(hm_dns_export_zone example.pl 2>&1)"
assert_contains "${out}" "IN" "export BIND"
assert_contains "${out}" "\$ORIGIN" "export ORIGIN"

# --- TXT split ---
chunks="$(hm_dns_split_txt "$(printf 'a%.0s' {1..300})" | wc -l | tr -d ' ')"
if [[ "${chunks}" -ge 2 ]]; then
  echo "PASS TXT split >255"
else
  echo "FAIL TXT split expected ≥2 chunks, got ${chunks}"
  fail=1
fi

# --- dns check match ---
DIG_MODE=match
out="$(hm_dns_check_cmd example.pl 2>&1)"
assert_contains "${out}" "OK" "check OK when A=VPS"
assert_contains "${out}" "SPF" "check SPF line"
assert_contains "${out}" "DKIM" "check DKIM"
assert_contains "${out}" "DMARC" "check DMARC"

# --- dns check mismatch ---
DIG_MODE=mismatch
out="$(hm_dns_check_cmd example.pl 2>&1)"
assert_contains "${out}" "ERR" "check ERR when A≠VPS"

# --- SQL quoting ---
assert_sql_quoted

# --- foreign zone id isolation: record from other domain ---
REC_NAME[99]="other.pl"
REC_TYPE[99]="A"
REC_CONTENT[99]="1.2.3.4"
REC_TTL[99]="3600"
REC_PRIO[99]="0"
REC_DOM[99]="999"
row="$(hm_dns_record_row example.pl 99 || true)"
if [[ -n "${row}" ]]; then
  echo "FAIL cross-zone record leaked"
  fail=1
else
  echo "PASS cross-zone id isolation"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
