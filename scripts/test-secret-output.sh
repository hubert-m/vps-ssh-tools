#!/usr/bin/env bash
# Regresja: hasło access ssh/ftp i wp nie trafia na stdout/applog (hm_print_secret + redakcja Hasło:).
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
# shellcheck disable=SC1091
source lib/logging.sh
hm_file_log_ui() { :; }

fail=0
PASS='GenPass12xYzAb99'
assert_no_secret() {
  local name="$1" blob="$2"
  if printf '%s' "${blob}" | grep -F -q "${PASS}"; then
    echo "FAIL ${name} (hasło w wyjściu)"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# --- redakcja linii Hasło: w applog ---
logdir="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-seclog.XXXXXX")"
trap 'rm -rf "${logdir}"' EXIT
LOG_DIR="${logdir}"
LOG_ENABLED=1
printf '%s\n' "  Hasło: ${PASS}" "zwykła linia" | hm_log_stream_to_file OUT INFO
logf="$(hm_log_file_path)"
if grep -F -q "${PASS}" "${logf}"; then
  echo "FAIL log-redact-haslo (jawne hasło)"
  fail=1
elif grep -q 'Hasło: \*\*\*' "${logf}" && grep -q 'zwykła linia' "${logf}"; then
  echo "OK   log-redact-haslo"
else
  echo "FAIL log-redact-haslo (brak redakcji lub zgubiona linia)"
  cat "${logf}" || true
  fail=1
fi

hm_confirm_plan() { return 0; }
hm_gen_password() { printf '%s' "${PASS}"; }
hm_have_cmd() { [[ "${1:-}" == "cyberpanel" ]] && return 0; return 1; }
hm_is_valid_domain() { [[ "${1:-}" == *.* ]]; }
hm_run() { return 0; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
C_BOLD="" C_RESET="" C_DIM=""

# shellcheck disable=SC1091
source commands/access/ssh.sh
# shellcheck disable=SC1091
source commands/access/ftp.sh

hm_access_resolve_site() {
  HM_SITE_DOMAIN="example.pl"
  HM_SITE_USER="$(id -un)"
  HM_SITE_ROOT="${logdir}"
  return 0
}
hm_access_require_site_user() { printf '%s\n' "$(id -un)"; }
chpasswd() { return 0; }
hm_access_cp_ftp_exists() { return 1; }
hm_access_cp_ftp_create() { return 0; }
hm_access_cp_ftp_actual_user() { printf '%s\n' "${2:-$1}"; }
hm_access_cp_ftp_belongs_to_domain() { return 0; }
hm_access_cp_ftp_set_password() { return 0; }
mkdir -p "${logdir}"

out="$(hm_access_ssh_passwd example.pl 2>&1 || true)"
assert_no_secret "ssh-passwd-stdout" "${out}"

out="$(hm_access_ftp_add ftpuser / 2>&1 || true)"
assert_no_secret "ftp-add-stdout" "${out}"

out="$(hm_access_ftp_passwd ftpuser 2>&1 || true)"
assert_no_secret "ftp-passwd-stdout" "${out}"

_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
# shellcheck disable=SC1091
source commands/wp/main.sh
hm_wp_require_site() { HM_SITE_DOMAIN="example.pl"; return 0; }
hm_wp_run() { return 0; }
hm_confirm_plan() { return 0; }
hm_gen_password() { printf '%s' "${PASS}"; }
hm_run() { return 0; }

out="$(hm_wp_admin_reset admin 2>&1 || true)"
assert_no_secret "wp-admin-reset-stdout" "${out}"

out="$(hm_wp_install example.pl --title T --admin-email a@example.pl --yes 2>&1 || true)"
assert_no_secret "wp-install-stdout" "${out}"

# sekret idzie na fd 3 (TTY logów), nie do strumienia łapanego jako applog
secretf="${logdir}/tty"
: > "${secretf}"
exec 3>>"${secretf}"
HM_LOG_TTY_FDS=1
out="$(hm_access_ssh_passwd example.pl 2>&1 || true)"
assert_no_secret "ssh-passwd-stdout-with-ttyfd" "${out}"
if grep -F -q "${PASS}" "${secretf}"; then
  echo "OK   ssh-passwd-on-tty-fd"
else
  echo "FAIL ssh-passwd-on-tty-fd"
  fail=1
fi

# mysql create: hasło nie na stdout; quiet zwraca je tylko w zmiennej.
# shellcheck disable=SC1091
source lib/db.sh
hm_mysql_db_exists() { return 1; }
hm_mysql_exec() {
  printf '%s\n' "$*" >> "${logdir}/mysql-argv"
  cat >/dev/null || true
  return 0
}
hm_confirm_plan() { return 0; }
hm_gen_password() { printf '%s' "${PASS}"; }
export TMP_DIR="${logdir}"
: > "${logdir}/mysql-argv"
out="$(hm_mysql_create shopdb shopuser 2>&1 || true)"
assert_no_secret "mysql-create-stdout" "${out}"
assert_no_secret "mysql-create-argv" "$(cat "${logdir}/mysql-argv")"
if find "${logdir}" -name 'hmtools-create-user*.sql' | grep -q .; then
  echo "FAIL mysql-create-sql-leftover"
  fail=1
else
  echo "OK   mysql-create-sql-leftover"
fi
HM_MYSQL_CREATE_PASS=""
qout="${logdir}/mysql-quiet.out"
hm_mysql_create shopdb2 shopuser2 quiet >"${qout}" 2>&1 || true
out="$(cat "${qout}")"
assert_no_secret "mysql-create-quiet-stdout" "${out}"
if [[ "${HM_MYSQL_CREATE_PASS}" == "${PASS}" ]]; then
  echo "OK   mysql-create-quiet-var"
else
  echo "FAIL mysql-create-quiet-var"
  fail=1
fi

# redakcja „hasło (raz):” i zarejestrowanego sekretu bez etykiety
: > "${logf}"
printf '%s\n' "Basic auth: user=staging  hasło (raz): OtherPass99xx" | hm_log_stream_to_file OUT INFO
if grep -F -q 'OtherPass99xx' "${logf}"; then
  echo "FAIL log-redact-haslo-raz"
  cat "${logf}" || true
  fail=1
elif grep -q 'hasło (raz): \*\*\*' "${logf}"; then
  echo "OK   log-redact-haslo-raz"
else
  echo "FAIL log-redact-haslo-raz (wzorzec)"
  cat "${logf}" || true
  fail=1
fi
hm_secret_register "${PASS}"
: > "${logf}"
printf '%s\n' "linia ${PASS} koniec" | hm_log_stream_to_file OUT INFO
if grep -F -q "${PASS}" "${logf}"; then
  echo "FAIL log-redact-registered"
  cat "${logf}" || true
  fail=1
elif grep -q '\*\*\*' "${logf}"; then
  echo "OK   log-redact-registered"
else
  echo "FAIL log-redact-registered (brak maski)"
  fail=1
fi

# bez TTY mysql create nie tworzy bazy; z --secret-file zapisuje hasło i nie loguje go
export HMTOOLS_TEST=1
export HMTOOLS_TEST_NO_TTY=1
unset HM_SECRET_FILE
: > "${logdir}/mysql-argv"
rc=0
hm_mysql_create shopdb3 shopuser3 >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 0 ]]; then
  echo "FAIL mysql-create-notty-refused"
  fail=1
