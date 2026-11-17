#!/usr/bin/env bash
# system: status (offset, rDNS, locale), sync/timezone/hostname/locale fix — mocki HM_SYSTEM_*.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export HMTOOLS_ROOT="${ROOT}"
export HMTOOLS_TEST=1
export OS_FAMILY=debian

# shellcheck disable=SC1091
source scripts/_stubs.sh
hm_confirm_plan() { return 0; }
# shellcheck disable=SC1091
source commands/system/main.sh

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export HM_SYSTEM_TIMEDATECTL_LOG="${tmp}/tdctl.log"
export HM_SYSTEM_HOSTNAMECTL_LOG="${tmp}/hctl.log"
export HM_SYSTEM_LOCALE_GEN_LOG="${tmp}/locale-gen.log"
export HM_SYSTEM_MAIN_IP="203.0.113.10"
export HM_SYSTEM_SYNC_DAEMON=chrony
export HM_SYSTEM_CHRONY_OFFSET=2.5
export HM_SYSTEM_NTP_SYNC=no
export HM_SYSTEM_TIMEZONE=Europe/Warsaw
export HM_SYSTEM_ETC_HOSTNAME="${tmp}/hostname"
export HM_SYSTEM_LOCALE_GEN="${tmp}/locale.gen"
export HM_SYSTEM_LOCALE_A="${tmp}/locale.a"
printf 'mail.vps.example.com\n' > "${HM_SYSTEM_ETC_HOSTNAME}"
printf 'C\n' > "${tmp}/locale.env"
touch "${HM_SYSTEM_LOCALE_A}"

cat > "${tmp}/timedatectl.sh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  show)
    if [[ "${2:-}" == "-p" ]]; then
      case "${3:-}" in
        NTPSynchronized) echo "no" ;;
        Timezone) echo "Europe/Warsaw" ;;
        *) echo "" ;;
      esac
      exit 0
    fi
    ;;
  set-ntp)
    echo "set-ntp ${2:-}" >> "${HM_SYSTEM_TIMEDATECTL_LOG:-/dev/null}"
    exit 0
    ;;
  set-timezone)
    echo "set-timezone ${2:-}" >> "${HM_SYSTEM_TIMEDATECTL_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
MOCK
chmod +x "${tmp}/timedatectl.sh"

cat > "${tmp}/hostname.sh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  -f) printf '%s\n' "$(tr -d '[:space:]' < "${HM_SYSTEM_ETC_HOSTNAME}")" ;;
  -s) printf '%s\n' "$(basename "$(tr -d '[:space:]' < "${HM_SYSTEM_ETC_HOSTNAME}")" .example.com)" ;;
  -I) printf '%s\n' "${HM_SYSTEM_MAIN_IP}" ;;
esac
MOCK
chmod +x "${tmp}/hostname.sh"

cat > "${tmp}/dig.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "+short" && "${2:-}" == "-x" ]]; then
  printf 'wrong-ptr.example.net.\n'
fi
MOCK
chmod +x "${tmp}/dig.sh"

export HM_SYSTEM_TIMEDATECTL="${tmp}/timedatectl.sh"
export HM_SYSTEM_HOSTNAME="${tmp}/hostname.sh"
export HM_SYSTEM_DIG="${tmp}/dig.sh"
export HM_SYSTEM_LOCALE_ENV="${tmp}/locale.env"

set +e
out="$(cmd_system status 2>&1)"
st=$?
set -e
[[ "${st}" -ne 0 ]] && ok "status-rc-warn" || bad "status-rc-warn"
printf '%s\n' "${out}" | grep -qi 'offset' && ok "status-offset" || bad "status-offset"
printf '%s\n' "${out}" | grep -qi 'rDNS' && ok "status-rdns-warn" || bad "status-rdns-warn"
printf '%s\n' "${out}" | grep -qi 'LANG' && ok "status-lang" || bad "status-lang"

# idempotent NTP already
export HM_SYSTEM_NTP_SYNC=yes
export HM_SYSTEM_CHRONY_OFFSET=0.01
if cmd_system time sync on >/dev/null 2>&1; then
  [[ ! -s "${HM_SYSTEM_TIMEDATECTL_LOG}" ]] && ok "sync-idempotent" || bad "sync-idempotent"
else
  bad "sync-idempotent-cmd"
fi

# timezone idempotent (already Europe/Warsaw)
: > "${HM_SYSTEM_TIMEDATECTL_LOG}"
cmd_system timezone set Europe/Warsaw >/dev/null 2>&1 && ok "tz-idempotent" || bad "tz-idempotent"
[[ ! -s "${HM_SYSTEM_TIMEDATECTL_LOG}" ]] && ok "tz-no-write" || bad "tz-no-write"

