#!/usr/bin/env bash
# backup verify — próbny restore do katalogu tymczasowego i bazy hmtools_verify_*.
# Nie zapisuje docrootu ani żywych baz. Hasło restic zostaje w pliku, nie w raporcie.

hm_backup_drill_mysql() {
  if [[ -n "${HM_BACKUP_VERIFY_MYSQL:-}" ]]; then
    "${HM_BACKUP_VERIFY_MYSQL}" "$@"
    return $?
  fi
  command -v mysql >/dev/null 2>&1 || return 127
  mysql "$@"
}

hm_backup_drill_cleanup() {
  local db="${HM_DRILL_DB:-}" work="${HM_DRILL_WORK:-}"
  HM_DRILL_DB=""
  HM_DRILL_WORK=""
  if [[ "${db}" =~ ^hmtools_verify_[a-z0-9]+$ ]]; then
    hm_backup_drill_mysql --batch -e "DROP DATABASE IF EXISTS \`${db}\`" >/dev/null 2>&1 || true
  fi
  case "${work}" in
    */hmtools-verify.*)
      rm -rf "${work}"
      ;;
  esac
}

hm_backup_drill_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

hm_backup_drill_alert() {
  local msg="$1"
  if declare -F hm_notify >/dev/null 2>&1; then
    hm_notify error "backup verify" "${msg}" "backup-verify" || true
    return 0
  fi
  if [[ -n "${HM_BACKUP_VERIFY_ALERTS:-}" ]]; then
    printf '%s\n' "${msg}" >> "${HM_BACKUP_VERIFY_ALERTS}"
  fi
}

hm_backup_drill_history() {
  local dir file line
  dir="$(dirname "${HM_BACKUP_VERIFY_HISTORY:-/var/lib/hmtools/backup-verify/history.jsonl}")"
  file="${HM_BACKUP_VERIFY_HISTORY:-/var/lib/hmtools/backup-verify/history.jsonl}"
  mkdir -p "${dir}" 2>/dev/null || true
  chmod 0700 "${dir}" 2>/dev/null || true
  touch "${file}" 2>/dev/null || return 0
  chmod 0600 "${file}" 2>/dev/null || true
  line="$1"
  printf '%s\n' "${line}" >> "${file}"
}

