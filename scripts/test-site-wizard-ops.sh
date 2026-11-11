#!/usr/bin/env bash
# Mock operacji kreatora: timer, worker, logrotate, health, firewall.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/lifecycle.sh
# shellcheck disable=SC1091
source lib/site/ops.sh

export HMTOOLS_TEST=1
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_MANIFEST_DIR="${root}/manifests"
export HM_SITE_SYSTEMD_DIR="${root}/systemd"
export HM_SITE_LOGROTATE_DIR="${root}/logrotate"
export HM_SITE_FW_DIR="${root}/fw"
export HM_SITE_HEALTH_REG="${root}/health.units"
export HM_SYSTEMCTL_STATE="${root}/systemctl.state"
export HM_SITE_OPS_LOG="${root}/ops.log"
export HM_TX_JOURNAL="${root}/journal.log"
export HM_SITE_BACKUP_LIST="${root}/backup.list"
: > "${HM_TX_JOURNAL}"
mkdir -p "${HM_SITE_FW_DIR}"
printf '80/tcp\n443/tcp\n' > "${HM_SITE_FW_DIR}/public.rules"
before="$(cat "${HM_SITE_FW_DIR}/public.rules")"

cat > "${root}/analyze.sh" <<'EOF'
#!/bin/bash
f="$2"
grep -q '^\[Unit\]' "${f}" || exit 1
grep -q '0.0.0.0' "${f}" && exit 1
if grep -q '^\[Timer\]' "${f}"; then exit 0; fi
grep -q '^\[Service\]' "${f}" || exit 1
exit 0
EOF
cat > "${root}/analyze-fail.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "${root}/logrotate.sh" <<'EOF'
#!/bin/bash
f="$2"
grep -q 'daily' "${f}" || exit 1
grep -q 'rotate 14' "${f}" || exit 1
grep -q 'compress' "${f}" || exit 1
grep -q 'copytruncate' "${f}" || exit 1
exit 0
EOF
export HM_SYSTEMD_ANALYZE="${root}/analyze.sh"
export HM_LOGROTATE_BIN="${root}/logrotate.sh"

ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

domain="shop.example"
home="${HM_SITE_HOME_BASE}/${domain}"
mkdir -p "${home}/.hmtools" "${HM_SITE_MANIFEST_DIR}"
printf '{"domain":"%s","runtime":{"type":"php","version":"8.3"}}\n' "${domain}" \
  > "${HM_SITE_MANIFEST_DIR}/${domain}.json"

hm_site_ops_apply "${domain}" laravel "" queue 2 /up "" || bad "apply"
svc="${HM_SITE_SYSTEMD_DIR}/hm-cron-shop.example-schedule.service"
tmr="${HM_SITE_SYSTEMD_DIR}/hm-cron-shop.example-schedule.timer"
worker="${HM_SITE_SYSTEMD_DIR}/hm-worker-shop.example@.service"
lr="${HM_SITE_LOGROTATE_DIR}/hm-shop.example"
[[ -f "${svc}" && -f "${tmr}" && -f "${worker}" && -f "${lr}" ]] || bad "files"
bash "${HM_SYSTEMD_ANALYZE}" verify "${svc}" || bad "analyze-svc"
bash "${HM_SYSTEMD_ANALYZE}" verify "${tmr}" || bad "analyze-tmr"
bash "${HM_SYSTEMD_ANALYZE}" verify "${worker}" || bad "analyze-worker"
grep -q 'Restart=always' "${worker}" || bad "restart"
grep -q 'MemoryMax=' "${worker}" || bad "memory"
grep -q 'schedule:run' "${svc}" || bad "laravel"
grep -q 'queue:work' "${worker}" || bad "queue"
bash "${HM_LOGROTATE_BIN}" -d "${lr}" || bad "logrotate"
grep -q 'shop.example' "${HM_SITE_MANIFEST_DIR}/${domain}.resources.ndjson" || bad "manifest-res"
grep -q '0.0.0.0' "${worker}" && bad "bind" || true
[[ "$(cat "${HM_SITE_FW_DIR}/public.rules")" == "${before}" ]] || bad "ports-same"
[[ ! -f "${HM_SITE_FW_DIR}/hm-shop.example.rules" ]] || bad "no-extra-port"
grep -q 'https://shop.example/up' "$(hm_site_state_dir "${domain}")/health.url" || bad "health-url"
grep -q 'hm-worker-shop.example@1.service' "${HM_SITE_HEALTH_REG}" || bad "inst-1"
grep -q 'hm-worker-shop.example@2.service' "${HM_SITE_HEALTH_REG}" || bad "inst-2"
grep -q '^undo=rm -f ' "${HM_TX_JOURNAL}" || bad "undo"
ok "units"
ok "logrotate"
ok "ports-closed"
ok "journal-undo"

