#!/usr/bin/env bash
# Regresja: mail accounts/forward — exact domain, SQL quote, delete --from scope, redaction
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() {
  case "$1" in
    cyberpanel|postqueue|postfix|systemctl|doveadm) return 0 ;;
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
hm_gen_password() { printf 'GenPass12!xYzAb'; }
hm_human_size() { echo "${1}B"; }
hm_ui_tty_fd() { return 1; }
# zbieraj sekrety do pliku (nie na stdout / applog) — działa też przy $(…)
hm_print_secret() {
  local line
  [[ -n "${SECRET_FILE:-}" ]] || return 0
  for line in "$@"; do
    printf '%s\n' "${line}" >> "${SECRET_FILE}"
  done
}
hm_sql_quote() {
  local s="${1:-}"
  s="${s//\'/\'\'}"
  printf "'%s'" "${s}"
}
hm_run() {
  # zapisz argv (z hasłem) do pliku testowego redaction osobno
  printf '%s\n' "$*" >> "${RUN_LOG}"
  return 0
}
hm_run_cmd_redacted() {
  # skopiuj logikę redakcji
  local -a out=() redact_next=0 a
  for a in "$@"; do
    if [[ "${redact_next}" -eq 1 ]]; then out+=("***"); redact_next=0; continue; fi
    if [[ "${a}" =~ ^--(password|pass|passwd)= ]]; then out+=("${a%%=*}=***"); continue; fi
    if [[ "${a}" =~ ^--(password|pass|passwd)$ || "${a}" == "-p" ]]; then out+=("${a}"); redact_next=1; continue; fi
    out+=("${a}")
  done
  printf '%s' "${out[*]}"
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

# fake cyberpanel DB via hm_mysql_exec
declare -A FAKE_USERS=()
declare -A FAKE_FWD=()
declare -A FAKE_CATCH=()

hm_mysql_exec() {
  # hm_mysql_exec cyberpanel -N -e "SQL"  OR cyberpanel -e "SQL"
  local db="" sql="" a
  for a in "$@"; do
    case "${a}" in
      cyberpanel) db=cyberpanel ;;
      -N|-e) ;;
      *)
        if [[ "${a}" == SELECT* || "${a}" == INSERT* || "${a}" == DELETE* || "${a}" == *"information_schema"* ]]; then
          sql="${a}"
        elif [[ -z "${sql}" && "${a}" != -* ]]; then
          [[ "${a}" != cyberpanel ]] && sql="${a}"
        fi
        ;;
    esac
  done
  # last -e arg
  local i=0
  for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-e" ]]; then
      local j=$((i+1))
      sql="${!j}"
    fi
  done
  local sql1
  sql1="$(printf '%s' "${sql}" | tr '\n' ' ' | tr -s ' ')"
  printf '%s\n' "${sql1}" >> "${SQL_LOG}"

  if [[ "${sql1}" == *information_schema.tables* && "${sql1}" == *e_users* ]]; then
    echo 1; return 0
  fi
  if [[ "${sql1}" == *information_schema.tables* && "${sql1}" == *e_forwardings* ]]; then
    echo 1; return 0
  fi
  if [[ "${sql1}" == *information_schema.tables* && "${sql1}" == *e_catchall* ]]; then
    echo 1; return 0
  fi
  if [[ "${sql1}" == *"SELECT COUNT(*) FROM e_users"* ]]; then
    local em
    em="$(printf '%s' "${sql1}" | sed -n "s/.*email='\\([^']*\\)'.*/\\1/p")"
    if [[ -n "${FAKE_USERS[${em}]:-}" ]]; then echo 1; else echo 0; fi
    return 0
  fi
  if [[ "${sql1}" == *"FROM e_users"* && "${sql1}" == *"SUBSTRING_INDEX"* ]]; then
    local want
    want="$(printf '%s' "${sql1}" | sed -n "s/.*= '\\([^']*\\)'.*/\\1/p" | tail -1)"
    local k
    for k in "${!FAKE_USERS[@]}"; do
      [[ "${k#*@}" == "${want}" ]] && printf '%s\t0\t%s/%s\n' "${k}" "${k#*@}" "${k%%@*}"
    done
    return 0
  fi
  if [[ "${sql1}" == *"SELECT email"* && "${sql1}" == *"FROM e_users"* ]]; then
    local k
    for k in "${!FAKE_USERS[@]}"; do
      printf '%s\t0\t\n' "${k}"
    done
    return 0
  fi
  if [[ "${sql1}" == *"SELECT DISTINCT"* ]]; then
    local k seen="|"
    for k in "${!FAKE_USERS[@]}"; do
      local d="${k#*@}"
      [[ "${seen}" == *"|${d}|"* ]] && continue
      seen+="${d}|"
      echo "${d}"
    done
    return 0
  fi
  if [[ "${sql1}" == *"SELECT source, destination FROM e_forwardings"* ]]; then
    local k
    for k in "${!FAKE_FWD[@]}"; do
      printf '%s\t%s\n' "${k%%→*}" "${k#*→}"
    done
    return 0
  fi
  if [[ "${sql1}" == *"SELECT COUNT(*) FROM e_forwardings"* ]]; then
    local s d key
    s="$(printf '%s' "${sql1}" | sed -n "s/.*source='\\([^']*\\)'.*/\\1/p")"
    d="$(printf '%s' "${sql1}" | sed -n "s/.*destination='\\([^']*\\)'.*/\\1/p")"
    key="${s}→${d}"
    if [[ -n "${FAKE_FWD[${key}]:-}" ]]; then echo 1; else echo 0; fi
    return 0
  fi
  if [[ "${sql1}" == *"INSERT INTO e_forwardings"* ]]; then
    local s d
    s="$(printf '%s' "${sql1}" | sed -n "s/.*VALUES ('\\([^']*\\)', '\\([^']*\\)').*/\\1/p")"
    d="$(printf '%s' "${sql1}" | sed -n "s/.*VALUES ('\\([^']*\\)', '\\([^']*\\)').*/\\2/p")"
    FAKE_FWD["${s}→${d}"]=1
    return 0
  fi
  if [[ "${sql1}" == *"DELETE FROM e_forwardings"* ]]; then
    local s d key
    s="$(printf '%s' "${sql1}" | sed -n "s/.*source='\\([^']*\\)'.*/\\1/p")"
    d="$(printf '%s' "${sql1}" | sed -n "s/.*destination='\\([^']*\\)'.*/\\1/p")"
    key="${s}→${d}"
    unset 'FAKE_FWD['"${key}"']'
    return 0
  fi
  if [[ "${sql1}" == *"SELECT ForwardTo"* ]]; then
    local dom
    dom="$(printf '%s' "${sql1}" | sed -n "s/.*domain='\\([^']*\\)'.*/\\1/p")"
    [[ -z "${dom}" ]] && dom="$(printf '%s' "${sql1}" | sed -n "s/.*domainName='\\([^']*\\)'.*/\\1/p")"
    printf '%s\n' "${FAKE_CATCH[${dom}]:-}"
    return 0
  fi
  if [[ "${sql1}" == *"INSERT INTO e_catchall"* ]]; then
    local dom dest
    dom="$(printf '%s' "${sql1}" | sed -n "s/.*VALUES ('\\([^']*\\)', '\\([^']*\\)').*/\\1/p")"
    dest="$(printf '%s' "${sql1}" | sed -n "s/.*VALUES ('\\([^']*\\)', '\\([^']*\\)').*/\\2/p")"
    FAKE_CATCH["${dom}"]="${dest}"
    return 0
  fi
  if [[ "${sql1}" == *"DELETE FROM e_catchall"* ]]; then
    local dom
    dom="$(printf '%s' "${sql1}" | sed -n "s/.*domain='\\([^']*\\)'.*/\\1/p")"
    unset 'FAKE_CATCH['"${dom}"']'
    return 0
  fi
  if [[ "${sql1}" == *"SELECT mail FROM e_users"* ]]; then
    echo ""
    return 0
  fi
  return 0
}

