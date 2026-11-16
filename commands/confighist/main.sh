#!/usr/bin/env bash
# config — lokalne repo zmian konfiguracji. Bez pusha i bez sekretów.

_hm_cmd_help config <<'EOF'
Użycie:
  config track init|status|gc
  config log [ścieżka]
  config diff [rev]
  config rollback <rev> [ścieżka]

Repo jest lokalne. shadow/gshadow, klucze, tokeny, hmtools.conf, debian.cnf
zostają jako skrót (.meta), bez treści. Rollback: atomowy mv, absolutny dest.
EOF

hm_config_repo() { printf '%s\n' "${HM_CONFIG_GIT:-/var/lib/hmtools/confgit}"; }

hm_config_is_secret() {
  local path="$1" base
  base="$(basename "${path}")"
  case "${base}" in
    shadow|shadow-|gshadow|gshadow-|id_rsa|id_ed25519|rclone.conf|restic.pass|debian.cnf|sasl_passwd|hmtools.conf)
      return 0
      ;;
  esac
  case "${base}" in
    *.pass|*.key|*.pem) return 0 ;;
  esac
  case "${path}" in
    *token*|*Token*|*TOKEN*|*.pass|*.key|*.pem) return 0 ;;
  esac
  if [[ -f "${path}" ]] && grep -q 'BEGIN .*PRIVATE KEY' "${path}" 2>/dev/null; then
    return 0
  fi
  return 1
}

hm_config_rel() {
  local path="$1" src="${HM_CONFIG_SRC:-}"
  if [[ -n "${src}" && "${path}" == "${src}/"* ]]; then
    printf '%s\n' "${path#"${src}/"}"
  elif [[ -n "${src}" && "${path}" == "${src}" ]]; then
    printf '\n'
  else
    # zawsze bez wiodącego /
    printf '%s\n' "${path#/}"
  fi
}

# Absolutna ścieżka docelowa na systemie (nigdy względna względem CWD).
hm_config_dest_abs() {
  local rel="$1" src="${HM_CONFIG_SRC:-}"
  rel="${rel#/}"
  if [[ -n "${src}" ]]; then
    printf '%s/%s\n' "${src}" "${rel}"
  else
    printf '/%s\n' "${rel}"
  fi
}

