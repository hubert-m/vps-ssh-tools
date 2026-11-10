#!/usr/bin/env bash
# site new — runtime Node: nvm z tagu i SHA-256, PM2/systemd, bez master.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1 HM_SITE_NODE_MOCK=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_confirm_plan() { return 0; }
hm_print_secret() { echo "SECRET:$*"; }
hm_gen_password() { printf 'GenPass12xYzAb99'; }
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }
hm_file_log() { :; }
hm_help_topic() { :; }
hm_tsv_unfield() { [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_USER=app
export HM_SITE_PORT_FILE="${root}/ports.ndjson"
export HM_NODE_FETCH_LOG="${root}/fetch.log"
export HM_NODE_FETCH_MOCK=1
export HM_NODE_FETCH_BODY="${root}/install.sh"
export HM_NODE_INDEX_FILE="${root}/index.json"
export HM_SITE_NODE_LOG="${root}/node.log"
export HM_SYSTEMD_UNIT_DIR="${root}/systemd"
mkdir -p "${HM_SITE_HOME_BASE}" "${HM_SYSTEMD_UNIT_DIR}"
: > "${HM_NODE_FETCH_LOG}"
: > "${HM_SITE_NODE_LOG}"

cat > "${HM_NODE_FETCH_BODY}" <<'EOF'
#!/bin/bash
mkdir -p "$NVM_DIR"
printf '%s\n' 'NVM_DIR nvm_echo "0.40.3"' > "$NVM_DIR/nvm.sh"
EOF
sum="$(sha256sum "${HM_NODE_FETCH_BODY}" | awk '{print $1}')"
export HM_NODE_NVM_PIN_SHA256="${sum}"

cat > "${HM_NODE_INDEX_FILE}" <<'EOF'
[
{"version":"v26.1.0","lts":false,"security":false},
{"version":"v24.11.1","lts":"Krypton","security":false},
{"version":"v24.11.0","lts":"Krypton","security":true},
{"version":"v22.14.0","lts":"Jod","security":false},
{"version":"v23.5.0","lts":false,"security":false},
{"version":"v20.18.0","lts":"Iron","security":false},
{"version":"v24.12.0-rc.1","lts":false,"security":false}
]
EOF

# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/db.sh
# shellcheck disable=SC1091
source lib/site/node.sh
# shellcheck disable=SC1091
source commands/site-create/wizard-db.sh
# shellcheck disable=SC1091
source commands/node/main.sh
# shellcheck disable=SC1091
source commands/pm2/main.sh

if hm_site_node_assert_pinned_url "https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh" >/dev/null 2>&1; then
  bad "reject-master"
else
  ok "reject-master"
fi
if grep -q master "${HM_NODE_FETCH_LOG}"; then
  bad "fetch-log-master"
else
  ok "fetch-log-clean"
fi

HM_NODE_NVM_PIN_SHA256="deadbeef"
if hm_site_node_install_nvm "bad.example.pl" >/dev/null 2>&1; then
  bad "bad-sha"
else
  ok "bad-sha"
fi
if [[ -f "${HM_SITE_HOME_BASE}/bad.example.pl/.nvm/nvm.sh" ]]; then
  bad "bad-sha-left-script"
else
  ok "bad-sha-left-script"
fi
export HM_NODE_NVM_PIN_SHA256="${sum}"

out="${root}/new.out"
cmd_site_new app.example.pl --runtime node --db none --node 24,22 --node-default 24 \
  --pkg pnpm --process pm2 --start "node dist/main.js" --port auto --yes >"${out}" 2>&1 || {
  bad "site-new"
  cat "${out}" >&2
  exit 1
}
ok "site-new"

home="${HM_SITE_HOME_BASE}/app.example.pl"
if grep -q '/nvm/v0.40.3/install.sh' "${HM_NODE_FETCH_LOG}" && ! grep -q master "${HM_NODE_FETCH_LOG}"; then
  ok "pinned-url"
else
  bad "pinned-url"
fi
[[ -f "${home}/.nvm/nvm.sh" ]] && ok "nvm-installed" || bad "nvm-installed"
[[ -d "${home}/.nvm/versions/node/v24.11.1" && -d "${home}/.nvm/versions/node/v22.14.0" ]] \
  && ok "nvm-ls-versions" || bad "nvm-ls-versions"
[[ "$(tr -d '[:space:]' < "${home}/.nvm/alias/default")" == "v24.11.1" ]] && ok "default-alias" || bad "default-alias"
[[ "$(tr -d '[:space:]' < "${home}/app/.nvmrc")" == "v24.11.1" ]] && ok "nvmrc" || bad "nvmrc"
ver="$("${home}/.nvm/versions/node/v24.11.1/bin/node")"
[[ "${ver}" == "v24.11.1" ]] && ok "node-v" || bad "node-v"

if grep -q 'corepack prepare pnpm@' "${HM_SITE_NODE_LOG}" && grep -q 'pm2 startup systemd -u app' "${HM_SITE_NODE_LOG}"; then
  ok "corepack-pm2"
else
  bad "corepack-pm2"
  cat "${HM_SITE_NODE_LOG}" >&2
fi

eco="${home}/shared/ecosystem.config.cjs"
secret="$(sed -n 's/^JWT_SECRET=//p' "${home}/shared/.env" | head -1)"
[[ -n "${secret}" ]] || { bad "secret-present"; secret="MISSING"; }
if grep -q 'env_file:' "${eco}" && grep -q '127.0.0.1' "${eco}" && grep -q 'app.example.pl' "${eco}" \
  && ! grep -q "${secret}" "${eco}" && ! grep -q "${secret}" "${HM_SITE_NODE_LOG}"; then
  ok "pm2-no-secret"
else
  bad "pm2-no-secret"
fi
grep -q '^PORT=' "${home}/shared/.env" && grep -q '^HOST=127.0.0.1$' "${home}/shared/.env" \
  && ok "env-host-port" || bad "env-host-port"
grep -q 'build=pnpm install --frozen-lockfile' "${home}/app/.hmtools-deploy" \
  && grep -q 'build=pnpm run build' "${home}/app/.hmtools-deploy" \
  && ok "deploy-steps" || bad "deploy-steps"
grep -q 'upstream=127.0.0.1:' "${home}/.hmtools/proxy.snippet" && ok "proxy" || bad "proxy"
grep -q '"packageManager":"pnpm@' "${home}/app/package.json" && ok "package-manager" || bad "package-manager"

hm_resolve_site_paths() {
  printf '%s\t%s\t%s\t-\t-\t-\t%s|active\n' "$1" "${HM_SITE_HOME_BASE}/$1" "${HM_SITE_HOME_BASE}/$1/public_html" "${HM_SITE_USER}"
}
probe="$(hm_node_probe_site app.example.pl || true)"
[[ "${probe}" == *$'\t''1'$'\t'* ]] && ok "node-sites-sees-nvm" || bad "node-sites-sees-nvm"
pm2bin="$(hm_pm2_bin_in_home "${home}" || true)"
[[ -n "${pm2bin}" && -x "${pm2bin}" ]] && ok "pm2-sees-bin" || bad "pm2-sees-bin"

: > "${HM_SITE_NODE_LOG}"
cmd_site_new svc.example.pl --runtime node --db none --node 24 --process systemd \
  --start "node dist/main.js" --port 4010 --yes >"${root}/sys.out" 2>&1 || {
  bad "systemd-new"
  cat "${root}/sys.out" >&2
  exit 1
}
unit="${HM_SYSTEMD_UNIT_DIR}/hm-app-svc-example-pl.service"
if [[ -f "${unit}" ]] && grep -q 'EnvironmentFile=-' "${unit}" && grep -q 'NoNewPrivileges=yes' "${unit}" \
  && grep -q 'ProtectSystem=strict' "${unit}" && grep -q 'ReadWritePaths=' "${unit}" \
  && grep -q 'Environment=HOST=127.0.0.1' "${unit}" && grep -q '^User=app$' "${unit}" \
  && grep -q '/.nvm/versions/node/v24.11.1/bin/node dist/main.js' "${unit}" \
  && grep -q 'systemctl enable hm-app-svc-example-pl.service' "${HM_SITE_NODE_LOG}"; then
  sec2="$(sed -n 's/^JWT_SECRET=//p' "${HM_SITE_HOME_BASE}/svc.example.pl/shared/.env" | head -1)"
  if [[ -n "${sec2}" ]] && ! grep -q "${sec2}" "${unit}"; then
    ok "systemd-unit"
  else
    bad "systemd-unit"
  fi
else
  bad "systemd-unit"
  cat "${unit}" >&2 || true
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
else
  echo "FAILED" >&2
  exit 1
fi
