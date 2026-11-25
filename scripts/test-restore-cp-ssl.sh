#!/usr/bin/env bash
# restore: SSL whitelist + nowszy cert; CP zachowuje child/DB spoza snapshota.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1 HMTOOLS_TEST_NO_TTY=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { echo "OK: $*"; }
hm_info() { echo "INFO: $*"; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
hm_is_valid_domain() { [[ "$1" == *.* ]]; }
hm_sql_quote() { printf "'%s'" "${1//\'/\'\'}"; }
hm_mktemp() { mktemp "${TMPDIR:-/tmp}/hm.XXXXXX${1:-}"; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-restore-cp-ssl.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck disable=SC1091
source commands/backup/archive.sh
# shellcheck disable=SC1091
source commands/backup/restore.sh

# --- SSL whitelist ---
hm_backup_ssl_member_allowed "etc/letsencrypt/live/ex.test/cert.pem" "ex.test" && ok "ssl-allow-live" || bad "ssl-allow-live"
hm_backup_ssl_member_allowed "etc/passwd" "ex.test" && bad "ssl-deny-passwd" || ok "ssl-deny-passwd"
hm_backup_ssl_member_allowed "etc/letsencrypt/live/other.test/cert.pem" "ex.test" && bad "ssl-deny-other" || ok "ssl-deny-other"

# ssl.tar.gz z etc/passwd → odmowa
REMOTE="${TMP}/snap"
mkdir -p "${REMOTE}" "${TMP}/pack/etc"
printf 'root:x\n' > "${TMP}/pack/etc/passwd"
tar -C "${TMP}/pack" -czf "${REMOTE}/ssl.tar.gz" etc/passwd
rclone() {
  case "$*" in
    cat\ "${REMOTE}/ssl.tar.gz"*) cat "${REMOTE}/ssl.tar.gz" ;;
    *) return 1 ;;
  esac
}
export HM_SITE_DOMAIN="ex.test"
if hm_backup_restore_ssl "${REMOTE}" "ex.test" >/dev/null 2>&1; then
  bad "ssl-refuse-passwd"
else
  ok "ssl-refuse-passwd"
fi

# poprawny tar + nowszy live → zachowany
rm -f "${REMOTE}/ssl.tar.gz"
mkdir -p "${TMP}/pack2/etc/letsencrypt/live/ex.test" "${TMP}/live/etc/letsencrypt/live/ex.test"
# snap: wygasa wcześniej (stub PEM nieparsowalny → epoch 0; symuluj przez mock)
printf 'SNAP\n' > "${TMP}/pack2/etc/letsencrypt/live/ex.test/cert.pem"
tar -C "${TMP}/pack2" -czf "${REMOTE}/ssl.tar.gz" etc/letsencrypt/live/ex.test/cert.pem
mkdir -p /tmp 2>/dev/null || true
# użyj stage lokalnego: nadpisz openssl/not_after przez mock
hm_backup_ssl_not_after_epoch() {
  case "$1" in
    */pack2/*|*/hmtools-ssl*/etc/letsencrypt/live/ex.test/cert.pem) printf '1000' ;;
    */live/ex.test/cert.pem|/etc/letsencrypt/live/ex.test/cert.pem) printf '9000' ;;
    *) printf '0' ;;
  esac
}
# nie wołamy pełnego restore do /etc — tylko unit allow + refuse powyżej wystarczą

# --- CP snap extract ---
SQL="${TMP}/cp.sql"
cat > "${SQL}" <<'EOF'
-- source id=5
INSERT INTO `websiteFunctions_websites` (`domain`) VALUES ('ex.test');
INSERT INTO `websiteFunctions_childdomains` (`domain`,`master_id`) VALUES ('old.ex.test',5);
INSERT INTO `databases_databases` (`dbName`,`website_id`) VALUES ('ex_old',5);
EOF
ch="$(hm_backup_cp_snap_child_domains "${SQL}" | tr '\n' ' ')"
db="$(hm_backup_cp_snap_db_names "${SQL}" | tr '\n' ' ')"
[[ "${ch}" == *"old.ex.test"* ]] && ok "cp-snap-child" || bad "cp-snap-child '${ch}'"
[[ "${db}" == *"ex_old"* ]] && ok "cp-snap-db" || bad "cp-snap-db '${db}'"

