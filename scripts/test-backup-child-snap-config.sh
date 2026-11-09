#!/usr/bin/env bash
# Regresja: restore childa — wyjątek DB tylko z configu w korzeniu docroot tara.
# Zagnieżdżony wp-config mastera (public_html/wp-config.php, kopia w podkatalogu)
# nie dopuszcza importu bazy mastera. Manifest nie nadpisuje tara.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }

fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL ${name}: got=[${got}] want=[${want}]"
    fail=1
    return
  fi
  echo "OK   ${name}"
}

# shellcheck disable=SC1091
source commands/backup/list.sh
# shellcheck disable=SC1091
source commands/backup/restore.sh

hm_extract_db_from_file() {
  local file="$1" kind="$2" line
  [[ -f "${file}" && "${kind}" == "wp" ]] || return 0
  line="$(sed -n "s/.*DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p" "${file}" | head -1)"
  [[ -n "${line}" ]] && printf '%s\twp-config\n' "${line}"
}
hm_resolve_site_paths() { return 1; }
PANEL=cyberpanel
hm_mysql_exec() {
  local sql="$*"
  if [[ "${sql}" == *childdomains* ]]; then
    if [[ "${sql}" == *child.alpha.test* && "${sql}" == *alpha.test* ]]; then
      printf '1'
    fi
    return 0
  fi
  if [[ "${sql}" == *databases_databases* ]]; then
    if [[ "${sql}" == *alpha_wp* || "${sql}" == *child_db* || "${sql}" == *alpha_extra* ]]; then
      printf 'alpha.test'
    fi
    return 0
  fi
  return 0
}

base="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-childsnap.XXXXXX")"
trap 'rm -rf "${base}"' EXIT

# Stary tar HOME: config mastera + child w public_html/<child> + zagnieżdżona kopia.
home="${base}/home"
mkdir -p "${home}/public_html/child.alpha.test/old-copy"
printf "%s\n" "<?php define('DB_NAME', 'alpha_wp');" > "${home}/public_html/wp-config.php"
printf "%s\n" "<?php define('DB_NAME', 'child_db');" > "${home}/public_html/child.alpha.test/wp-config.php"
printf "%s\n" "<?php define('DB_NAME', 'alpha_extra');" > "${home}/public_html/child.alpha.test/old-copy/wp-config.php"
snap="${base}/snap-home"
mkdir -p "${snap}"
tar -C "${home}" -czf "${snap}/files.tar.gz" .
printf '%s\n' '{"databases_from_site_config":["alpha_wp","alpha_extra"]}' > "${snap}/manifest.json"

got="$(hm_backup_snap_site_config_dbs "${snap}" "child.alpha.test" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
assert_eq "home-tar-only-child-db" "${got}" "child_db"

if hm_backup_db_belongs_to_other_domain alpha_wp child.alpha.test "${snap}"; then
  echo "OK   refuse-alpha_wp"
else
  echo "FAIL refuse-alpha_wp (dopuszczona)"
  fail=1
fi
if hm_backup_db_belongs_to_other_domain alpha_extra child.alpha.test "${snap}"; then
  echo "OK   refuse-alpha_extra"
else
  echo "FAIL refuse-alpha_extra (dopuszczona)"
  fail=1
fi
if hm_backup_db_belongs_to_other_domain child_db child.alpha.test "${snap}"; then
  echo "FAIL allow-child_db (odmowa)"
  fail=1
else
  echo "OK   allow-child_db"
fi

# Nowy tar = sam docroot childa; zagnieżdżony wp-config nie liczy się.
doc="${base}/doc"
mkdir -p "${doc}/vendor/pkg"
printf "%s\n" "<?php define('DB_NAME', 'child_db');" > "${doc}/wp-config.php"
printf "%s\n" "<?php define('DB_NAME', 'alpha_wp');" > "${doc}/vendor/pkg/wp-config.php"
snap2="${base}/snap-doc"
mkdir -p "${snap2}"
tar -C "${doc}" -czf "${snap2}/files.tar.gz" .
got="$(hm_backup_snap_site_config_dbs "${snap2}" "child.alpha.test" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
assert_eq "docroot-tar-only-child-db" "${got}" "child_db"

# Tar bez configu + spreparowany manifest → brak wyjątku.
statdir="${base}/static"
mkdir -p "${statdir}" "${base}/snap-empty"
printf '%s\n' 'hello' > "${statdir}/index.html"
tar -C "${statdir}" -czf "${base}/snap-empty/files.tar.gz" .
printf '%s\n' '{"databases_from_site_config":["alpha_wp"]}' > "${base}/snap-empty/manifest.json"
got="$(hm_backup_snap_site_config_dbs "${base}/snap-empty" "child.alpha.test" | tr -d '[:space:]')"
assert_eq "tar-without-config-ignores-manifest" "${got}" ""
if hm_backup_db_belongs_to_other_domain alpha_wp child.alpha.test "${base}/snap-empty"; then
  echo "OK   refuse-forged-manifest"
else
  echo "FAIL refuse-forged-manifest (dopuszczona)"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
