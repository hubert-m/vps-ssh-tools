#!/usr/bin/env bash
# Testy: hm_ols_remove_domain_from_conf + hm_is_safe_sites_root_config (case virtualhost / SITES_ROOT)
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

# Minimalne stuby UI używane przez delete.sh (nie ładujemy całego hmtools)
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }

# shellcheck disable=SC1091
source commands/delete-site/delete.sh

fail=0
assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    echo "OK   ${name}"
  else
    echo "FAIL ${name}"
    fail=1
  fi
}
assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL ${name}"
    fail=1
  else
    echo "OK   ${name}"
  fi
}

# --- SITES_ROOT config ---
assert_fail "deny SITES_ROOT=/" hm_is_safe_sites_root_config "/"
assert_fail "deny SITES_ROOT=/usr" hm_is_safe_sites_root_config "/usr"
assert_fail "deny SITES_ROOT=/etc" hm_is_safe_sites_root_config "/etc"
assert_fail "deny SITES_ROOT=/var" hm_is_safe_sites_root_config "/var"
assert_fail "deny SITES_ROOT=/opt" hm_is_safe_sites_root_config "/opt"
assert_fail "deny SITES_ROOT=/srv" hm_is_safe_sites_root_config "/srv"
assert_ok "allow SITES_ROOT=/srv/www" hm_is_safe_sites_root_config "/srv/www"
assert_ok "allow SITES_ROOT=/var/www" hm_is_safe_sites_root_config "/var/www"

# site root under dangerous SITES_ROOT must not pass via SITES_ROOT branch
SITES_ROOT=/usr
assert_fail "deny site under SITES_ROOT=/usr" hm_is_safe_site_root_to_delete "/usr/local/foo"
SITES_ROOT=/srv/www
assert_ok "allow site under safe SITES_ROOT" hm_is_safe_site_root_to_delete "/srv/www/example.com"
assert_fail "deny bare SITES_ROOT itself" hm_is_safe_site_root_to_delete "/srv/www"
unset SITES_ROOT

# --- OLS remove: virtualhost (lower) + virtualHost (camel) ---
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
conf="${tmpdir}/httpd_config.conf"
cat > "${conf}" <<'EOF'
listener Default {
  map a.pl *
  map b.pl *
  map keep.pl *
}
virtualhost a.pl {
  vhRoot /home/a.pl
}
virtualHost b.pl{
  vhRoot /home/b.pl
}
virtualHost keep.pl {
  vhRoot /home/keep.pl
}
EOF

OLS_CONF="${conf}"
hm_ols_remove_domain_from_conf "a.pl"
hm_ols_remove_domain_from_conf "b.pl"

if grep -Eqi 'virtualhost[[:space:]]+a\.pl' "${conf}"; then
  echo "FAIL lower virtualhost a.pl still present"
  fail=1
else
  echo "OK   removed virtualhost a.pl (lowercase)"
fi
if grep -Eqi 'virtualhost[[:space:]]+b\.pl' "${conf}"; then
  echo "FAIL camel virtualHost b.pl still present"
  fail=1
else
  echo "OK   removed virtualHost b.pl (camelCase)"
fi
if ! grep -Eqi 'virtualhost[[:space:]]+keep\.pl' "${conf}"; then
  echo "FAIL keep.pl block missing"
  fail=1
else
  echo "OK   kept unrelated keep.pl"
fi
if grep -Eq '^[[:space:]]*map[[:space:]]+a\.pl' "${conf}"; then
  echo "FAIL map a.pl still present"
  fail=1
else
  echo "OK   removed map a.pl"
fi
if grep -Eq '^[[:space:]]*map[[:space:]]+b\.pl' "${conf}"; then
  echo "FAIL map b.pl still present"
  fail=1
else
  echo "OK   removed map b.pl"
fi
if ! grep -Eq '^[[:space:]]*map[[:space:]]+keep\.pl' "${conf}"; then
  echo "FAIL map keep.pl missing"
  fail=1
else
  echo "OK   kept map keep.pl"
fi

# --- archive snippet extracts both casings ---
# shellcheck disable=SC1091
source commands/backup/archive.sh
cat > "${conf}" <<'EOF'
virtualhost low.pl {
  vhRoot /home/low.pl
}
virtualHost cam.pl {
  vhRoot /home/cam.pl
}
EOF
OLS_CONF="${conf}"
snip="${tmpdir}/snip.conf"
hm_archive_write_ols_snippet "low.pl" "${snip}"
if ! grep -Eqi 'virtualhost[[:space:]]+low\.pl' "${snip}"; then
  echo "FAIL archive snippet missing lowercase low.pl"
  fail=1
else
  echo "OK   archive snippet has virtualhost low.pl"
fi
hm_archive_write_ols_snippet "cam.pl" "${snip}"
if ! grep -Eqi 'virtualhost[[:space:]]+cam\.pl' "${snip}"; then
  echo "FAIL archive snippet missing camel cam.pl"
  fail=1
else
  echo "OK   archive snippet has virtualHost cam.pl"
fi

# --- apply snippet (restore path): lowercase virtualhost + map into listeners ---
# shellcheck disable=SC1091
source commands/backup/restore.sh
cat > "${conf}" <<'EOF'
listener Default {
  address *:80
  map keep.pl *
}
virtualHost keep.pl {
  vhRoot /home/keep.pl
}
EOF
snip="${tmpdir}/restore-snip.conf"
cat > "${snip}" <<'EOF'
virtualhost rest.pl {
  vhRoot /home/rest.pl
}
map rest.pl *
EOF
OLS_CONF="${conf}"
hm_ols_apply_httpd_snippet "rest.pl" "${snip}"
if ! grep -Eqi 'virtualhost[[:space:]]+rest\.pl' "${conf}"; then
  echo "FAIL apply snippet: virtualhost rest.pl missing"
  fail=1
else
  echo "OK   apply snippet: virtualhost rest.pl"
fi
if ! grep -Eq 'map[[:space:]]+rest\.pl' "${conf}"; then
  echo "FAIL apply snippet: map rest.pl missing in listener"
  fail=1
else
  echo "OK   apply snippet: map rest.pl in listener"
fi
if ! grep -Eqi 'virtualhost[[:space:]]+keep\.pl' "${conf}"; then
  echo "FAIL apply snippet: keep.pl lost"
  fail=1
else
  echo "OK   apply snippet: keep.pl retained"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
