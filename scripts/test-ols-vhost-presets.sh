#!/usr/bin/env bash
# Regresja: vhost strip/append (idempotencja), zapis cat> (mode), sekcje, backup stamp
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_run_on_tty() { "$@"; }
hm_confirm_plan() { return 1; } # nigdy nie mutuj w teście apply
hm_ols_reload_soft() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register_site() { :; }
hm_vhost_conf_path() { echo "${TEST_VHOST_CONF:-}"; [[ -f "${TEST_VHOST_CONF:-}" ]]; }

# Minimalny fragment vhost.sh — source całego pliku (po stubach)
# shellcheck disable=SC1091
source commands/ols/vhost.sh

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

conf="${tmpdir}/vhconf.conf"
cat > "${conf}" <<'EOF'
docRoot                   $VH_ROOT/public_html
vhDomain                  example.pl
rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
extprocessor lsphp {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp.sock
}
context / {
  type                    NULL
}
module cache {
  ls_enabled              1
  expireInSeconds         600
}
EOF
chmod 640 "${conf}"
mode_before="$(stat -c '%a' "${conf}" 2>/dev/null || stat -f '%Lp' "${conf}")"

# --- strip / append idempotent ---
tmp1="$(mktemp)"
hm_ols_vhost_strip_block "${conf}" "rewrite-https" "${tmp1}"
{
  cat "${tmp1}"
  echo "# hmtools:rewrite-https BEGIN"
  echo "rewrite { enable 1 }"
  echo "# hmtools:rewrite-https END"
} > "${tmp1}.a"
cp "${tmp1}.a" "${tmp1}"

# drugi raz strip+append = jeden blok
hm_ols_vhost_strip_block "${tmp1}" "rewrite-https" "${tmp1}.b"
{
  cat "${tmp1}.b"
  echo "# hmtools:rewrite-https BEGIN"
  echo "rewrite { enable 1 }"
  echo "# hmtools:rewrite-https END"
} > "${tmp1}.c"

c1="$(grep -c 'hmtools:rewrite-https BEGIN' "${tmp1}.c" || true)"
if [[ "${c1}" -eq 1 ]]; then
  echo "OK   preset-idempotent"
else
  echo "FAIL preset-idempotent count=${c1}"
  fail=1
fi

# strip usuwa
hm_ols_vhost_strip_block "${tmp1}.c" "rewrite-https" "${tmp1}.d"
if grep -q 'hmtools:rewrite-https' "${tmp1}.d"; then
  echo "FAIL preset-strip"
  fail=1
else
  echo "OK   preset-strip"
fi

# --- cat > zachowuje mode ---
TEST_VHOST_CONF="${conf}"
tmpw="$(mktemp)"
cp "${conf}" "${tmpw}"
echo "# touch" >> "${tmpw}"
if hm_ols_vhost_write "${conf}" "${tmpw}"; then
  mode_after="$(stat -c '%a' "${conf}" 2>/dev/null || stat -f '%Lp' "${conf}")"
  if [[ "${mode_after}" == "${mode_before}" ]]; then
    echo "OK   write-preserves-mode (${mode_before})"
  else
    echo "FAIL write-preserves-mode ${mode_before}→${mode_after}"
    fail=1
  fi
else
  echo "FAIL write"
  fail=1
fi

# --- backup stamp + prune ---
OLS_ROOT="${tmpdir}"
for i in 1 2 3; do
  sleep 0.05 2>/dev/null || true
  hm_ols_vhost_backup "${conf}" "2026010100000${i}" >/dev/null
done
# ręcznie więcej niż 10
for i in $(seq -w 4 12); do
  cp -a "${conf}" "${conf}.hmtools.202601010000${i}"
done
hm_ols_vhost_backup_prune "${conf}" 10
cnt="$(hm_ols_vhost_backup_list "${conf}" | wc -l | tr -d ' ')"
if [[ "${cnt}" -le 10 ]]; then
  echo "OK   backup-prune (<=10, got ${cnt})"
else
  echo "FAIL backup-prune got ${cnt}"
  fail=1
fi

# --- section show ---
sec="$(hm_ols_vhost_show_section "${conf}" rewrite)"
if printf '%s\n' "${sec}" | grep -q 'autoLoadHtaccess'; then
  echo "OK   section-rewrite"
else
  echo "FAIL section-rewrite: ${sec}"
  fail=1
fi
sec="$(hm_ols_vhost_show_section "${conf}" module)"
if printf '%s\n' "${sec}" | grep -qi 'expireInSeconds'; then
  echo "OK   section-module"
else
  echo "FAIL section-module"
  fail=1
fi

# --- has_block ---
echo "# hmtools:headers-security BEGIN" >> "${conf}"
echo "extraHeaders x" >> "${conf}"
echo "# hmtools:headers-security END" >> "${conf}"
if hm_ols_vhost_has_block "${conf}" "headers-security"; then
  echo "OK   has-block"
else
  echo "FAIL has-block"
  fail=1
fi

# --- apply cancel (confirm false) nie zmienia ---
sum1="$(cksum "${conf}" | awk '{print $1}')"
tmpa="$(mktemp)"
echo "broken {" > "${tmpa}"
HM_SITE_DOMAIN="example.pl"
# apply returns 0 on cancel
hm_ols_vhost_apply_tmp "example.pl" "${conf}" "${tmpa}" "test" >/dev/null 2>&1 || true
sum2="$(cksum "${conf}" | awk '{print $1}')"
if [[ "${sum1}" == "${sum2}" ]]; then
  echo "OK   apply-cancel-no-write"
else
  echo "FAIL apply-cancel-no-write"
  fail=1
fi
rm -f "${tmp1}" "${tmp1}.a" "${tmp1}.b" "${tmp1}.c" "${tmp1}.d" "${tmpw}" "${tmpa}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
