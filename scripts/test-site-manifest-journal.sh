#!/usr/bin/env bash
# Manifest, journal, lock, resume, rollback, profile.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { return 1; }
hm_confirm_plan() { return 0; }
hm_is_valid_domain() { return 0; }
hm_site_db_provision() { return 0; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_MANIFEST_DIR="${root}/manifest"
export HM_SITE_JOURNAL_DIR="${root}/journal"
export HM_SITE_LOCK_DIR="${root}/locks"
export HM_SITE_HOME_BASE="${root}/homes"
mkdir -p "${HM_SITE_HOME_BASE}"

# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh

probe="${root}/probe"
: > "${probe}"
chmod 0600 "${probe}" || true
mode_ok=0
[[ "$(stat -c %a "${probe}" 2>/dev/null || stat -f %OLp "${probe}")" == "600" ]] && mode_ok=1

# rollback po „kill” usuwa tylko zapisane undo
mkdir -p "${root}/res"
hm_tx_begin kill.example
txrc=0
hm_tx_step files "rm -rf ${root}/res" || txrc=$?
[[ "${txrc}" -eq 2 ]] || bad rollback-started
echo secret-token > "${root}/res/f"
hm_tx_done files
hm_tx_unlock
HM_TX_JOURNAL=""
hm_tx_rollback kill.example >/dev/null
if [[ -e "${root}/res" ]]; then bad rollback-gone; else ok rollback-gone; fi

# resume pomija DONE i nie dubluje katalogu
mkdir -p "${root}/keep"
hm_tx_begin resume.example
txrc=0
hm_tx_step keep "rm -rf ${root}/keep" || txrc=$?
hm_tx_done keep
hm_tx_unlock
HM_TX_JOURNAL=""
hm_tx_resume resume.example >/dev/null
skip="$(hm_tx_step keep "rm -rf ${root}/keep" 2>&1 || true)"
printf '%s\n' "${skip}" | grep -q 'pomijam — już jest' && ok resume-skip || bad resume-skip
[[ -d "${root}/keep" ]] && ok resume-keeps || bad resume-keeps
hm_tx_unlock

# lock: drugi begin przy żywym PID
hm_tx_begin lock.example
HM_TX_LOCK=""
if hm_tx_begin lock.example >/dev/null 2>&1; then bad lock-busy; else ok lock-busy; fi
printf '999999\n' > "$(hm_tx_lock_path stale.example)"
HM_TX_LOCK=""
if hm_tx_begin stale.example >/dev/null; then ok lock-stale; else bad lock-stale; fi
hm_tx_unlock
HM_TX_LOCK=""
if hm_tx_pkg_lock >/dev/null; then
  HM_TX_LOCK=""
  if hm_tx_pkg_lock >/dev/null 2>&1; then bad pkg-lock; else ok pkg-lock; fi
else
  bad pkg-lock
fi
hm_tx_unlock

# manifest bez sekretu, 0600 gdy chmod działa
if hm_site_manifest_record_db app.example mysql appdb app 127.0.0.1 3306 'password=secret-token'; then
  bad manifest-rejects-secret
else
  ok manifest-rejects-secret
fi
hm_site_manifest_record_db app.example mysql appdb app 127.0.0.1 3306 ''
path="$(hm_site_manifest_write app.example appuser php nginx "${root}/homes/app.example/shared/.env" www)"
if grep -Eq 'password|secret-token|token' "${path}"; then bad manifest-clean; else ok manifest-clean; fi
if [[ "${mode_ok}" -eq 1 ]]; then
  [[ "$(stat -c %a "${path}" 2>/dev/null || stat -f %OLp "${path}")" == "600" ]] && ok manifest-mode || bad manifest-mode
  [[ "$(stat -c %a "${HM_SITE_MANIFEST_DIR}" 2>/dev/null || stat -f %OLp "${HM_SITE_MANIFEST_DIR}")" == "700" ]] && ok manifest-dir || bad manifest-dir
else
  ok manifest-mode-platform
  ok manifest-dir-platform
fi
show="$(cmd_site_manifest app.example)"
printf '%s\n' "${show}" | grep -q '"domain":"app.example"' && ok manifest-show || bad manifest-show

# site new z profilu, drugie uruchomienie nic nie dopisuje
cat > "${root}/spa.json" <<'EOF'
{"preset":"spa","runtime":"static","db":"none","webserver":"","php":"","domain":""}
EOF
cmd_site_new spa.example --from "${root}/spa.json" --save-profile "${root}/out.json" --yes >/dev/null
grep -q '"type":"static"' "$(hm_site_manifest_path spa.example)" && ok profile-new || bad profile-new
if grep -q 'secret-token' "${root}/out.json" || ! grep -q '"runtime":"static"' "${root}/out.json"; then bad profile-saved; else ok profile-saved; fi
before="$(cat "$(hm_site_manifest_path spa.example)")"
second="$(cmd_site_new spa.example --from "${root}/spa.json" --yes 2>&1 || true)"
printf '%s\n' "${second}" | grep -q 'pomijam — już jest' && ok idempotent || bad idempotent
[[ "$(cat "$(hm_site_manifest_path spa.example)")" == "${before}" ]] && ok idempotent-file || bad idempotent-file

# --resume domyka otwarty journal
dom="go.example"
dir="$(hm_site_journal_dir)"
mkdir -p "${dir}"
printf 'BEGIN tx %s\nBEGIN layout\nundo=\nDONE layout\n' "${dom}" > "${dir}/${dom}-1.log"
cmd_site_new "${dom}" --resume --db none --yes >/dev/null
grep -q '^COMMIT$' "${dir}/${dom}-1.log" && ok resume-commit || bad resume-commit

# YAML bez parsera
printf 'preset: spa\n' > "${root}/p.yml"
HM_SITE_YAML_FORCE=missing
if hm_site_profile_load "${root}/p.yml" >/dev/null 2>"${root}/yaml.err"; then
  bad yaml-missing
else
  grep -q 'yaml' "${root}/yaml.err" && ok yaml-missing || bad yaml-missing
fi

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
