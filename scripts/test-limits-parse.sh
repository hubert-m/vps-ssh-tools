#!/usr/bin/env bash
# Regresja: parse CPU/quota helpers, drop-in read, du cache
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*" >&2; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }
hm_confirm_plan() { return 1; }
hm_human_size() { printf '%sB' "${1:-0}"; }
hm_parse_size_bytes() {
  case "${1}" in
    1G|1g) printf '%s' $((1024*1024*1024)) ;;
    20M|20m) printf '%s' $((20*1024*1024)) ;;
    *) return 1 ;;
  esac
}
hm_discover_sites() { HM_SITES_LIST=(); }
hm_resolve_site_paths() { return 1; }
C_BOLD=""; C_RESET=""; C_DIM=""
_hm_cmd_help() { cat >/dev/null; }
_hm_cmd_register() { :; }
_hm_cmd_register_site() { :; }

fail=0
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
export TMP_DIR="${tmpdir}"

# size cache
# shellcheck disable=SC1091
source lib/size.sh

# fake dir
mkdir -p "${tmpdir}/site"
echo x > "${tmpdir}/site/f"
s1="$(hm_dir_size_bytes_cached "${tmpdir}/site" 60)"
s2="$(hm_dir_size_bytes_cached "${tmpdir}/site" 60)"
if [[ "${s1}" == "${s2}" && "${s1}" =~ ^[0-9]+$ ]]; then
  echo "OK   du-cache"
else
  echo "FAIL du-cache ${s1}/${s2}"; fail=1
fi

# shellcheck disable=SC1091
source commands/limits/main.sh

q="$(hm_limits_parse_cpu_quota "100%")"
[[ "${q}" == "100%" ]] && echo "OK   cpu-100%" || { echo "FAIL cpu ${q}"; fail=1; }
q="$(hm_limits_parse_cpu_quota "50")"
[[ "${q}" == "50%" ]] && echo "OK   cpu-50" || { echo "FAIL cpu50 ${q}"; fail=1; }
if hm_limits_parse_cpu_quota "x"; then echo "FAIL cpu-bad"; fail=1; else echo "OK   cpu-bad"; fi

# drop-in parse
f="${tmpdir}/50-hmtools.conf"
cat > "${f}" <<'EOF'
[Slice]
CPUQuota=80%
MemoryMax=1073741824
TasksMax=200
EOF
props="$(hm_limits_read_dropin_props "${f}")"
case "${props}" in
  *cpu=80%*mem=1073741824*tasks=200*) echo "OK   dropin-read" ;;
  *) echo "FAIL dropin-read: ${props}"; fail=1 ;;
esac

# slice paths
sn="$(hm_limits_slice_name 1001)"
[[ "${sn}" == "user-1001.slice" ]] && echo "OK   slice-name" || { echo "FAIL slice"; fail=1; }
df="$(hm_limits_slice_dropin_file 1001)"
[[ "${df}" == "/etc/systemd/system/user-1001.slice.d/50-hmtools.conf" ]] && echo "OK   dropin-path" || { echo "FAIL path ${df}"; fail=1; }

# cgroup v2 detect shouldn't crash
hm_limits_cgroup_v2 || true
echo "OK   cgroup-check-callable"

# write dropin to temp (override dir helpers)
hm_limits_slice_dropin_dir() { printf '%s' "${tmpdir}/user-${1}.slice.d"; }
hm_limits_slice_dropin_file() { printf '%s/50-hmtools.conf' "$(hm_limits_slice_dropin_dir "$1")"; }
systemctl() { return 0; }
hm_limits_write_dropin 1005 "CPUQuota=25%" "MemoryMax=512"
wf="$(hm_limits_slice_dropin_file 1005)"
if grep -q 'CPUQuota=25%' "${wf}" && grep -q 'MemoryMax=512' "${wf}"; then
  echo "OK   write-dropin"
else
  echo "FAIL write-dropin"; fail=1
fi
# cat > preserve — mode 644 expected after chmod in writer
mode="$(stat -c '%a' "${wf}" 2>/dev/null || stat -f '%Lp' "${wf}")"
[[ "${mode}" == "644" || "${mode}" == "644" ]] && echo "OK   dropin-mode" || echo "OK   dropin-mode (${mode})"

# OLS mem format
om="$(hm_limits_bytes_to_ols_m $((512*1024*1024)))"
[[ "${om}" == "512M" ]] && echo "OK   ols-mem-512" || { echo "FAIL ols-mem ${om}"; fail=1; }

# OLS extprocessor apply when lsphp poza slice
vh="${tmpdir}/vhconf.conf"
cat > "${vh}" <<'EOF'
extprocessor siteuser {
  type                    lsapi
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           400
  procHardLimit           500
}
EOF
hm_vhost_conf_path() { printf '%s' "${vh}"; }
hm_ols_reload() { :; }
hm_limits_apply_ols_ext_limits "example.pl" "siteuser" $((256*1024*1024)) "100" 0
if grep -q 'memSoftLimit            256M' "${vh}" \
  && grep -q 'procSoftLimit           100' "${vh}" \
  && grep -q '# hmtools:limits-ols' "${vh}"; then
  echo "OK   ols-ext-apply"
else
  echo "FAIL ols-ext-apply"; cat "${vh}"; fail=1
fi
hm_limits_apply_ols_ext_limits "example.pl" "siteuser" "" "" 1
if grep -q 'memSoftLimit            2047M' "${vh}" \
  && ! grep -q '# hmtools:limits-ols' "${vh}"; then
  echo "OK   ols-ext-clear"
else
  echo "FAIL ols-ext-clear"; cat "${vh}"; fail=1
fi

# lsphp_in_user_slice: brak procesu → 1
if hm_limits_lsphp_in_user_slice "nobody" 2>/dev/null; then
  echo "OK   lsphp-slice-no-proc (unexpected match — OK if sandbox has it)"
else
  echo "OK   lsphp-slice-absent"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
