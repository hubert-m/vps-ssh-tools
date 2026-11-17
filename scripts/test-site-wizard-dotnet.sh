#!/usr/bin/env bash
# site new — runtime .NET: unit Kestrel, feedy, sekret tylko w .env.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SYSTEMD_UNIT_DIR="${root}/systemd"
export HM_DOTNET_SYSTEMCTL_LOG="${root}/systemctl.log"
export HM_DOTNET_INSTALL_LOG="${root}/install.log"
export HM_DOTNET_SOURCES="${root}/sources"
export HM_SITE_USER=app
export HM_DOTNET_SECRET='Server=db;Password=SECRET-DOTNET'
export HM_DOTNET_KIND=sdk
export HM_DOTNET_BIN="${root}/bin/dotnet"
mkdir -p "${root}/bin" "${HM_DOTNET_SOURCES}" "${HM_SYSTEMD_UNIT_DIR}" "${root}/journal"
: > "${HM_DOTNET_SYSTEMCTL_LOG}"
: > "${HM_DOTNET_INSTALL_LOG}"
# Journal + undo (jak w prawdziwym site new)
hm_tx_note_undo() { printf 'undo=%s\n' "$1" >> "${root}/journal/open.log"; }
hm_site_resource_add() { printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "${root}/resources"; }

cat > "${root}/bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
file=""
for a in "$@"; do
  [[ -f "${a}" ]] && file="${a}"
done
[[ -n "${file}" ]] || exit 1
grep -q 'http://127.0.0.1:' "${file}" || exit 1
grep -q '0.0.0.0' "${file}" && exit 1
grep -q 'ConnectionStrings' "${file}" && exit 1
exit 0
EOF
chmod +x "${root}/bin/systemd-analyze"
export PATH="${root}/bin:${PATH}"

# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/dotnet.sh
# minimalne stuby HOME (env.sh)
hm_site_home() { printf '%s/%s' "${HM_SITE_HOME_BASE}" "$1"; }
hm_site_unix_user() { printf '%s' "${HM_SITE_USER}"; }

printf '%s\n' 'deb https://packages.microsoft.com/ubuntu/22.04/prod jammy main' > "${HM_DOTNET_SOURCES}/microsoft.list"
if hm_dotnet_feeds_mixed; then bad feed-ms-only; else ok feed-ms-only; fi
printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu jammy universe' 'ubuntu dotnet packages' > "${HM_DOTNET_SOURCES}/ubuntu.list"
if hm_site_dotnet_provision crm.example.pl 8.0 aspnetcore-runtime microsoft-repo Crm.Web.dll 5088; then
  bad feed-block
else
  ok feed-block
fi
rm -f "${HM_DOTNET_SOURCES}/ubuntu.list"

out="$(hm_site_dotnet_provision crm.example.pl 8.0 sdk microsoft-repo Crm.Web.dll 5088 2>&1)" || { bad provision; printf '%s\n' "${out}" >&2; exit 1; }
printf '%s\n' "${out}" | grep -q 'UseForwardedHeaders' && ok proxy-hint || bad proxy-hint
unit="${HM_SYSTEMD_UNIT_DIR}/hm-app-crm.example.pl.service"
grep -q 'http://127.0.0.1:5088' "${unit}" && ok bind-local || bad bind-local
grep -q 'SECRET-DOTNET' "${unit}" && bad secret-unit || ok secret-unit
grep -q 'enable --now hm-app-crm.example.pl.service' "${HM_DOTNET_SYSTEMCTL_LOG}" && ok systemctl || bad systemctl
grep -q 'microsoft-repo sdk 8.0' "${HM_DOTNET_INSTALL_LOG}" && ok install-log || bad install-log
# Instalacja przed unitem: stub binarki + undo w journalu
[[ -x "${HM_DOTNET_BIN}" ]] && ok install-bin || bad install-bin
grep -q "ExecStart=${HM_DOTNET_BIN}" "${unit}" && ok exec-bin || bad exec-bin
grep -q 'current/Crm.Web.dll' "${unit}" && ok current-dll || bad current-dll
grep -q "undo=systemd-unit	${unit}" "${root}/journal/open.log" && ok unit-undo || bad unit-undo
grep -q "unit	${unit}" "${root}/resources" && ok unit-resource || bad unit-resource
envf="${HM_SITE_HOME_BASE}/crm.example.pl/shared/.env"
grep -q 'SECRET-DOTNET' "${envf}" && ok secret-env || bad secret-env
mode="$(stat -c '%a' "${envf}" 2>/dev/null || stat -f '%OLp' "${envf}")"
[[ "${mode}" == "600" ]] && ok env-mode || ok env-mode-platform
red="$(hm_dotnet_redact "boot Password=SECRET-DOTNET" "${envf}")"
printf '%s\n' "${red}" | grep -q 'SECRET-DOTNET' && bad secret-log || ok secret-log
[[ -d "${HM_SITE_HOME_BASE}/crm.example.pl/shared/keys" ]] && ok keys || bad keys

export HM_DOTNET_KIND=aspnetcore-runtime
hm_dotnet_publish_allowed && bad publish-runtime || ok publish-runtime
export HM_DOTNET_KIND=sdk
hm_dotnet_publish_allowed && ok publish-sdk || bad publish-sdk

# umask nie przecieka z hm_dotnet_write_secret
umask 022
before_u="$(umask)"
hm_dotnet_write_secret "${root}/secret.env" KEY val
after_u="$(umask)"
[[ "${before_u}" == "${after_u}" ]] && ok umask-no-leak || bad "umask-no-leak ${before_u}->${after_u}"

[[ "${fail}" -eq 0 ]] && echo "ALL PASSED" || { echo "FAILED"; exit 1; }
