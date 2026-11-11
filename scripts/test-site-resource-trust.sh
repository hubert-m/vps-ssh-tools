#!/usr/bin/env bash
# Podmieniony ~/.hmtools nie steruje webs delete. Ścieżka spoza allowlisty zostaje.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/site/env.sh
# shellcheck disable=SC1091
source lib/site/tx.sh
# shellcheck disable=SC1091
source lib/site/lifecycle.sh

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
export HM_SITE_HOME_BASE="${root}/homes"
export HM_SITE_MANIFEST_DIR="${root}/manifests"
export HM_SITE_STATE_DIR="${root}/state"
export HM_SITE_SYSTEMD_DIR="${root}/systemd"
domain="app.example"
home="$(hm_site_home "${domain}")"
mkdir -p "${home}/.hmtools" "${HM_SITE_SYSTEMD_DIR}" "${HM_SITE_MANIFEST_DIR}"
victim="${root}/etc/ofiara"
mkdir -p "${victim}"
printf 'sekret\n' > "${victim}/plik"

printf '%s\n' "{\"kind\":\"logrotate\",\"path\":\"${victim}\",\"shared\":false}" \
  > "${home}/.hmtools/${domain}.resources.ndjson"
printf '%s\n' "{\"domain\":\"${domain}\",\"drop\":\"${victim}\"}" > "${home}/.hmtools/service.json"

good="${HM_SITE_SYSTEMD_DIR}/hm-${domain}.service"
printf 'unit\n' > "${good}"
hm_site_resource_add "${domain}" unit "${good}" 0

HM_DEL_DOMAIN="${domain}"
HM_DEL_WIZARD=()
hm_site_lifecycle_collect_delete
joined="$(printf '%s\n' "${HM_DEL_WIZARD[@]:-}")"
if printf '%s\n' "${joined}" | grep -F -q "${victim}"; then
  bad "plan czyta listę z HOME"
else
  ok "plan ignoruje ~/.hmtools"
fi
if printf '%s\n' "${joined}" | grep -F -q "${good}"; then
  ok "plan bierze listę z /etc"
else
  bad "brak oficjalnej listy"
fi

if hm_site_lifecycle_remove_path "${victim}" logrotate; then
  bad "allowlista przyjęła ${victim}"
else
  ok "odmowa ścieżki spoza allowlisty"
fi
[[ -d "${victim}" && -f "${victim}/plik" ]] && ok "ofiara zostaje" || bad "ofiara skasowana"

link="${HM_SITE_SYSTEMD_DIR}/hm-${domain}.link"
ln -s "${victim}" "${link}" 2>/dev/null || true
line="$(ls -ld -- "${link}" 2>/dev/null || true)"
if [[ "${line}" == *"->"* ]]; then
  if hm_site_delete_path_allowed "${link}" unit "${domain}"; then
    bad "symlink na allowliście"
  else
    ok "symlink odrzucony"
  fi
  [[ -d "${victim}" ]] && ok "symlink nie skasował celu" || bad "cel symlinku zniknął"
else
  ok "ten bash nie tworzy symlinku — odmowa sprawdzona na katalogu"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo ALL OK
