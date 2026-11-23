#!/usr/bin/env bash
# safety: prune — partial+payload pod keep_min; błąd odczytu ⇒ pomiń domenę;
# type=archive nigdy auto-purge. Bez rclone/root (lokalny RCLONE_REMOTE).
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
# shellcheck disable=SC1091
source lib/rclone_drive.sh
# shellcheck disable=SC1091
source commands/backup/list.sh
# shellcheck disable=SC1091
source commands/backup/prune.sh

PASS=0
FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-prune-safety.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

REMOTE_ROOT="${TMP}/remote"
DOMAIN="shop.test"
mkdir -p "${REMOTE_ROOT}/${DOMAIN}"

export RCLONE_REMOTE="${REMOTE_ROOT}"
export BACKUP_ORPHAN_GRACE_HOURS=24

# --- (a) 3× partial z files.tar.gz, keep_min=3, days=0 → zero purge ---
STAMP_OLD1="20200101-120000"
STAMP_OLD2="20200102-120000"
STAMP_OLD3="20200103-120000"
for st in "${STAMP_OLD1}" "${STAMP_OLD2}" "${STAMP_OLD3}"; do
  d="${REMOTE_ROOT}/${DOMAIN}/${st}"
  mkdir -p "${d}"
  echo "payload" > "${d}/files.tar.gz"
  printf '%s\n' "{\"version\":1,\"type\":\"full\",\"status\":\"partial\",\"created_at\":\"${st:0:4}-${st:4:2}-${st:6:2}T12:00:00Z\"}" \
    > "${d}/manifest.json"
done

out="$(hm_backup_prune_scope "${DOMAIN}" 0 3 || true)"
if [[ -z "${out}" ]]; then
  pass "(a) partial+payload: keep_min=3 → brak purge"
else
  fail "(a) partial+payload: oczekiwano pustego, dostano: ${out}"
fi

# --- (b) błąd odczytu manifestu → return 1, nic nie kasuj ---
BROKEN_STAMP="20190101-120000"
bd="${REMOTE_ROOT}/${DOMAIN}/${BROKEN_STAMP}"
mkdir -p "${bd}"
echo "payload" > "${bd}/files.tar.gz"
printf '%s\n' '{"version":1,"type":"full","status":"ok"}' > "${bd}/manifest.json"

# symuluj rc=1 tylko dla tego stampu (rename oryginału)
eval "$(declare -f hm_backup_cat_manifest | sed '1s/hm_backup_cat_manifest/hm_backup_cat_manifest_orig/')"
hm_backup_cat_manifest() {
  local remote_base="$1"
  if [[ "${remote_base}" == *"/${BROKEN_STAMP}" ]]; then
    return 1
  fi
  hm_backup_cat_manifest_orig "${remote_base}"
}

set +e
out="$(hm_backup_prune_scope "${DOMAIN}" 0 1 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  pass "(b) błąd odczytu manifestu → rc≠0 (pomiń domenę)"
else
  fail "(b) oczekiwano rc≠0 przy błędzie cat, rc=${rc} out=${out}"
fi
for st in "${STAMP_OLD1}" "${STAMP_OLD2}" "${STAMP_OLD3}" "${BROKEN_STAMP}"; do
  if [[ ! -d "${REMOTE_ROOT}/${DOMAIN}/${st}" ]]; then
    fail "(b) katalog zniknął: ${st}"
  fi
done
[[ -d "${REMOTE_ROOT}/${DOMAIN}/${STAMP_OLD1}" ]] && pass "(b) katalogi nietknięte po błędzie odczytu"

# przywróć prawdziwy cat
eval "$(declare -f hm_backup_cat_manifest_orig | sed '1s/hm_backup_cat_manifest_orig/hm_backup_cat_manifest/')"

# --- (c) type=archive nigdy nie purge ---
rm -rf "${REMOTE_ROOT}/${DOMAIN}"
mkdir -p "${REMOTE_ROOT}/${DOMAIN}"
ARCH_STAMP="20180101-120000"
ad="${REMOTE_ROOT}/${DOMAIN}/${ARCH_STAMP}"
mkdir -p "${ad}"
echo "payload" > "${ad}/files.tar.gz"
printf '%s\n' '{"version":1,"type":"archive","status":"ok","created_at":"2018-01-01T12:00:00Z"}' \
  > "${ad}/manifest.json"
FULL_STAMP="20180201-120000"
fd="${REMOTE_ROOT}/${DOMAIN}/${FULL_STAMP}"
mkdir -p "${fd}"
echo "payload" > "${fd}/files.tar.gz"
printf '%s\n' '{"version":1,"type":"full","status":"ok","created_at":"2018-02-01T12:00:00Z"}' \
  > "${fd}/manifest.json"

out="$(hm_backup_prune_scope "${DOMAIN}" 0 1 || true)"
if echo "${out}" | grep -q "${ARCH_STAMP}"; then
  fail "(c) archive trafił do purge: ${out}"
else
  pass "(c) type=archive nie jest kasowany"
fi
[[ -d "${ad}" ]] && pass "(c) katalog archive nadal istnieje" || fail "(c) katalog archive zniknął"

echo ""
echo "Wynik: ${PASS} pass, ${FAIL} fail"
[[ "${FAIL}" -eq 0 ]]