elif grep -q 'CREATE' "${logdir}/mysql-argv"; then
  echo "FAIL mysql-create-notty-still-ran"
  fail=1
else
  echo "OK   mysql-create-notty-refused"
fi
export HM_SECRET_FILE="${logdir}/mysql.secret"
: > "${logdir}/mysql-argv"
out="$(hm_mysql_create shopdb4 shopuser4 2>&1 || true)"
assert_no_secret "mysql-create-secret-file-stdout" "${out}"
if [[ -f "${HM_SECRET_FILE}" ]] && grep -F -q "${PASS}" "${HM_SECRET_FILE}"; then
  echo "OK   mysql-create-secret-file"
else
  echo "FAIL mysql-create-secret-file"
  fail=1
fi
if grep -q 'CREATE DATABASE' "${logdir}/mysql-argv"; then
  echo "OK   mysql-create-secret-file-ran"
else
  echo "FAIL mysql-create-secret-file-ran"
  fail=1
fi
unset HM_SECRET_FILE

# clone basic auth: bez TTY nie zapisuje htpasswd; z plikiem nie wstawia hasła do stdout
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
# shellcheck disable=SC1091
source commands/clone/main.sh
hm_have_cmd() { [[ "${1:-}" == "htpasswd" || "${1:-}" == "cyberpanel" ]]; }
htpasswd() { printf '%s\n' "$2:hash"; }
hm_gen_password() { printf '%s' "${PASS}"; }
doc="${logdir}/docroot"
mkdir -p "${doc}"
rc=0
out="$(hm_clone_apply_basic_auth staging.example.pl "${doc}" "$(id -un)" 2>&1)" || rc=$?
assert_no_secret "clone-basic-notty-stdout" "${out}"
if [[ "${rc}" -eq 0 || -f "${doc}/.htpasswd.hmtools" ]]; then
  echo "FAIL clone-basic-notty-refused rc=${rc}"
  fail=1
else
  echo "OK   clone-basic-notty-refused"
fi
export HM_SECRET_FILE="${logdir}/clone.secret"
rm -f "${doc}/.htpasswd.hmtools" "${doc}/.htaccess"
rc=0
out="$(hm_clone_apply_basic_auth staging.example.pl "${doc}" "$(id -un)" 2>&1)" || rc=$?
assert_no_secret "clone-basic-secret-file-stdout" "${out}"
if [[ "${rc}" -eq 0 && -f "${doc}/.htpasswd.hmtools" && -f "${HM_SECRET_FILE}" ]] && grep -F -q "${PASS}" "${HM_SECRET_FILE}"; then
  echo "OK   clone-basic-secret-file"
else
  echo "FAIL clone-basic-secret-file rc=${rc}"
  printf '%s\n' "${out}"
  fail=1
fi
if grep -F -q "${PASS}" "${logf}" 2>/dev/null; then
  echo "FAIL clone-basic-applog"
  fail=1
else
  echo "OK   clone-basic-applog"
fi
unset HM_SECRET_FILE
unset HMTOOLS_TEST HMTOOLS_TEST_NO_TTY

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