# Root lokalnych snapshotów.
# hm_load_config zawsze ustawia BACKUP_LOCAL_ROOT=/backup/hmtools — gdy to tylko default
# (HM_BACKUP_LOCAL_ROOT_EXPLICIT≠1), a RCLONE_REMOTE to ścieżka lokalna, użyj RCLONE_REMOTE
# (domyślna konfiguracja VPS: RCLONE_REMOTE=/backup/remote).
hm_backup_verify_local_root() {
  local rr="${RCLONE_REMOTE:-}" blr="${BACKUP_LOCAL_ROOT:-}"
  if [[ "${rr}" == /* && "${HM_BACKUP_LOCAL_ROOT_EXPLICIT:-0}" != "1" ]]; then
    printf '%s' "${rr}"
    return 0
  fi
  if [[ -n "${blr}" ]]; then
    printf '%s' "${blr}"
    return 0
  fi
  if [[ "${rr}" == /* ]]; then
    printf '%s' "${rr}"
    return 0
  fi
  printf '%s' "/backup/hmtools"
}

# Stamp: YYYYMMDD | YYYYMMDD-HHMMSS | YYYYMMDD-HHMMSS-N
hm_backup_verify_is_stamp() {
  [[ "${1:-}" =~ ^[0-9]{8}(-[0-9]{6}(-[0-9]+)?)?$ ]]
}

# Najnowszy stamp z manifestem status=ok/partial/brak (pomija orphan bez manifestu).
hm_backup_verify_pick_ok_stamp() {
  local base="$1" s man st
  local -a cands=()
  [[ -d "${base}" ]] || return 1
  while IFS= read -r s; do
    [[ -n "${s}" ]] || continue
    hm_backup_verify_is_stamp "${s}" || continue
    man="${base}/${s}/manifest.json"
    [[ -f "${man}" ]] || continue
    st="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${man}" | head -1)"
    [[ -z "${st}" || "${st}" == "ok" || "${st}" == "partial" ]] || continue
    cands+=("${s}")
  done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  [[ "${#cands[@]}" -gt 0 ]] || return 1
  printf '%s' "${cands[0]}"
}

hm_backup_drill_resolve_stamp() {
  local scope="$1" stamp="$2" target="${3:-local}" base found="" root
  [[ -n "${stamp}" && "${stamp}" != "latest" ]] && { printf '%s' "${stamp}"; return 0; }
  root="$(hm_backup_verify_local_root)"
  if [[ "${target}" == "local" ]]; then
    if [[ "${scope}" == "full" ]]; then
      base="${root}/full"
      found="$(hm_backup_verify_pick_ok_stamp "${base}" 2>/dev/null || true)"
      if [[ -z "${found}" && -d "${base}" ]]; then
        found="$(find "${base}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
          | grep -E '^[0-9]{8}(-[0-9]{6}(-[0-9]+)?)?$' | sort -r | head -1 || true)"
      fi
    else
      base="${root}/${scope}"
      found="$(hm_backup_verify_pick_ok_stamp "${base}" 2>/dev/null || true)"
      # full/<stamp>/sites/<scope>
      if [[ -z "${found}" ]]; then
        base="${root}/full"
        if [[ -d "${base}" ]]; then
          while IFS= read -r s; do
            [[ -n "${s}" ]] || continue
            [[ -d "${base}/${s}/sites/${scope}" ]] || continue
            [[ -f "${base}/${s}/sites/${scope}/manifest.json" || -f "${base}/${s}/manifest.json" ]] || continue
            found="${s}"
            break
          done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | grep -E '^[0-9]{8}(-[0-9]{6}(-[0-9]+)?)?$' | sort -r)
        fi
      fi
    fi
  elif declare -F hm_backup_list_stamps >/dev/null 2>&1; then
    found="$(hm_backup_list_stamps "${scope}" 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${found}" ]] || {
    HM_DRILL_REASON="brak stampów (latest)"
    return 1
  }
  printf '%s' "${found}"
}

hm_backup_drill_fetch_local() {
  local scope="$1" stamp="$2" dest="$3" src root
  root="$(hm_backup_verify_local_root)"
  if [[ "${scope}" == "full" ]]; then
    # meta full — bez plików site; caller iteruje sites/
    src="${root}/full/${stamp}"
  else
    src="${root}/${scope}/${stamp}"
    if [[ ! -d "${src}" ]]; then
      src="${root}/full/${stamp}/sites/${scope}"
    fi
  fi
  [[ -d "${src}" ]] || {
    HM_DRILL_REASON="brak lokalnego snapshotu"
    return 1
  }
  cp -a "${src}/." "${dest}/"
}

hm_backup_drill_exec_bin() {
  local bin="$1"
  shift
  if [[ -f "${bin}" ]]; then
    if [[ -x "${bin}" ]]; then
      "${bin}" "$@"
    else
      bash "${bin}" "$@"
    fi
    return $?
  fi
  command -v "${bin}" >/dev/null 2>&1 || return 127
  "${bin}" "$@"
}

hm_backup_drill_fetch_rclone() {
  local target="$1" scope="$2" stamp="$3" dest="$4" remote bin rc=0
  if [[ -n "${HM_BACKUP_VERIFY_REMOTE:-}" ]]; then
    remote="${HM_BACKUP_VERIFY_REMOTE}"
  elif [[ -n "${RCLONE_REMOTE:-}" ]] && [[ "${RCLONE_REMOTE}" == "${target}:"* ]]; then
    remote="${RCLONE_REMOTE}"
  elif [[ -n "${RCLONE_REMOTE:-}" ]] && [[ "${RCLONE_REMOTE%%:*}" == "${target}" ]]; then
    remote="${RCLONE_REMOTE}"
  elif [[ "${target}" == "gdrive" || "${target}" == "drive" ]] && [[ "${RCLONE_REMOTE:-}" == gdrive:* || "${RCLONE_REMOTE:-}" == drive:* ]]; then
    remote="${RCLONE_REMOTE}"
  elif [[ "${target}" =~ ^(gdrive|s3|b2|sftp|drive)$ ]]; then
    # legacy mock/test prefix
    remote="hmtools-${target}:backup"
  elif [[ "${target}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    # dowolny remote z rclone (np. qa:)
    remote="${target}:"
  else
    remote="hmtools-${target}:backup"
  fi
  bin="${HM_BACKUP_VERIFY_RCLONE_BIN:-rclone}"
  if [[ "${scope}" == "full" ]]; then
    hm_backup_drill_exec_bin "${bin}" copy "${remote}/full/${stamp}" "${dest}" || rc=$?
  else
    hm_backup_drill_exec_bin "${bin}" copy "${remote}/${scope}/${stamp}" "${dest}" || rc=$?
    # Fallback full/<stamp>/sites/<scope>
    if [[ "${rc}" -ne 0 ]] || [[ ! -e "${dest}/manifest.json" && ! -e "${dest}/files.tar.gz" && ! -d "${dest}/files.chunks" ]]; then
      rc=0
      hm_backup_drill_exec_bin "${bin}" copy "${remote}/full/${stamp}/sites/${scope}" "${dest}" || rc=$?
    fi
  fi
  if [[ "${rc}" -eq 127 ]]; then
    HM_DRILL_REASON="brak rclone"
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    HM_DRILL_REASON="pobranie ${target} nieudane"
    return 1
  fi
  return 0
}

hm_backup_drill_fetch_restic() {
  local scope="$1" stamp="$2" dest="$3" pass repo bin errf rc=0
  pass="${HM_BACKUP_VERIFY_PASSFILE:-/etc/hmtools/restic.pass}"
  repo="${HM_BACKUP_VERIFY_RESTIC_REPO:-}"
  bin="${HM_BACKUP_VERIFY_RESTIC_BIN:-restic}"
  [[ -n "${repo}" ]] || {
    HM_DRILL_REASON="brak repozytorium restic"
    return 1
  }
  [[ -f "${pass}" ]] || {
    HM_DRILL_REASON="zly klucz"
    return 1
  }
  errf="${HM_DRILL_WORK}/restic.err"
  RESTIC_PASSWORD_FILE="${pass}" hm_backup_drill_exec_bin "${bin}" restore "${stamp:-latest}" --repo "${repo}" --target "${dest}" >/dev/null 2>"${errf}" || rc=$?
  if [[ "${rc}" -eq 127 ]]; then
    HM_DRILL_REASON="brak restic"
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    if grep -Eiq 'wrong password|ciphertext|unable to open config' "${errf}" 2>/dev/null; then
      HM_DRILL_REASON="zly klucz"
    else
      HM_DRILL_REASON="restic restore nieudany"
    fi
    return 1
  fi
  return 0
}

hm_backup_drill_fetch() {
  local target="$1" scope="$2" stamp="$3" dest="$4"
  mkdir -p "${dest}"
  if [[ -n "${HM_BACKUP_VERIFY_SNAP:-}" ]]; then
    [[ -d "${HM_BACKUP_VERIFY_SNAP}" ]] || {
      HM_DRILL_REASON="brak fixture snapshotu"
      return 1
    }
    cp -a "${HM_BACKUP_VERIFY_SNAP}/." "${dest}/"
    return 0
  fi
  case "${target}" in
    local) hm_backup_drill_fetch_local "${scope}" "${stamp}" "${dest}" ;;
    restic|inc) hm_backup_drill_fetch_restic "${scope}" "${stamp}" "${dest}" ;;
    *)
      # dowolny rclone remote (gdrive/s3/qa/…) — nie whitelist
      if [[ "${target}" =~ ^[A-Za-z0-9_-]+$ ]]; then
        hm_backup_drill_fetch_rclone "${target}" "${scope}" "${stamp}" "${dest}"
      else
        HM_DRILL_REASON="nieznany cel ${target}"
        return 1
      fi
      ;;
  esac
}

hm_backup_drill_sums() {
  local dest="$1" sum file got want
  if [[ -f "${dest}/SHA256SUMS" ]]; then
    while read -r sum file || [[ -n "${sum}" ]]; do
      [[ "${sum}" =~ ^[0-9a-fA-F]{64}$ ]] || continue
      [[ -f "${dest}/${file}" ]] || {
        HM_DRILL_REASON="brak pliku z manifestu: ${file}"
        return 1
      }
      got="$(sha256sum "${dest}/${file}" 2>/dev/null | awk '{print $1}')"
      got="${got#\\}"
      [[ "${got}" == "${sum}" ]] || {
        HM_DRILL_REASON="suma niezgodna: ${file}"
        return 1
      }
    done < "${dest}/SHA256SUMS"
  fi
  if [[ -f "${dest}/manifest.json" && -f "${dest}/files.tar.gz" ]]; then
    want="$(sed -n 's/.*"sha256_files"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{64\}\)".*/\1/p' "${dest}/manifest.json" | head -1)"
    if [[ -n "${want}" ]]; then
      got="$(sha256sum "${dest}/files.tar.gz" 2>/dev/null | awk '{print $1}')"
      got="${got#\\}"
      [[ "${got}" == "${want}" ]] || {
        HM_DRILL_REASON="suma niezgodna: files.tar.gz"
        return 1
      }
    fi
  fi
  return 0
}

hm_backup_drill_sql_filter() {
  # tolower — portable (mawk nie ma IGNORECASE)
  awk '
    {
      line=$0
      low=tolower(line)
      if (low ~ /^[[:space:]]*(create|drop)[[:space:]]+database([[:space:]]|$)/) next
      if (low ~ /^[[:space:]]*use[[:space:]]/) next
      print line
    }
  '
}

# Sklej files.chunks → files.tar.gz w dest (gdy brak monolitu).
hm_backup_drill_join_chunks() {
  local dest="$1" out part
  [[ -f "${dest}/files.tar.gz" ]] && return 0
  [[ -d "${dest}/files.chunks" ]] || return 1
  out="${dest}/files.tar.gz"
  : > "${out}"
  while IFS= read -r part; do
    [[ -n "${part}" ]] || continue
    cat "${part}" >> "${out}" || return 1
  done < <(find "${dest}/files.chunks" -name 'files.tar.gz.part_*' 2>/dev/null | sort)
  [[ -s "${out}" ]] || { rm -f "${out}"; return 1; }
  return 0
}

# Czy snapshot wymaga dump SQL? return 0 = tak. Puste/brak databases → nie (serwis bez bazy).
hm_backup_drill_expects_db() {
  local dest="$1" man blob
  man="${dest}/manifest.json"
  [[ -f "${man}" ]] || return 1
  if grep -Eq '"databases"[[:space:]]*:[[:space:]]*\[\]' "${man}" 2>/dev/null; then
    return 1
  fi
  if grep -Eq '"databases"[[:space:]]*:[[:space:]]*""' "${man}" 2>/dev/null; then
    return 1
  fi
  # Niepusta tablica / niepusty string → wymagaj dumpów
  blob="$(sed -n 's/.*"databases"[[:space:]]*:[[:space:]]*//p' "${man}" | head -1)"
  [[ -n "${blob}" && "${blob}" != "null"* ]] || return 1
  return 0
}

hm_backup_drill_run() {
  local target="$1" scope="$2" stamp="$3" json="$4"
  local start end sec dest list files=0 tables=0 bytes=0 result="FAIL" reason="" sql irc=""
  local db rand report
  start="$(date +%s)"
  HM_DRILL_REASON=""
  HM_DRILL_DB=""
  rand="$(printf '%04x%04x' "${RANDOM}" "${RANDOM}")"
  dest_parent="${TMP_DIR:-/tmp}"
  HM_DRILL_WORK="$(mktemp -d "${dest_parent}/hmtools-verify.XXXXXX")" || {
    HM_DRILL_REASON="brak katalogu tymczasowego"
    return 1
  }
  chmod 0700 "${HM_DRILL_WORK}" 2>/dev/null || true
  if [[ -n "${HM_BACKUP_VERIFY_MODE_LOG:-}" ]]; then
    stat -c '%a' "${HM_DRILL_WORK}" > "${HM_BACKUP_VERIFY_MODE_LOG}" 2>/dev/null || true
  fi
  dest="${HM_DRILL_WORK}/snap"
  local resolved=""
  if ! resolved="$(hm_backup_drill_resolve_stamp "${scope}" "${stamp}" "${target}")"; then
    reason="${HM_DRILL_REASON:-brak stampów (latest)}"
  else
    stamp="${resolved}"
  fi
  if [[ -z "${reason}" ]] && ! hm_backup_drill_fetch "${target}" "${scope}" "${stamp}" "${dest}"; then
    reason="${HM_DRILL_REASON:-pobranie nieudane}"
  fi
  if [[ -z "${reason}" ]]; then
    hm_backup_drill_join_chunks "${dest}" || true
  fi
  if [[ -z "${reason}" && ! -f "${dest}/files.tar.gz" ]]; then
    reason="brak files.tar.gz"
  elif [[ -z "${reason}" ]] && ! hm_backup_drill_sums "${dest}"; then
    reason="${HM_DRILL_REASON:-zla suma}"
  elif [[ -z "${reason}" ]]; then
    list="${HM_DRILL_WORK}/tar.list"
    if ! tar -tzf "${dest}/files.tar.gz" > "${list}" 2>"${HM_DRILL_WORK}/tar.err"; then
      reason="uszkodzony tar"
    else
      files="$(grep -c . "${list}" || true)"
      [[ "${files}" =~ ^[0-9]+$ ]] || files=0
      if [[ "${files}" -eq 0 ]]; then
        reason="pusty tar"
      fi
    fi
  fi
  local sqls=() need_db=1
  if [[ -z "${reason}" ]]; then
    shopt -s nullglob
    sqls=( "${dest}/db/"*.sql.gz )
    shopt -u nullglob
    if [[ "${#sqls[@]}" -eq 0 ]]; then
      if hm_backup_drill_expects_db "${dest}"; then
        reason="brak dumpa SQL"
      else
        need_db=0
      fi
    else
      for sql in "${sqls[@]}"; do
        if ! gzip -t "${sql}" 2>/dev/null; then
          reason="uszkodzony dump"
          break
        fi
        bytes="$(gzip -dc "${sql}" 2>/dev/null | wc -c | tr -d '[:space:]')"
        if [[ ! "${bytes}" =~ ^[0-9]+$ || "${bytes}" -eq 0 ]]; then
          reason="pusty dump"
          break
        fi
      done
    fi
  fi
  if [[ -z "${reason}" && "${need_db}" -eq 1 ]]; then
    HM_DRILL_DB="hmtools_verify_${rand}"
    if [[ ! "${HM_DRILL_DB}" =~ ^hmtools_verify_[a-z0-9]+$ ]]; then
      reason="odmowa nazwy bazy"
      HM_DRILL_DB=""
    elif ! hm_backup_drill_mysql --batch -e "CREATE DATABASE \`${HM_DRILL_DB}\`" >/dev/null 2>&1; then
      reason="nie utworzono bazy drill"
      HM_DRILL_DB=""
    else
      for sql in "${sqls[@]}"; do
        irc=0
        gzip -dc "${sql}" | hm_backup_drill_sql_filter | hm_backup_drill_mysql "${HM_DRILL_DB}" >/dev/null 2>&1 || irc=$?
        if [[ "${irc}" -ne 0 ]]; then
          reason="import SQL nieudany"
          break
        fi
      done
    fi
  fi
  if [[ -z "${reason}" ]]; then
    if [[ "${need_db}" -eq 1 && -n "${HM_DRILL_DB}" ]]; then
      tables="$(hm_backup_drill_mysql --batch -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${HM_DRILL_DB}'" 2>/dev/null || true)"
      tables="$(printf '%s' "${tables}" | tr -d '[:space:]')"
      [[ "${tables}" =~ ^[0-9]+$ ]] || tables=0
    else
      tables=0
    fi
    result="PASS"
    reason="ok"
  fi
  end="$(date +%s)"
  sec="$((end - start))"
  [[ "${sec}" =~ ^[0-9]+$ ]] || sec=0
  bytes=0
  if [[ -f "${dest}/files.tar.gz" ]]; then
    bytes="$(wc -c < "${dest}/files.tar.gz" | tr -d '[:space:]')"
  fi
  [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
  report="$(printf '{"result":"%s","scope":"%s","stamp":"%s","target":"%s","seconds":%s,"bytes":%s,"files":%s,"tables":%s,"reason":"%s"}' \
    "$(hm_backup_drill_json_escape "${result}")" \
    "$(hm_backup_drill_json_escape "${scope}")" \
    "$(hm_backup_drill_json_escape "${stamp}")" \
    "$(hm_backup_drill_json_escape "${target}")" \
    "${sec}" "${bytes}" "${files}" "${tables}" \
    "$(hm_backup_drill_json_escape "${reason}")")"
  hm_backup_drill_history "${report}"
  if [[ "${json}" -eq 1 ]]; then
    printf '%s' "${report}"
  else
    printf 'backup verify %s @ %s/%s: %s  pliki=%s tabele=%s  %ss  %s\n' \
      "${scope}" "${target}" "${stamp}" "${result}" "${files}" "${tables}" "${sec}" "${reason}"
  fi
  if [[ "${result}" != "PASS" ]]; then
    hm_backup_drill_alert "backup verify ${scope} ${target} ${stamp}: ${reason}"
    return 1
  fi
  return 0
}

hm_backup_drill_exec() {
  local target="$1" scope="$2" stamp="$3" json="$4" rc=0
  (
    set +e
    HM_DRILL_DB=""
    HM_DRILL_WORK=""
    trap 'hm_backup_drill_cleanup' EXIT
    hm_backup_drill_run "${target}" "${scope}" "${stamp}" "${json}"
  ) || rc=$?
  return "${rc}"
}

hm_backup_drill_split_targets() {
  local csv="$1" part rest
  rest="${csv},"
  while [[ "${rest}" == *","* ]]; do
    part="${rest%%,*}"
    rest="${rest#*,}"
    [[ -n "${part}" ]] && printf '%s\n' "${part}"
  done
}

hm_backup_drill_schedule_path() {
  printf '%s' "${HM_BACKUP_VERIFY_CRON:-/etc/cron.d/hmtools-backup-verify}"
}

hm_backup_drill_schedule() {
  local sub="${1:-status}" f bin logf
  f="$(hm_backup_drill_schedule_path)"
  bin="$(command -v hmtools 2>/dev/null || echo "${HMTOOLS_ROOT:-/opt/hmtools}/bin/hmtools")"
  logf="${LOG_DIR:-/hm-tools/logs}/backup-verify.log"
  case "${sub}" in
    status|show|"")
      if [[ -f "${f}" ]]; then
        echo "backup verify schedule: włączony (${f})"
        sed 's/^/  /' "${f}"
      else
        echo "backup verify schedule: wyłączony"
      fi
      ;;
    enable|on)
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "backup verify schedule enable" \
          "Cron odpala próbny restore. Żywa strona i żywe bazy nie są ruszane." \
          "Zapis ${f} (niedziela 04:15, backup verify --weekly --yes)" || return 1
      fi
      mkdir -p "$(dirname "${f}")" "$(dirname "${logf}")" 2>/dev/null || true
      cat > "${f}" <<EOF
# hmtools — próbny restore (backup verify). Nie przywraca na żywą stronę.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
15 4 * * 0 root ${bin} -c "backup verify --weekly --yes" >> ${logf} 2>&1
EOF
      chmod 644 "${f}" 2>/dev/null || true
      echo "backup verify schedule: włączony (${f})"
      ;;
    disable|off)
      if [[ ! -f "${f}" ]]; then
        echo "backup verify schedule: już wyłączony"
        return 0
      fi
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "backup verify schedule disable" \
          "Usunięcie crona próbnego restore." \
          "Usunięcie ${f}" || return 1
      fi
      rm -f "${f}"
      echo "backup verify schedule: wyłączony"
      ;;
    *)
      hm_err "Użycie: backup verify schedule enable|disable|status"
      return 1
      ;;
  esac
}