# shellcheck disable=SC1091
source commands/mail/accounts.sh
# shellcheck disable=SC1091
source commands/mail/forward.sh

# seed
FAKE_USERS["biuro@example.pl"]=1
FAKE_USERS["info@example.pl"]=1
FAKE_USERS["biuro@other.pl"]=1

# --- exact domain normalize ---
if out="$(hm_mail_normalize_local biuro example.pl)" && [[ "${out}" == "biuro" ]]; then
  echo "OK   normalize-local"
else
  echo "FAIL normalize-local"
  fail=1
fi
if hm_mail_normalize_local "biuro@evil-example.pl" example.pl 2>/dev/null; then
  echo "FAIL normalize-reject-other-domain"
  fail=1
else
  echo "OK   normalize-reject-other-domain"
fi

# --- list only example.pl ---
HM_SITE_DOMAIN="example.pl"
list="$(hm_mail_list_domain_emails example.pl)"
if printf '%s\n' "${list}" | grep -q 'biuro@example.pl' \
  && printf '%s\n' "${list}" | grep -q 'info@example.pl' \
  && ! printf '%s\n' "${list}" | grep -q 'other.pl'; then
  echo "OK   list-domain-exact"
else
  echo "FAIL list-domain-exact"
  printf '%s\n' "${list}"
  fail=1
fi