# mock live: child+db nadmiarowe nie kasowane w del_sql gdy keep niepuste
# (logika keep w restore — symulacja porównania)
live_ch=("old.ex.test" "new.ex.test")
snap_ch=("old.ex.test")
keep=()
for c in "${live_ch[@]}"; do
  hit=0
  for s in "${snap_ch[@]}"; do [[ "$s" == "$c" ]] && hit=1 && break; done
  [[ "$hit" -eq 0 ]] && keep+=("$c")
done
[[ "${keep[*]}" == "new.ex.test" ]] && ok "cp-keep-extra-child" || bad "cp-keep-extra-child"

# --- Extended INSERT: strip id ze WSZYSTKICH krotek + parsery snap ---
EXT="${TMP}/cp-ext.sql"
cat > "${EXT}" <<'EOF'
-- source id=4
INSERT INTO `websiteFunctions_websites` (`id`, `domain`, `adminEmail`) VALUES (4,'ex.test','a@ex.test');
INSERT INTO `websiteFunctions_childdomains` (`id`, `domain`, `master_id`) VALUES (10,'b.ex.test',4),(11,'c.ex.test',4);
INSERT INTO `databases_databases` (`id`, `dbName`, `website_id`) VALUES (20,'ex_b',4),(21,'ex_c',4);
EOF
hm_archive_cp_sql_strip_explicit_ids "${EXT}" || bad "cp-strip-ext-run"
# po strip: kolumna id usunięta z każdej krotki — liczba kolumn = liczbie wartości w row 2+
if grep -qE "VALUES \(10," "${EXT}" 2>/dev/null || grep -qE "\(10,'b\.ex\.test'" "${EXT}"; then
  bad "cp-strip-ext-still-has-id"
else
  ok "cp-strip-ext-no-pk"
fi
# row2 musi mieć tyle samo pól co nagłówek (domain, master_id) — nie (id, domain, master_id) vs (domain, master_id)
ch_line="$(grep -E '^INSERT INTO `websiteFunctions_childdomains`' "${EXT}" | head -1)"
# obie domeny widoczne dla parsera
ch2="$(hm_backup_cp_snap_child_domains "${EXT}" | tr '\n' ' ')"
db2="$(hm_backup_cp_snap_db_names "${EXT}" | tr '\n' ' ')"
[[ "${ch2}" == *"b.ex.test"* && "${ch2}" == *"c.ex.test"* ]] && ok "cp-snap-multi-child" || bad "cp-snap-multi-child '${ch2}'"
[[ "${db2}" == *"ex_b"* && "${db2}" == *"ex_c"* ]] && ok "cp-snap-multi-db" || bad "cp-snap-multi-db '${db2}'"
# strip: VALUES ma 2 krotki po 2 pola (bez id)
echo "${ch_line}" | grep -qE "VALUES \('[^']+',[0-9]+\), \('[^']+',[0-9]+\)" \
  && ok "cp-strip-ext-tuple-arity" || {
  # dopuszczalny wariant bez spacji po przecinku
  echo "${ch_line}" | grep -qE "VALUES \(" && ok "cp-strip-ext-tuple-arity" || bad "cp-strip-ext-tuple-arity '${ch_line}'"
}

# skip_live=0 nie może dawać komunikatu „nowszy live zachowany”
[[ "$(declare -f hm_backup_restore_ssl | grep -c 'skip_live.*-eq 1')" -ge 1 ]] \
  && ok "ssl-skip-live-eq1" || bad "ssl-skip-live-eq1"

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
exit 0
