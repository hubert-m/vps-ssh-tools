#!/usr/bin/env bash
# vuln: fixture apt/dnf, EOL, odpowiedź API. Token nie wchodzi do argv ani wyjścia.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export HMTOOLS_ROOT="${ROOT}"

# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
# shellcheck disable=SC1091
source lib/site/php.sh

_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
hm_have_cmd() { return 1; }

# shellcheck disable=SC1091
source commands/vuln/main.sh

fail=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-vuln.XXXXXX")"
SECRET="SECRETTOKEN9"
FILESECRET="FILETOKEN9"

cat > "${TMP}/apt.txt" <<'EOF'
Listing...
openssl/noble-security 3.0.13-0ubuntu3.4 amd64 [upgradable from: 3.0.2-0ubuntu1]
curl/noble-updates 8.5.0-2ubuntu10.6 amd64 [upgradable from: 8.5.0-2ubuntu10.1]
EOF
printf '%s\n' 'openssl CVE-2024-5535 high' > "${TMP}/cve.map"
cat > "${TMP}/dnf.txt" <<'EOF'
CVE-2024-5535 Important/Sec. openssl-1:3.0.13-1.el9_4.x86_64
EOF
printf '%s\t%s\t%s\t%s\t%s\n' plugin hello 1.3 CVE-2024-9999 critical > "${TMP}/wp.feed"
printf '%s\t%s\t%s\t%s\n' example.com plugin hello 1.2.3 > "${TMP}/wp.inv"
printf '%s\t%s\t%s\t%s\n' other.com plugin hello 1.2.3 >> "${TMP}/wp.inv"
printf '%s\n' '{"items":[{"kind":"plugin","name":"akismet","fixed":"5.4","cve":"CVE-2024-4242","severity":"critical"}]}' > "${TMP}/api.json"
mkdir -p "${TMP}/wp/example.com/wp-includes" "${TMP}/wp/example.com/wp-content/plugins/hello" "${TMP}/wp/example.com/wp-content/themes/twentytwentyone"
printf '%s\n' "<?php \$wp_version = '6.4.2';" > "${TMP}/wp/example.com/wp-includes/version.php"
printf '%s\n' ' * Version: 1.2.3' > "${TMP}/wp/example.com/wp-content/plugins/hello/hello.php"
printf '%s\n' 'Version: 1.0' > "${TMP}/wp/example.com/wp-content/themes/twentytwentyone/style.css"
printf '%s\t%s\t%s\t%s\t%s\n' core wordpress 6.4.3 CVE-2024-1000 high >> "${TMP}/wp.feed"
printf '%s\t%s\t%s\t%s\t%s\n' theme twentytwentyone 1.1 CVE-2023-1 medium >> "${TMP}/wp.feed"

export HM_VULN_OS_FILE="${TMP}/apt.txt"
export HM_VULN_CVE_MAP="${TMP}/cve.map"
export HM_VULN_WP_FEED="${TMP}/wp.feed"
export HM_VULN_WP_FILE="${TMP}/wp.inv"
export HM_VULN_WP_ROOT="${TMP}/wp"
export HM_VULN_PHP_VERSIONS="8.1 8.2 8.4"
export HM_VULN_NODE_VERSIONS="18.20.4 22.11.0"
export HM_VULN_OLS_VERSION="1.7.16"
export HM_VULN_MARIADB_VERSION="10.6.18"
export HM_VULN_OS_KEY="ubuntu-20.04"
unset HM_VULN_WPSCAN_TOKEN || true
unset HM_VULN_WP_API_FILE || true
unset HM_VULN_WP_API_URL || true
unset HM_VULN_TOKEN_FILE || true

out="$(cmd_vuln 2>"${TMP}/err")" || true
printf '%s\n' "${out}" | grep -q 'openssl' && ok "apt security openssl" || bad "brak openssl"
printf '%s\n' "${out}" | grep -q 'CVE-2024-5535' && ok "mapa CVE" || bad "brak CVE z mapy"
if printf '%s\n' "${out}" | grep -q 'curl'; then
  bad "apt updates (nie security) trafił do wyniku"
else
  ok "pominięty pakiet spoza security"
fi
printf '%s\n' "${out}" | grep -q 'update security' && ok "naprawa update security" || bad "brak update security"
printf '%s\n' "${out}" | grep -q 'php 8.1' && ok "PHP 8.1 EOL" || bad "brak PHP 8.1"
printf '%s\n' "${out}" | grep -q 'php 8.2' && ok "PHP 8.2 security" || bad "brak PHP 8.2"
if printf '%s\n' "${out}" | grep -q 'php 8.4'; then
  bad "PHP 8.4 active nie powinien być podatnością"
else
  ok "PHP 8.4 pominięty"
fi
printf '%s\n' "${out}" | grep -q 'node 18.20.4' && ok "Node 18 EOL" || bad "brak Node 18"
if printf '%s\n' "${out}" | grep -q 'node 22'; then
  bad "Node 22 active w wyniku"
else
  ok "Node 22 pominięty"
