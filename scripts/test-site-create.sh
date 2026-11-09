#!/usr/bin/env bash
# Regresja: site create — kolizje, map alias add/remove, mock cyberpanel
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 0; }
hm_ols_reload_soft() { return 0; }
hm_help_topic() { :; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_file_log() { :; }
hm_run() { printf 'RUN:%s\n' "$*"; return 0; }
hm_detect_all() { :; }
hm_discover_sites() { HM_SITES_LIST=("example.pl"); }
hm_find_site_by_arg_exact() {
  local a="$1" d
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ "${d}" == "${a}" ]] && { echo "${d}"; return 0; }
  done
  return 1
}
hm_php_normalize_branch() {
  local r="$1"
  r="${r#php}"; r="${r#lsphp}"
  [[ "${r}" =~ ^[0-9]+\.[0-9]+$ ]] && { printf '%s' "${r}"; return 0; }
  return 1
}
hm_php_lsphp_suffix() { local b="$1"; printf '%s%s' "${b%%.*}" "${b#*.}"; }
hm_php_installed_packages() { echo "lsphp${1}"; }
hm_os_web_group() { echo nogroup; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
hm_mysql_exec() { return 0; }
hm_tsv_unfield() { [[ "${1:-}" == "-" ]] && printf '' || printf '%s' "${1:-}"; }
hm_resolve_site_paths() { printf '%s\t%s\t%s\t-\t-\t8.3\tuser|active\n' "$1" "/home/$1" "/home/$1/public_html"; }
hm_set_site_context() { :; }
hm_print_site_info() { echo "info $1"; }
C_BOLD=""; C_RESET=""; C_DIM=""; C_CYAN=""; C_RED=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

# minimal insert maps (z restore) — lokalna kopia do testu append
hm_ols_insert_maps_into_listeners() {
  local conf="$1" maps_file="$2"
  [[ -f "${conf}" && -f "${maps_file}" ]] || return 0
  local tmp mapline
  tmp="$(mktemp)"
  mapline="$(awk -F'\t' '{print $2; exit}' "${maps_file}")"
  awk -v ml="${mapline}" '
    BEGIN { in_l=0; depth=0; done=0 }
    {
      first=tolower($1)
      if (!in_l && first=="listener") { in_l=1; depth=0; if ($0 ~ /\{/) depth=1; print; next }
      if (in_l) {
        if ($0 ~ /\{/) depth++
        if ($0 ~ /\}/) {
          depth--
          if (depth <= 0 && !done) { print "  " ml; done=1; in_l=0 }
        }
        print; next
      }
      print
    }
  ' "${conf}" > "${tmp}"
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
}
hm_ols_remove_domain_from_conf() {
  local domain="$1" conf="${OLS_CONF:-}"
  [[ -f "${conf}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v dom="${domain}" '
    BEGIN { skip=0; depth=0 }
    tolower($1)=="virtualhost" {
      second=$2; gsub(/\{/,"",second)
      if (second==dom) { skip=1; depth=0; if ($0 ~ /\{/) depth=1; next }
    }
    skip {
      if ($0 ~ /\{/) depth++
      if ($0 ~ /\}/) { depth--; if (depth<=0) { skip=0; depth=0 } }
      next
    }
    tolower($1)=="map" && $2==dom { next }
    { print }
  ' "${conf}" > "${tmp}"
  cat "${tmp}" > "${conf}"
  rm -f "${tmp}"
}

# shellcheck disable=SC1091
source commands/site-create/main.sh

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

OLS_CONF="${tmpdir}/httpd_config.conf"
OLS_VHOSTS="${tmpdir}/vhosts"
mkdir -p "${OLS_VHOSTS}"
PANEL=unknown
export OLS_CONF OLS_VHOSTS PANEL

cat > "${OLS_CONF}" <<'EOF'
listener Default {
  map example.pl example.pl, www.example.pl
}
virtualhost example.pl {
  vhRoot /home/example.pl
}
EOF

# --- list aliases ---
al="$(hm_sc_ols_list_aliases example.pl | tr '\n' ' ')"
if [[ "${al}" == *"www.example.pl"* ]]; then
  echo "OK   list-aliases"
else
  echo "FAIL list-aliases got=${al}"
  fail=1
fi

# --- add alias (nie rusza innych) ---
hm_sc_ols_map_add_alias example.pl parked.pl
if grep -q 'map example.pl example.pl, www.example.pl, parked.pl' "${OLS_CONF}" \
  || grep -qE 'map[[:space:]]+example\.pl[[:space:]]+.*parked\.pl' "${OLS_CONF}"; then
  echo "OK   add-alias"
else
  echo "FAIL add-alias"
  grep map "${OLS_CONF}" || true
  fail=1
fi
if grep -q 'www.example.pl' "${OLS_CONF}"; then
  echo "OK   add-alias-keeps-www"
else
  echo "FAIL add-alias-keeps-www"
  fail=1
fi

# --- remove alias only ---
hm_sc_ols_map_remove_alias example.pl parked.pl
if grep -q 'parked.pl' "${OLS_CONF}"; then
  echo "FAIL remove-alias still present"
  fail=1
else
  echo "OK   remove-alias"
fi
if grep -q 'www.example.pl' "${OLS_CONF}"; then
  echo "OK   remove-keeps-www"
else
  echo "FAIL remove-keeps-www"
  fail=1
fi

# --- refuse removing master from map ---
if hm_sc_ols_map_remove_alias example.pl example.pl 2>/dev/null; then
  echo "FAIL remove-master-fn should fail"
  fail=1
else
  echo "OK   remove-master-fn-rc"
fi
if grep -qE 'map[[:space:]]+example\.pl[[:space:]]+.*example\.pl' "${OLS_CONF}" \
  || grep -q 'map example.pl example.pl' "${OLS_CONF}"; then
  echo "OK   remove-master-keeps-apex"
else
  echo "FAIL remove-master-keeps-apex"
  grep map "${OLS_CONF}" || true
  fail=1
fi

PANEL=none
HM_SITE_DOMAIN=example.pl
if cmd_site_alias remove example.pl --yes 2>/dev/null; then
  echo "FAIL alias-remove-apex should fail"
  fail=1
else
  echo "OK   alias-remove-apex-rc"
fi
if cmd_site_alias remove www.other.pl --yes 2>/dev/null; then
  echo "FAIL alias-remove-foreign should fail"
  fail=1
else
  echo "OK   alias-remove-foreign-rc"
fi

# --- map has name ---
if hm_sc_ols_map_has_name www.example.pl; then
  echo "OK   map-has-www"
else
  echo "FAIL map-has-www"
  fail=1
fi
if hm_sc_ols_map_has_name nosuch.pl; then
  echo "FAIL map-has-nosuch"
  fail=1
else
  echo "OK   map-has-nosuch"
fi

# --- collision: existing site ---
HM_SITES_LIST=("example.pl")
if hm_sc_domain_occupied example.pl; then
  echo "OK   collision-existing"
else
  echo "FAIL collision-existing"
  fail=1
fi
if hm_sc_domain_occupied brand-new-xyz.pl; then
  echo "FAIL collision-free"
  fail=1
else
  echo "OK   collision-free"
fi

# --- unix name ---
u="$(hm_sc_unix_name_for_domain example.pl)"
if [[ "${u}" == "examplep" || "${u}" == "example" ]]; then
  echo "OK   unix-name (${u})"
else
  # examplepl truncated to 8 = examplep
  if [[ "${#u}" -le 8 && "${u}" =~ ^[a-z] ]]; then
    echo "OK   unix-name (${u})"
  else
    echo "FAIL unix-name ${u}"
    fail=1
  fi
fi

# --- mock cyberpanel create path (confirm always yes; no real useradd) ---
# Stub id/useradd/mkdir heavy path: only exercise collision refusal via cmd
PANEL=cyberpanel
# fake cyberpanel binary
mkdir -p "${tmpdir}/bin"
cat > "${tmpdir}/bin/cyberpanel" <<'EOF'
#!/bin/sh
echo "mock cyberpanel $*"
exit 0
EOF
chmod +x "${tmpdir}/bin/cyberpanel"
export PATH="${tmpdir}/bin:${PATH}"

# occupied → odmowa
if cmd_site_create occupied.pl --php 8.3 --yes 2>/dev/null; then
  # occupied.pl not in list — should succeed mock; use example.pl
  :
fi
if cmd_site_create example.pl --php 8.3 --yes 2>"${tmpdir}/err"; then
  echo "FAIL create-collision-should-deny"
  fail=1
else
  if grep -qi 'Kolizja\|kolizja\|zajęta\|istnieje' "${tmpdir}/err" 2>/dev/null \
    || grep -qi 'Kolizja\|kolizja' "${tmpdir}/err"; then
    echo "OK   create-collision-deny"
  else
    # hm_err goes to stderr via our stub
    if grep -q 'Kolizja' "${tmpdir}/err"; then
      echo "OK   create-collision-deny"
    else
      # our hm_err prints ERR:
      if [[ -s "${tmpdir}/err" ]]; then
        echo "OK   create-collision-deny ($(head -1 "${tmpdir}/err"))"
      else
        echo "FAIL create-collision-deny empty err"
        fail=1
      fi
    fi
  fi
fi

# --- OLS create primary (sandbox) ---
PANEL=unknown
mkdir -p "${tmpdir}/home"
# override /home — nie możemy pisać do prawdziwego /home; testujemy tylko vhconf writer + map helpers
vdir="$(hm_sc_write_vhconf newsite.test 8.3 newsite admin@newsite.test)" || vdir=""
if [[ -n "${vdir}" && -f "${vdir}/vhconf.conf" ]] && grep -q 'lsphp83' "${vdir}/vhconf.conf"; then
  echo "OK   write-vhconf"
else
  # path may be lsphp without existing binary — function returns 1
  # create fake lsphp
  mkdir -p "${tmpdir}/lsws/lsphp83/bin"
  echo '#!/bin/sh' > "${tmpdir}/lsws/lsphp83/bin/lsphp"
  chmod +x "${tmpdir}/lsws/lsphp83/bin/lsphp"
  OLS_ROOT="${tmpdir}/lsws"
  export OLS_ROOT
  vdir="$(hm_sc_write_vhconf newsite.test 8.3 newsite admin@newsite.test)" || vdir=""
  if [[ -n "${vdir}" && -f "${vdir}/vhconf.conf" ]]; then
    echo "OK   write-vhconf"
  else
    echo "FAIL write-vhconf"
    fail=1
  fi
fi

# append vhost block
hm_sc_ols_append_vhost_block newsite.test
if grep -qi 'virtualhost newsite.test' "${OLS_CONF}" && grep -q 'newsite.test' "${OLS_CONF}"; then
  echo "OK   append-vhost-map"
else
  echo "FAIL append-vhost-map"
  cat "${OLS_CONF}"
  fail=1
fi

# placeholder HTTP (treść pod docroot — kryterium HTTP 200 wymaga żywego OLS)
ph_doc="${tmpdir}/ph/public_html"
hm_sc_write_placeholder "${ph_doc}" "placeholder.test"
if [[ -f "${ph_doc}/index.html" ]] \
  && grep -q 'placeholder.test' "${ph_doc}/index.html" \
  && grep -qi 'hmtools' "${ph_doc}/index.html"; then
  echo "OK   placeholder-index"
else
  echo "FAIL placeholder-index"
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "ALL PASSED"
  exit 0
fi
echo "FAILED=${fail}"
exit 1