hm_config_path_allowed() {
  local abs="$1" repo p src="${HM_CONFIG_SRC:-}"
  repo="$(hm_config_repo)"
  [[ -f "${repo}/paths.txt" ]] || return 1
  # normalizuj
  abs="$(readlink -f "${abs}" 2>/dev/null || printf '%s' "${abs}")"
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    p="$(readlink -f "${p}" 2>/dev/null || printf '%s' "${p}")"
    case "${abs}" in
      "${p}"|"${p}"/*) return 0 ;;
    esac
  done < "${repo}/paths.txt"
  if [[ -n "${src}" ]]; then
    src="$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")"
    case "${abs}" in
      "${src}"|"${src}"/*) return 0 ;;
    esac
  fi
  return 1
}

hm_config_each() {
  local repo path
  repo="$(hm_config_repo)"
  [[ -f "${repo}/paths.txt" ]] || return 0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if [[ -d "${path}" ]]; then
      find "${path}" -type f -print
    elif [[ -f "${path}" ]]; then
      printf '%s\n' "${path}"
    fi
  done < "${repo}/paths.txt"
}

hm_config_sync() {
  local repo path rel mode owner hash dest keep="${TMPDIR:-/tmp}/hm-config-keep.$$"
  repo="$(hm_config_repo)"
  : > "${repo}/modes.tsv"
  : > "${keep}"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    rel="$(hm_config_rel "${path}")"
    [[ -n "${rel}" ]] || continue
    dest="${repo}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    printf '%s\n' "${rel}" >> "${keep}"
    if hm_config_is_secret "${path}"; then
      hash="$(sha256sum "${path}" | awk '{ print $1 }')"
      printf 'sha256 %s\n' "${hash}" > "${dest}.meta"
      rm -f "${dest}"
      printf '%s\n' "${rel}.meta" >> "${keep}"
      continue
    fi
    cp -f "${path}" "${dest}"
    rm -f "${dest}.meta"
    mode="$(stat -c '%a' "${path}" 2>/dev/null || echo 644)"
    owner="$(stat -c '%U:%G' "${path}" 2>/dev/null || echo unknown)"
    printf '%s %s %s\n' "${mode}" "${owner}" "${rel}" >> "${repo}/modes.tsv"
  done < <(hm_config_each)

  # Usuń z working tree pliki, których już nie ma w źródle (snapshot = stan)
  if [[ -d "${repo}" ]]; then
    while IFS= read -r -d '' path; do
      rel="${path#"${repo}/"}"
      case "${rel}" in
        .git|/*|.git/*|paths.txt|modes.tsv) continue ;;
      esac
      if ! grep -qxF "${rel}" "${keep}" 2>/dev/null; then
        rm -f "${path}"
      fi
    done < <(find "${repo}" -type f -print0 2>/dev/null)
  fi
  rm -f "${keep}"
}

hm_config_commit() {
  local msg="$1" repo
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || return 0
  hm_config_sync
  git -C "${repo}" add -A
  if git -C "${repo}" diff --cached --quiet; then
    return 0
  fi
  git -C "${repo}" -c user.email=hmtools@localhost -c user.name=hmtools commit -q -m "${msg}"
}

hm_config_before() {
  local repo
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || return 0
  if [[ "${HM_CONFIG_OPEN:-0}" == "1" ]]; then
    hm_config_after || true
  fi
  HM_CONFIG_TITLE="${1:-zmiana}"
  HM_CONFIG_OPEN=1
  hm_config_commit "przed: ${HM_CONFIG_TITLE} user=$(id -un 2>/dev/null || echo unknown)"
}

hm_config_after() {
  local repo
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || return 0
  [[ "${HM_CONFIG_OPEN:-0}" == "1" ]] || return 0
  hm_config_commit "po: ${HM_CONFIG_TITLE:-zmiana} user=$(id -un 2>/dev/null || echo unknown)"
  HM_CONFIG_OPEN=0
}

hm_config_init() {
  local repo
  repo="$(hm_config_repo)"
  mkdir -p "${repo}"
  chmod 0700 "${repo}" || true
  if [[ ! -d "${repo}/.git" ]]; then
    git -C "${repo}" init -q
    git -C "${repo}" config core.autocrlf false
  fi
  if [[ -n "${HM_CONFIG_PATHS:-}" && -f "${HM_CONFIG_PATHS}" ]]; then
    cp -f "${HM_CONFIG_PATHS}" "${repo}/paths.txt"
  elif [[ ! -f "${repo}/paths.txt" ]]; then
    printf '%s\n' /etc /usr/local/lsws/conf /etc/crontab > "${repo}/paths.txt"
  fi
  hm_config_commit "init"
  hm_ok "Repo konfiguracji: ${repo}"
}

hm_config_status() {
  local repo
  hm_config_after || true
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || { hm_err "Brak repo. config track init"; return 1; }
  git -C "${repo}" status --short
  if git -C "${repo}" remote | grep -q .; then
    hm_err "Repo ma remote. To ma zostać lokalne."
    return 1
  fi
  printf 'remote: brak\n'
}

hm_config_gc() {
  local repo size limit
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || { hm_err "Brak repo."; return 1; }
  git -C "${repo}" gc --quiet
  size="$(du -sk "${repo}/.git" 2>/dev/null | awk '{ print $1 }')"
  if [[ -z "${size}" ]]; then
    size="$(git -C "${repo}" count-objects -v | awk '/^size:/{s+=$2} /size-pack:/{s+=$2} END { print s+0 }')"
  fi
  limit="${HM_CONFIG_LIMIT_KB:-102400}"
  printf 'size_kb: %s\n' "${size:-0}"
  if [[ "${size:-0}" -gt "${limit}" ]]; then
    hm_warn "Repo konfiguracji ma ${size} KB, limit ${limit}."
  fi
}

hm_config_log() {
  local repo path="${1:-}"
  hm_config_after || true
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || { hm_err "Brak repo."; return 1; }
  if [[ -n "${path}" ]]; then
    git -C "${repo}" log --oneline -- "$(hm_config_rel "${path}")"
  else
    git -C "${repo}" log --oneline
  fi
}

hm_config_diff() {
  local repo rev="${1:-}"
  hm_config_after || true
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || { hm_err "Brak repo."; return 1; }
  if [[ -n "${rev}" ]]; then
    git -C "${repo}" show --stat "${rev}"
  else
    git -C "${repo}" log -1 --stat
  fi
}

hm_config_rollback() {
  local rev="${1:-}" path_arg="${2:-}" repo dest rel tmp mode owner line
  [[ -n "${rev}" ]] || { hm_err "Użycie: config rollback <rev> [ścieżka]"; return 1; }
  repo="$(hm_config_repo)"
  [[ -d "${repo}/.git" ]] || { hm_err "Brak repo."; return 1; }
  # bez wymuszania --yes — prawdziwe potwierdzenie
  hm_confirm_plan "config rollback ${rev}" \
    "Przywraca plik z lokalnego repo (atomowy zapis, absolutna ścieżka)." \
    "" "config rollback ${rev}" || return 1
  if [[ -z "${path_arg}" ]]; then
    hm_err "Podaj ścieżkę pliku."
    return 1
  fi
  rel="$(hm_config_rel "${path_arg}")"
  [[ -n "${rel}" ]] || { hm_err "Pusta ścieżka względna."; return 1; }

  # rewizja:ścieżka musi istnieć PRZED jakimkolwiek zapisem
  if ! git -C "${repo}" cat-file -e "${rev}:${rel}" 2>/dev/null; then
    hm_err "Brak ${rel} w rewizji ${rev}. Nic nie zmieniam."
    return 1
  fi
  # sekrety tylko jako .meta — nie przywracaj treści
  if git -C "${repo}" cat-file -e "${rev}:${rel}.meta" 2>/dev/null \
    || [[ -f "${repo}/${rel}.meta" ]]; then
    # jeśli w tej rewizji jest treść pliku (nie powinno) — i tak odmawiaj gdy baza wygląda na sekret
    :
  fi
  if hm_config_is_secret "/${rel}" || hm_config_is_secret "${path_arg}"; then
    hm_err "Nie przywracam sekretu (${rel}) z historii."
    return 1
  fi

  dest="$(hm_config_dest_abs "${rel}")"
  case "${dest}" in
    /*) ;;
    *) hm_err "Wewnętrzny błąd: dest nie jest absolutny (${dest})."; return 1 ;;
  esac
  if ! hm_config_path_allowed "${dest}"; then
    hm_err "Ścieżka ${dest} poza listą śledzonych katalogów."
    return 1
  fi

  mkdir -p "$(dirname "${dest}")"
  tmp="$(mktemp "${dest}.hmtools.XXXXXX")"
  if ! git -C "${repo}" show "${rev}:${rel}" > "${tmp}"; then
    rm -f "${tmp}"
    hm_err "Nie odczytano ${rev}:${rel}."
    return 1
  fi
  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    hm_err "Pusta treść w repo dla ${rel} — nie nadpisuję ${dest}."
    return 1
  fi

  # sshd_config: walidacja przed podmianą
  if [[ "${rel}" == *sshd_config* ]] && command -v sshd >/dev/null 2>&1; then
    if ! sshd -t -f "${tmp}" 2>/dev/null; then
      rm -f "${tmp}"
      hm_err "sshd -t odrzucił przywracany plik — nic nie zmieniam."
      return 1
    fi
  fi

  # zachowaj tryb/właściciela z live albo z modes.tsv
  mode=""
  owner=""
  if [[ -e "${dest}" ]]; then
    mode="$(stat -c '%a' "${dest}" 2>/dev/null || true)"
    owner="$(stat -c '%U:%G' "${dest}" 2>/dev/null || true)"
  fi
  if [[ -z "${mode}" ]]; then
    line="$(git -C "${repo}" show "${rev}:modes.tsv" 2>/dev/null | awk -v r="${rel}" '$3==r { print $1, $2; exit }')"
    mode="${line%% *}"
    owner="${line#* }"
  fi

  mv -f "${tmp}" "${dest}"
  if [[ "${mode}" =~ ^[0-9]+$ ]]; then
    chmod "${mode}" "${dest}" || true
  fi
  if [[ -n "${owner}" && "${owner}" != "unknown" ]] && command -v chown >/dev/null 2>&1; then
    chown "${owner}" "${dest}" 2>/dev/null || true
  fi
  hm_info "Po rollbacku przeładuj usługę, której dotyczy ${rel}."
  hm_ok "Przywrócono ${rel} z ${rev}."
}

cmd_config() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    track)
      case "${1:-status}" in
        init) shift || true; hm_config_init "$@" ;;
        status|"") hm_config_status ;;
        gc) hm_config_gc ;;
        *) hm_err "Użycie: config track init|status|gc"; return 1 ;;
      esac
      ;;
    log) hm_config_log "$@" ;;
    diff) hm_config_diff "$@" ;;
    rollback|rb) hm_config_rollback "$@" ;;
    help|-h|--help|"") hm_help_topic config ;;
    *) hm_err "Nieznane: config ${sub}"; return 1 ;;
  esac
}

_hm_cmd_register config cmd_config 0