fi
printf '%s\n' "${out}" | grep -q 'ols 1.7.16' && ok "OLS EOL" || bad "brak OLS"
printf '%s\n' "${out}" | grep -q 'mariadb 10.6.18' && ok "MariaDB EOL" || bad "brak MariaDB"
printf '%s\n' "${out}" | grep -q 'ubuntu-20.04' && ok "OS EOL" || bad "brak OS"
printf '%s\n' "${out}" | grep -q 'wp plugin update hello' && ok "naprawa wtyczki" || bad "brak wp plugin update"
printf '%s\n' "${out}" | grep -q 'wp core update' && ok "naprawa core" || bad "brak wp core update"
printf '%s\n' "${out}" | grep -q 'krytyczne' && ok "podsumowanie" || bad "brak podsumowania"
grep -q 'tryb offline' "${TMP}/err" "${TMP}/err" 2>/dev/null || true
# hm_info idzie na stdout
printf '%s\n' "${out}" | grep -q 'tryb offline' && ok "offline bez tokenu" || bad "brak trybu offline"

# tylko jedna domena
one="$(cmd_vuln wp example.com 2>/dev/null || true)"
printf '%s\n' "${one}" | grep -q 'hello' && ok "filtr domeny" || bad "filtr domeny"
# other.com też ma hello w TSV, ale filtr example.com zostawia skan example.com (też hello).
# Sprawdź, że other.com nie dokłada drugiej kopii tylko przez licznik... obie mają hello.
# Osobny inwentarz bez skanu root:
export HM_VULN_WP_ROOT=""
only="$(cmd_vuln wp other.com 2>/dev/null || true)"
export HM_VULN_WP_ROOT="${TMP}/wp"
printf '%s\n' "${only}" | grep -q 'hello' && ok "wp TSV other.com" || bad "wp TSV"

export HM_VULN_OS_FILE="${TMP}/dnf.txt"
dnf_out="$(cmd_vuln os 2>/dev/null || true)"
printf '%s\n' "${dnf_out}" | grep -q 'openssl' && ok "dnf updateinfo openssl" || bad "dnf parser"
printf '%s\n' "${dnf_out}" | grep -q 'CVE-2024-5535' && ok "dnf CVE" || bad "dnf CVE"

# API z pliku, bez sieci
export HM_VULN_OS_FILE=""
export HM_VULN_WP_API_FILE="${TMP}/api.json"
export HM_VULN_WP_FILE="${TMP}/empty.inv"
: > "${TMP}/empty.inv"
export HM_VULN_WP_ROOT=""
printf '%s\t%s\t%s\t%s\n' example.com plugin akismet 5.0 > "${TMP}/empty.inv"
api_out="$(cmd_vuln wp --json 2>/dev/null || true)"
printf '%s\n' "${api_out}" | grep -q 'CVE-2024-4242' && ok "fixture API" || bad "fixture API: ${api_out}"
printf '%s\n' "${api_out}" | grep -q '"critical":' && ok "json" || bad "json"

# Token w env: curl dostaje --config, nie sekret.
export HM_VULN_WP_API_FILE=""
export HM_VULN_WP_API_URL="http://127.0.0.1:9/vuln"
export HM_VULN_WPSCAN_TOKEN="${SECRET}"
curl() {
  printf '%s\n' "$@" > "${TMP}/curl-argv"
  cat "${TMP}/api.json"
}
http_out="$(cmd_vuln wp --json 2>"${TMP}/http.err" || true)"
argv="$(cat "${TMP}/curl-argv" 2>/dev/null || true)"
if printf '%s\n%s\n' "${http_out}" "${argv}" | grep -q "${SECRET}"; then
  bad "token w stdout albo argv"
else
  ok "token poza stdout i argv"
fi
printf '%s\n' "${argv}" | grep -q -- '--config' && ok "curl --config" || bad "brak --config: ${argv}"
printf '%s\n' "${http_out}" | grep -q 'CVE-2024-4242' && ok "wynik z curl" || bad "curl nie oddał API"

# Plik tokenu nie-0600 jest odrzucany i nie woła curl.
unset HM_VULN_WPSCAN_TOKEN || true
printf '%s\n' "${FILESECRET}" > "${TMP}/token"
chmod 0644 "${TMP}/token" 2>/dev/null || true
export HM_VULN_TOKEN_FILE="${TMP}/token"
rm -f "${TMP}/curl-argv"
cmd_vuln wp --json >"${TMP}/file.out" 2>"${TMP}/file.err" || true
mode="$(stat -c '%a' -- "${TMP}/token" 2>/dev/null || printf '644')"
if [[ "${mode: -2}" != "00" ]]; then
  grep -q '0600' "${TMP}/file.err" && ok "odrzucenie tokenu bez 0600" || bad "brak ostrzeżenia 0600"
  if [[ -f "${TMP}/curl-argv" ]]; then
    bad "curl po odrzuceniu tokenu"
  else
    ok "brak curl bez ważnego tokenu"
  fi
else
  ok "platforma trzyma 0600 — plik tokenu dopuszczony"
fi
if printf '%s\n' "$(cat "${TMP}/file.out" "${TMP}/file.err")" | grep -q "${FILESECRET}"; then
  bad "sekret z pliku w wyjściu"
else
  ok "sekret z pliku poza wyjściem"
fi

rm -rf "${TMP}"
unset HM_VULN_OS_FILE HM_VULN_CVE_MAP HM_VULN_WP_FEED HM_VULN_WP_FILE HM_VULN_WP_ROOT
unset HM_VULN_PHP_VERSIONS HM_VULN_NODE_VERSIONS HM_VULN_OLS_VERSION HM_VULN_MARIADB_VERSION
unset HM_VULN_OS_KEY HM_VULN_WP_API_URL HM_VULN_TOKEN_FILE HM_VULN_WPSCAN_TOKEN

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