hm_backup_verify_cmd() {
  local scope="" stamp="" json=0 weekly=0
  local -a targets=()
  local a csv t rc=0 any=0 first=1 picked=""
  if [[ "${1:-}" == "schedule" ]]; then
    shift || true
    hm_backup_drill_schedule "${1:-status}"
    return $?
  fi
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --yes|-y) ;;
      --weekly) weekly=1 ;;
      --target)
        [[ $# -gt 0 ]] || { hm_err "Brak nazwy celu"; return 1; }
        targets+=("$1")
        shift
        ;;
      --target=*) targets+=("${a#--target=}") ;;
      --targets)
        [[ $# -gt 0 ]] || { hm_err "Brak listy celów"; return 1; }
        csv="$1"
        shift
        while IFS= read -r t; do
          [[ -n "${t}" ]] && targets+=("${t}")
        done < <(hm_backup_drill_split_targets "${csv}")
        ;;
      --targets=*)
        csv="${a#--targets=}"
        while IFS= read -r t; do
          [[ -n "${t}" ]] && targets+=("${t}")
        done < <(hm_backup_drill_split_targets "${csv}")
        ;;
      help|-h|--help)
        hm_err "Użycie: backup verify [domena|full] [stamp] [--target n|--targets a,b] [--json] [--weekly]"
        hm_err "       backup verify schedule enable|disable|status"
        return 0
        ;;
      *)
        if [[ -z "${scope}" ]]; then
          scope="${a}"
        elif [[ -z "${stamp}" ]]; then
          stamp="${a}"
        else
          hm_err "Nieznany argument: ${a}"
          return 1
        fi
        ;;
    esac
  done
  if [[ "${weekly}" -eq 1 && -z "${scope}" ]]; then
    if [[ -n "${HM_BACKUP_VERIFY_SITE:-}" ]]; then
      scope="${HM_BACKUP_VERIFY_SITE}"
    elif [[ -n "${HM_BACKUP_VERIFY_SITES:-}" && -f "${HM_BACKUP_VERIFY_SITES}" ]]; then
      picked="$(grep -v '^[[:space:]]*$' "${HM_BACKUP_VERIFY_SITES}" | head -1 || true)"
      scope="${picked}"
    else
      # round-robin / pierwsza domena z katalogu snapshotów (nie full/)
      local _root _d
      _root="$(hm_backup_verify_local_root)"
      if [[ -d "${_root}" ]]; then
        while IFS= read -r _d; do
          [[ -n "${_d}" && "${_d}" != "full" ]] || continue
          [[ -d "${_root}/${_d}" ]] || continue
          scope="${_d}"
          break
        done < <(find "${_root}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
      fi
      [[ -n "${scope}" ]] || scope="full"
    fi
  fi
  if [[ -z "${scope}" ]]; then
    hm_err "Podaj domenę albo full (albo --weekly)."
    return 1
  fi
  case "${scope}" in
    *..*|/*|*\\*) hm_err "Zła nazwa zakresu"; return 1 ;;
  esac
  [[ -n "${stamp}" ]] || stamp="${HM_BACKUP_VERIFY_STAMP:-latest}"
  case "${stamp}" in
    *..*|/*|*\\*) hm_err "Zły stamp"; return 1 ;;
  esac
  if [[ "${#targets[@]}" -eq 0 ]]; then
    if [[ -n "${HM_BACKUP_VERIFY_TARGETS:-}" ]]; then
      while IFS= read -r t; do
        [[ -n "${t}" ]] && targets+=("${t}")
      done < <(hm_backup_drill_split_targets "${HM_BACKUP_VERIFY_TARGETS}")
    elif [[ -n "${RCLONE_REMOTE:-}" && "${RCLONE_REMOTE}" != /* ]]; then
      # zdalny rclone (np. qa:/backup) — domyślny cel = nazwa remote
      targets=("${RCLONE_REMOTE%%:*}")
    else
      # lokalny RCLONE_REMOTE lub BACKUP_LOCAL_ROOT
      targets=(local)
    fi
  fi
  if [[ "${json}" -eq 1 ]]; then
    printf '['
  fi

  # scope=full → weryfikuj każdą domenę w full/<stamp>/sites/*
  if [[ "${scope}" == "full" ]]; then
    local fstamp site sites_root _root
    for t in "${targets[@]}"; do
      fstamp=""
      if ! fstamp="$(hm_backup_drill_resolve_stamp full "${stamp}" "${t}")"; then
        if [[ "${json}" -eq 1 ]]; then
          [[ "${first}" -eq 1 ]] || printf ','
          first=0
          printf '{"result":"FAIL","scope":"full","stamp":"%s","target":"%s","reason":"%s"}' \
            "$(hm_backup_drill_json_escape "${stamp}")" \
            "$(hm_backup_drill_json_escape "${t}")" \
            "$(hm_backup_drill_json_escape "${HM_DRILL_REASON:-brak stampów}")"
        else
          printf 'backup verify full @ %s/%s: FAIL  %s\n' "${t}" "${stamp}" "${HM_DRILL_REASON:-brak stampów}"
        fi
        any=1
        continue
      fi
      _root="$(hm_backup_verify_local_root)"
      sites_root="${_root}/full/${fstamp}/sites"
      if [[ "${t}" == "local" && -d "${sites_root}" ]]; then
        while IFS= read -r site; do
          [[ -n "${site}" ]] || continue
          if [[ "${json}" -eq 1 ]]; then
            [[ "${first}" -eq 1 ]] || printf ','
            first=0
          fi
          hm_backup_drill_exec "${t}" "${site}" "${fstamp}" "${json}" || rc=$?
          [[ "${rc}" -ne 0 ]] && any=1
          rc=0
        done < <(find "${sites_root}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
      else
        # remote: bez listingu sites — jeden komunikat
        if [[ "${json}" -eq 1 ]]; then
          [[ "${first}" -eq 1 ]] || printf ','
          first=0
          printf '{"result":"FAIL","scope":"full","stamp":"%s","target":"%s","reason":"użyj backup verify <domena> <stamp> (full/sites)"}' \
            "$(hm_backup_drill_json_escape "${fstamp}")" \
            "$(hm_backup_drill_json_escape "${t}")"
        else
          hm_info "verify full @ ${t}: wskaż domenę (backup verify <d> ${fstamp}) — remote bez auto-list sites."
        fi
        any=1
      fi
    done
  else
    for t in "${targets[@]}"; do
      if [[ "${json}" -eq 1 ]]; then
        [[ "${first}" -eq 1 ]] || printf ','
        first=0
      fi
      hm_backup_drill_exec "${t}" "${scope}" "${stamp}" "${json}" || rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        any=1
      fi
      rc=0
    done
  fi
  if [[ "${json}" -eq 1 ]]; then
    printf ']\n'
  fi
  [[ "${any}" -eq 0 ]]
}