printf 'hm-worker-shop.example@1.service inactive\nhm-worker-shop.example@2.service active\n' \
  > "${HM_SYSTEMCTL_STATE}"
_hm_cmd_help() { :; }
_hm_cmd_register() { :; }
# shellcheck disable=SC1091
source commands/health/main.sh
hm_load_config() { :; }
hm_detect_all() { :; }
hm_discover_sites() { :; }
hm_disk_used_percent() { echo 10; }
hm_health_failed_services() { :; }
notify_log="${root}/notify.log"
hm_notify() { printf '%s\n' "$*" >> "${notify_log}"; }
set +e
out="$(hm_health_check --notify 2>&1)"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || bad "health-rc"
printf '%s\n' "${out}" | grep -q 'service:failed:hm-worker-shop.example@1.service' || bad "health-alert"
grep -q 'service:failed:hm-worker-shop.example@1.service' "${notify_log}" || bad "notify"
ok "health-worker"

hm_site_ops_rollback "${domain}" || bad "rollback"
[[ ! -f "${svc}" && ! -f "${tmr}" && ! -f "${worker}" && ! -f "${lr}" ]] || bad "rollback-files"
grep -q 'disable hm-cron-shop.example-schedule.timer' "${HM_SITE_OPS_LOG}" || bad "disable-timer"
grep -q 'disable hm-worker-shop.example@.service' "${HM_SITE_OPS_LOG}" || bad "disable-worker"
ok "rollback"

export HM_SYSTEMD_ANALYZE="${root}/analyze-fail.sh"
bad_domain="bad.example"
mkdir -p "${HM_SITE_HOME_BASE}/${bad_domain}/.hmtools"
printf '{"domain":"%s"}\n' "${bad_domain}" > "${HM_SITE_MANIFEST_DIR}/${bad_domain}.json"
set +e
hm_site_ops_apply "${bad_domain}" laravel "" "" 1 "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || bad "analyze-fail-rc"
[[ ! -e "${HM_SITE_SYSTEMD_DIR}/hm-cron-bad.example-schedule.timer" ]] || bad "analyze-fail-left"
[[ ! -e "${HM_SITE_LOGROTATE_DIR}/hm-bad.example" ]] || bad "analyze-fail-lr"
ok "analyze-fail"

export HM_SYSTEMD_ANALYZE="${root}/analyze.sh"
export HM_SITE_DOCKER=1
export HM_SITE_BACKUP=1
export HM_SITE_HEALTH_REG="${root}/health-open.units"
open_domain="open.example"
mkdir -p "${HM_SITE_HOME_BASE}/${open_domain}/.hmtools"
printf '{"domain":"%s"}\n' "${open_domain}" > "${HM_SITE_MANIFEST_DIR}/${open_domain}.json"
set +e
warn="$(hm_site_ops_apply "${open_domain}" wp "" celery 1 /healthz 9090 2>&1)"
rc=$?
set -e
[[ "${rc}" -eq 0 ]] || bad "open-rc"
printf '%s\n' "${warn}" | grep -q 'Docker omija UFW' || bad "docker"
grep -q 'DISABLE_WP_CRON=true' "$(hm_site_state_dir "${open_domain}")/wp-cron.env" || bad "wp-cron"
grep -q '9090/tcp # hm:open.example' "${HM_SITE_FW_DIR}/hm-open.example.rules" || bad "open-port"
grep -q '3000' "${HM_SITE_FW_DIR}/public.rules" && bad "app-port" || true
grep -q 'open.example' "${HM_SITE_BACKUP_LIST}" || bad "backup"
grep -q 'celery' "${HM_SITE_SYSTEMD_DIR}/hm-worker-open.example@.service" || bad "celery"
ok "open-port"
ok "docker-warn"
ok "backup"
echo ALL OK
