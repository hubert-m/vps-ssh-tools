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

# Exact vhost — bez prefiksu ${domain}*
other_vh="${root}/vhosts/${domain}-old.conf"
mkdir -p "${root}/vhosts" /etc/nginx/sites-available 2>/dev/null || true
export HM_SITE_VHOST_DIR="${root}/vhosts"
printf 'x\n' > "${HM_SITE_VHOST_DIR}/${domain}.conf"
printf 'y\n' > "${other_vh}"
if hm_site_delete_path_allowed "${other_vh}" vhost "${domain}"; then
  bad "vhost cudzej strony (prefiks)"
else
  ok "vhost tylko dokładna nazwa"
fi
if hm_site_delete_path_allowed "${HM_SITE_VHOST_DIR}/${domain}.conf" vhost "${domain}"; then
  ok "vhost własny OK"
else
  bad "vhost własny odrzucony"
fi

# Unit traversal + cudzy unit
trav="${HM_SITE_SYSTEMD_DIR}/hm-../../ofiara"
if hm_site_delete_path_allowed "${trav}" unit "${domain}"; then
  bad "unit z .. przeszedł"
else
  ok "unit z .. odrzucony"
fi
foreign="${HM_SITE_SYSTEMD_DIR}/hm-other.example.service"
printf 'u\n' > "${foreign}"
if hm_site_delete_path_allowed "${foreign}" unit "${domain}"; then
  bad "cudzy unit przeszedł"
else
  ok "cudzy unit odrzucony"
fi

# resources.ndjson 0600 (na NTFS chmod często nie działa — wtedy pomijamy)
probe="${root}/mode-probe"
: > "${probe}"
chmod 0600 "${probe}" 2>/dev/null || true
mode_ok=0
[[ "$(stat -c '%a' "${probe}" 2>/dev/null || stat -f '%OLp' "${probe}" 2>/dev/null || true)" == "600" ]] && mode_ok=1
if [[ "${mode_ok}" -eq 1 ]]; then
  mode="$(stat -c '%a' "$(hm_site_resources_path "${domain}")" 2>/dev/null || stat -f '%OLp' "$(hm_site_resources_path "${domain}")" 2>/dev/null || true)"
  [[ "${mode}" == "600" || "${mode}" == "0600" ]] && ok "resources 0600" || bad "resources mode=${mode}"
else
  ok "resources 0600 (platforma bez chmod)"
fi

# sites-enabled: kasuj link, nie cel
en_dir="${root}/nginx/sites-enabled"
av_dir="${root}/nginx/sites-available"
mkdir -p "${en_dir}" "${av_dir}"
export HM_SITE_VHOST_ENABLED_DIR="${en_dir}"
printf 'server{}\n' > "${av_dir}/${domain}.conf"
ln -sfn "${av_dir}/${domain}.conf" "${en_dir}/${domain}.conf" 2>/dev/null || true
if [[ -L "${en_dir}/${domain}.conf" ]]; then
  if hm_site_lifecycle_remove_path "${en_dir}/${domain}.conf" vhost; then
    [[ -L "${en_dir}/${domain}.conf" ]] && bad "link sites-enabled został" || ok "link sites-enabled usunięty"
    [[ -f "${av_dir}/${domain}.conf" ]] && ok "cel vhosta nietknięty" || bad "cel vhosta skasowany"
  else
    bad "odmowa usunięcia linku sites-enabled"
  fi
else
  ok "brak symlinku sites-enabled — pominięte"
fi

# zapis HOME bez podążania za symlinkiem
nvmrc="${home}/.nvmrc"
rm -f "${nvmrc}"
ln -s "${victim}/plik" "${nvmrc}" 2>/dev/null || true
if [[ -L "${nvmrc}" ]]; then
  if printf '22\n' | hm_site_write_nofollow "${nvmrc}" 2>/dev/null; then
    bad "write_nofollow nadpisał przez symlink"
  else
    ok "write_nofollow odmawia symlinku"
  fi
  grep -q sekret "${victim}/plik" && ok "ofiara nvmrc nietknięta" || bad "ofiara nvmrc zmieniona"
else
  ok "brak symlinku nvmrc — pominięte"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo ALL OK