# --- source_in_domain ---
if hm_mail_source_in_domain "biuro@example.pl" example.pl \
  && hm_mail_source_in_domain "@example.pl" example.pl \
  && ! hm_mail_source_in_domain "biuro@evil-example.pl" example.pl \
  && ! hm_mail_source_in_domain "x@sub.example.pl" example.pl; then
  echo "OK   source-in-domain"
else
  echo "FAIL source-in-domain"
  fail=1
fi

# --- forward add/remove only pair ---
HM_SITE_DOMAIN="example.pl"
hm_mail_forward_add biuro@example.pl jan@gmail.com --yes >/dev/null
hm_mail_forward_add biuro@example.pl other@gmail.com --yes >/dev/null
if [[ -n "${FAKE_FWD[biuro@example.pl→jan@gmail.com]:-}" && -n "${FAKE_FWD[biuro@example.pl→other@gmail.com]:-}" ]]; then
  echo "OK   forward-add"
else
  echo "FAIL forward-add"
  fail=1
fi
hm_mail_forward_remove biuro@example.pl jan@gmail.com --yes >/dev/null
if [[ -z "${FAKE_FWD[biuro@example.pl→jan@gmail.com]:-}" && -n "${FAKE_FWD[biuro@example.pl→other@gmail.com]:-}" ]]; then
  echo "OK   forward-remove-one-pair"
else
  echo "FAIL forward-remove-one-pair"
  fail=1
fi

# cross-domain forward rejected
if hm_mail_forward_add "x@other.pl" "y@gmail.com" --yes 2>/dev/null; then
  echo "FAIL forward-cross-domain"
  fail=1
else
  echo "OK   forward-cross-domain"
fi

# --- password redaction ---
red="$(hm_run_cmd_redacted cyberpanel createEmail --domainName example.pl --userName biuro --password 'SecretPass99')"
if [[ "${red}" == *'--password ***'* || "${red}" == *'--password=***'* ]] && [[ "${red}" != *SecretPass99* ]]; then
  echo "OK   password-redacted"
else
  echo "FAIL password-redacted (${red})"
  fail=1
fi

# --- bez CyberCP python: odmowa (NIGDY createEmail --password w argv) ---
: > "${RUN_LOG}"
unset HM_CYBERCP_PYTHON || true
FAKE_USERS=()
HM_SITE_DOMAIN="example.pl"
if hm_mail_account_add biuro --yes >/dev/null 2>&1; then
  echo "FAIL add-without-python-should-fail"
  fail=1
elif grep -qE -- '--password|createEmail' "${RUN_LOG}"; then
  echo "FAIL add-without-python-leaked-cli"
  cat "${RUN_LOG}"
  fail=1
else
  echo "OK   add-without-python-refuse"
fi

# --- z CyberCP python: hm_run woła pythona + passfile; hasło nie w argv / stdout ---
mkdir -p "${tmpdir}/CyberCP/bin"
cat > "${tmpdir}/CyberCP/bin/python" <<'EOF'
#!/bin/sh
# mock: argv = domain user passfile  OR  email passfile
echo "PY $*" >> "${RUN_LOG}"
exit 0
EOF
chmod +x "${tmpdir}/CyberCP/bin/python"
# hm_run w teście tylko loguje — podłączamy ścieżkę przez HM_CYBERCP_PYTHON
export HM_CYBERCP_PYTHON="${tmpdir}/CyberCP/bin/python"
: > "${RUN_LOG}"
SECRET_FILE="${tmpdir}/secret.out"
: > "${SECRET_FILE}"
FAKE_USERS=()
HM_SITE_DOMAIN="example.pl"
add_out="$(hm_mail_account_add biuro --yes 2>&1)"
if grep -q "${HM_CYBERCP_PYTHON}" "${RUN_LOG}" && ! grep -qE -- '--password' "${RUN_LOG}" \
  && ! grep -q 'GenPass12' "${RUN_LOG}"; then
  echo "OK   add-cybercp-python-no-argv"
else
  echo "FAIL add-cybercp-python-no-argv"
  cat "${RUN_LOG}"
  fail=1
fi
if printf '%s\n' "${add_out}" | grep -q 'GenPass12'; then
  echo "FAIL add-password-on-stdout"
  fail=1
elif grep -q 'GenPass12' "${SECRET_FILE}"; then
  echo "OK   add-password-via-print-secret"
else
  echo "FAIL add-password-via-print-secret"
  printf 'out=%s\n' "${add_out}"
  cat "${SECRET_FILE}" || true
  fail=1
fi
unset HM_CYBERCP_PYTHON

# --- catchall ---
hm_mail_catchall_set example.pl biuro@example.pl --yes >/dev/null
if [[ "${FAKE_CATCH[example.pl]:-}" == "biuro@example.pl" ]]; then
  echo "OK   catchall-set"
else
  echo "FAIL catchall-set"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED=${fail}"
  exit 1
fi
echo "ALL OK"
exit 0