# timezone change
cmd_system timezone set America/New_York >/dev/null 2>&1 && ok "tz-set" || bad "tz-set"
grep -q 'set-timezone America/New_York' "${HM_SYSTEM_TIMEDATECTL_LOG}" && ok "tz-log" || bad "tz-log"

# hostname idempotent
: > "${HM_SYSTEM_HOSTNAMECTL_LOG}"
printf 'mail.vps.example.com\n' > "${HM_SYSTEM_ETC_HOSTNAME}"
cmd_system hostname set mail.vps.example.com >/dev/null 2>&1 && ok "host-idempotent" || bad "host-idempotent"
[[ ! -s "${HM_SYSTEM_HOSTNAMECTL_LOG}" ]] && ok "host-no-write" || bad "host-no-write"

export HM_SYSTEM_ETC_HOSTS="${tmp}/hosts"
export HM_SYSTEM_HOSTS_LOG="${tmp}/hosts.log"
printf '127.0.0.1 localhost\n127.0.1.1 old.example.com old\n' > "${HM_SYSTEM_ETC_HOSTS}"
cmd_system hostname set srv.new.example.com >/dev/null 2>&1 && ok "host-set" || bad "host-set"
grep -q 'set-hostname srv.new.example.com' "${HM_SYSTEM_HOSTNAMECTL_LOG}" && ok "host-log" || bad "host-log"
grep -qE '^127\.0\.1\.1 srv\.new\.example\.com srv$' "${HM_SYSTEM_ETC_HOSTS}" && ok "host-hosts" || bad "host-hosts"

# locale fix (Debian / locale-gen)
printf '# pl_PL.UTF-8 UTF-8\n' > "${HM_SYSTEM_LOCALE_GEN}"
: > "${HM_SYSTEM_LOCALE_GEN_LOG}"
cmd_system locale fix >/dev/null 2>&1 && ok "locale-fix" || bad "locale-fix"
grep -q locale-gen "${HM_SYSTEM_LOCALE_GEN_LOG}" && ok "locale-gen-log" || bad "locale-gen-log"
grep -qxi 'en_US.UTF-8' "${HM_SYSTEM_LOCALE_A}" && ok "locale-a-updated" || bad "locale-a-updated"

# second locale fix idempotent
grep -qxi 'C.UTF-8' "${HM_SYSTEM_LOCALE_A}" || echo 'C.UTF-8' >> "${HM_SYSTEM_LOCALE_A}"
grep -qxi 'pl_PL.UTF-8' "${HM_SYSTEM_LOCALE_A}" || echo 'pl_PL.UTF-8' >> "${HM_SYSTEM_LOCALE_A}"
grep -qxi 'en_US.UTF-8' "${HM_SYSTEM_LOCALE_A}" || echo 'en_US.UTF-8' >> "${HM_SYSTEM_LOCALE_A}"
: > "${HM_SYSTEM_LOCALE_GEN_LOG}"
cmd_system locale fix >/dev/null 2>&1 && ok "locale-idempotent" || bad "locale-idempotent"
[[ ! -s "${HM_SYSTEM_LOCALE_GEN_LOG}" ]] && ok "locale-no-gen" || bad "locale-no-gen"

# RHEL: localedef + langpacki, bez localectl set-locale; rc≠0 przy fail
export OS_FAMILY=rhel
unset HM_SYSTEM_LOCALE_GEN_LOG
export HM_SYSTEM_LOCALEDEF_LOG="${tmp}/localedef.log"
export HM_SYSTEM_PKG_LOG="${tmp}/pkg.log"
hm_pkg_install() { printf 'pkg %s\n' "$*" >> "${HM_SYSTEM_PKG_LOG}"; }
: > "${HM_SYSTEM_LOCALE_A}"
: > "${HM_SYSTEM_LOCALEDEF_LOG}"
: > "${HM_SYSTEM_PKG_LOG}"
cmd_system locale fix >/dev/null 2>&1 && ok "locale-rhel" || bad "locale-rhel"
grep -q 'glibc-langpack-pl' "${HM_SYSTEM_PKG_LOG}" && ok "locale-rhel-pkg" || bad "locale-rhel-pkg"
grep -q 'localedef' "${HM_SYSTEM_LOCALEDEF_LOG}" && ok "locale-rhel-localedef" || bad "locale-rhel-localedef"
! grep -qi 'localectl' "${HM_SYSTEM_LOCALEDEF_LOG}" && ok "locale-rhel-no-localectl" || bad "locale-rhel-no-localectl"

export HM_SYSTEM_LOCALEDEF_FAIL=1
: > "${HM_SYSTEM_LOCALE_A}"
: > "${HM_SYSTEM_LOCALEDEF_LOG}"
if cmd_system locale fix >/dev/null 2>&1; then
  bad "locale-rhel-fail-rc"
else
  ok "locale-rhel-fail-rc"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"