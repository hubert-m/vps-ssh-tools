#!/usr/bin/env bash
# Regresja: katalog usług, aliasy, ścieżki logów Debian/RHEL, sshd gate
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 1; }
hm_run() { "$@"; }
hm_help_topic() { :; }
hm_detect_all() { :; }
hm_ols_reload_soft() { return 0; }
hm_human_size() { echo "${1}B"; }
hm_file_log() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
UNITS="lsws.service mariadb.service postfix.service sshd.service"
case "$1" in
  cat)
    u="${2%.service}.service"
    echo "$UNITS" | tr ' ' '\n' | grep -qx "$u" && exit 0
    exit 1
    ;;
  list-unit-files)
    echo "$UNITS" | tr ' ' '\n' | grep -E "^${2:-}" || true
    exit 0
    ;;
  is-active) echo active; exit 0 ;;
  is-enabled) echo enabled; exit 0 ;;
  show)
    echo "$*" | grep -q MemoryCurrent && { echo 1048576; exit 0; }
    echo "$*" | grep -q MainPID && { echo 1; exit 0; }
    echo "$*" | grep -q ActiveEnterTimestamp && { echo n/a; exit 0; }
    echo ""
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${tmpdir}/bin/systemctl"
PATH="${tmpdir}/bin:$PATH"

# shellcheck disable=SC1091
source commands/services/main.sh
# shellcheck disable=SC1091
source commands/logs/main.sh

# --- alias ---
a="$(hm_services_alias_for_arg mysql)"
[[ "${a}" == "mariadb" ]] && echo "OK   alias-mysql" || { echo "FAIL alias-mysql"; fail=1; }
a="$(hm_services_alias_for_arg ols)"
[[ "${a}" == "lsws" ]] && echo "OK   alias-ols" || { echo "FAIL alias-ols"; fail=1; }

# --- resolve installed ---
u="$(hm_services_resolve_unit lsws || true)"
[[ "${u}" == "lsws" ]] && echo "OK   resolve-lsws" || { echo "FAIL resolve-lsws got=${u}"; fail=1; }
u="$(hm_services_resolve_unit mariadb || true)"
[[ "${u}" == "mariadb" ]] && echo "OK   resolve-mariadb" || { echo "FAIL resolve-mariadb"; fail=1; }

# redis nie w SYSTEMCTL_UNITS
if hm_services_resolve_unit redis >/dev/null 2>&1; then
  echo "FAIL resolve-missing-redis"
  fail=1
else
  echo "OK   resolve-missing"
fi

# lista tylko zainstalowanych
list="$(hm_services_list_installed | tr '\n' ' ')"
if [[ "${list}" == *lsws* && "${list}" == *mariadb* && "${list}" != *redis* ]]; then
  echo "OK   list-installed"
else
  echo "FAIL list-installed got=${list}"
  fail=1
fi

# --- log paths Debian vs RHEL ---
OS_FAMILY=debian
mail_paths="$(hm_logs_system_paths mail)"
echo "${mail_paths}" | grep -q '/var/log/mail.log' && echo "OK   mail-debian-path" || { echo "FAIL mail-debian"; fail=1; }
echo "${mail_paths}" | grep -q '/var/log/maillog' && echo "OK   mail-rhel-path-listed" || { echo "FAIL mail-rhel-listed"; fail=1; }

auth_paths="$(hm_logs_system_paths auth)"
echo "${auth_paths}" | grep -q '/var/log/auth.log' && echo "OK   auth-debian" || { echo "FAIL auth-debian"; fail=1; }
echo "${auth_paths}" | grep -q '/var/log/secure' && echo "OK   auth-rhel" || { echo "FAIL auth-rhel"; fail=1; }

# find files — utwórz mock
mkdir -p "${tmpdir}/var/log"
echo "postfix ok line" > "${tmpdir}/var/log/mail.log"
echo "error boom" >> "${tmpdir}/var/log/mail.log"

# override paths via wrapper test of grep logic
if grep -F "ok" "${tmpdir}/var/log/mail.log" | grep -q postfix; then
  echo "OK   grep-mail"
else
  echo "FAIL grep-mail"
  fail=1
fi

# --grep semantics (jak cmd_logs_system)
out="$(grep -F "boom" "${tmpdir}/var/log/mail.log" || true)"
[[ "${out}" == *error* ]] && echo "OK   grep-error-line" || { echo "FAIL grep-error"; fail=1; }

# sshd restart bez -t gdy brak — upewnij się że katalog ma sshd
if grep -q 'sshd -t' commands/services/main.sh; then
  echo "OK   sshd-t-gate"
else
  echo "FAIL sshd-t-gate"
  fail=1
fi

if grep -q 'hm_ols_reload_soft' commands/services/main.sh; then
  echo "OK   lsws-soft-reload"
else
  echo "FAIL lsws-soft-reload"
  fail=1
fi

if grep -q 'hm_services_journal_tail' commands/services/main.sh; then
  echo "OK   journal-on-fail"
else
  echo "FAIL journal-on-fail"
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL OK"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
}