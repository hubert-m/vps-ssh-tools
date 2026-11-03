#!/usr/bin/env bash
# Komenda: disk


_hm_cmd_help disk <<'EOF'
Użycie:
  disk                         pełny raport (df + inody + top /home)
  disk --drive                 tylko zużycie dysku (df -hT)
  disk --inodes                tylko inody (df -i)
  disk --home                  tylko top katalogi w /home
  disk --heavy [--count N] [--deep N]
                               najcięższe pliki/katalogi od / (rekurencja)

  Domyślnie przy --heavy: --count 3, --deep 5

  --count N  ile najcięższych pozycji na poziomie
  --deep N   ile poziomów zejścia w najcięższe katalogi
EOF

hm_disk_section_drive() {
  echo "${C_BOLD}Zużycie dysku${C_RESET}"
  df -hT 2>/dev/null || df -h
}

hm_disk_section_inodes() {
  echo "${C_BOLD}Inody${C_RESET}"
  df -i 2>/dev/null | head -20
}

hm_disk_section_home() {
  if [[ ! -d /home ]]; then
    hm_warn "Brak katalogu /home."
    return 0
  fi
  echo "${C_BOLD}Top katalogi w /home${C_RESET}"
  hm_status_line "Obliczanie rozmiaru katalogów w /home..."
  du -h --max-depth=1 /home 2>/dev/null | sort -hr | head -25
  hm_status_clear
}

hm_disk_section_summary() {
  hm_info "Wolne: $(hm_disk_free_percent /)%  |  Zajęte: $(hm_disk_used_percent /)%"
}

# Top N wpisów (pliki + katalogi) bezpośrednio w path — bajty + ścieżka (sort malejąco).
# Pomija sam path oraz typowe wirtualne punkty montowania.
hm_disk_top_entries() {
  local path="$1" count="$2"
  local path_r
  path_r="$(realpath -m "${path}" 2>/dev/null || echo "${path}")"
  path_r="${path_r%/}"
  [[ -n "${path_r}" ]] || path_r="/"

  # -a: pliki i katalogi; -d 1: tylko poziom niżej; -x: ten sam FS
  du -axd 1 -- "${path_r}" 2>/dev/null \
    | awk -v base="${path_r}" '
        NF >= 2 {
          sz = $1
          p = $2
          for (i = 3; i <= NF; i++) p = p " " $i
          # pomiń sam katalog bazowy
          if (p == base || p == base "/" || (base == "/" && p == "/")) next
          # pomiń oczywiste wirtualne (gdy -x nie zadziałało)
          if (p ~ /^\/(proc|sys|dev|run)(\/|$)/) next
          printf "%s\t%s\n", sz, p
        }
      ' \
    | sort -t $'\t' -nr -k1,1 \
    | head -n "${count}"
}

hm_disk_human_size() {
  local bytes="${1:-0}"
  if hm_have_cmd numfmt; then
    numfmt --to=iec --suffix=B --format='%.1f' "${bytes}" 2>/dev/null | sed 's/\.0B$/B/;s/B$//'
    return 0
  fi
  # fallback bez numfmt
  local u=0 units=(B K M G T P) v="${bytes}"
  while (( v >= 1024 && u < ${#units[@]} - 1 )); do
    v=$((v / 1024))
    u=$((u + 1))
  done
  printf '%s%s' "${v}" "${units[$u]}"
}

# Rekurencja: na każdym poziomie top `count` pozycji; zejście w katalogi max `deep` poziomów (1 = tylko bieżący).
hm_disk_heavy_walk() {
  local path="$1" count="$2" deep="$3" level="${4:-1}"
  local indent="" i line sz ent human
  for ((i = 1; i < level; i++)); do
    indent+="  "
  done

  local -a rows=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && rows+=("${line}")
  done < <(hm_disk_top_entries "${path}" "${count}")

  if [[ "${#rows[@]}" -eq 0 ]]; then
    echo "${indent}${C_DIM}(brak wpisów / brak dostępu)${C_RESET}"
    return 0
  fi

  for line in "${rows[@]}"; do
    sz="${line%%$'\t'*}"
    ent="${line#*$'\t'}"
    human="$(hm_disk_human_size "${sz}")"
    if [[ -d "${ent}" && ! -L "${ent}" ]]; then
      echo "${indent}${C_BOLD}${human}${C_RESET}  ${ent}/"
      if [[ "${level}" -lt "${deep}" ]]; then
        hm_disk_heavy_walk "${ent}" "${count}" "${deep}" "$((level + 1))"
      fi
    else
      echo "${indent}${human}  ${ent}"
    fi
  done
}

hm_disk_section_heavy() {
  local count="${1:-3}" deep="${2:-5}"
  echo "${C_BOLD}Najcięższe w /${C_RESET}  (top ${count}, głębokość ${deep})"
  hm_status_line "Skanowanie najcięższych ścieżek od / (może chwilę potrwać)..."
  hm_disk_heavy_walk "/" "${count}" "${deep}" 1
  hm_status_clear
}

cmd_disk() {
  local do_drive=0 do_inodes=0 do_home=0 do_heavy=0
  local heavy_count="" heavy_deep=""
  local any_section=0
  local arg

  while [[ $# -gt 0 ]]; do
    arg="${1}"
    case "${arg}" in
      --drive|-d)
        do_drive=1
        any_section=1
        shift
        ;;
      --inodes|-i)
        do_inodes=1
        any_section=1
        shift
        ;;
      --home)
        do_home=1
        any_section=1
        shift
        ;;
      --heavy)
        do_heavy=1
        any_section=1
        shift
        ;;
      --count)
        shift
        [[ -n "${1:-}" && "${1}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: disk --heavy --count <N>  (N ≥ 1)"
          return 1
        }
        heavy_count="${1}"
        shift
        ;;
      --count=*)
        heavy_count="${arg#--count=}"
        [[ "${heavy_count}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: disk --heavy --count <N>  (N ≥ 1)"
          return 1
        }
        shift
        ;;
      --deep)
        shift
        [[ -n "${1:-}" && "${1}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: disk --heavy --deep <N>  (N ≥ 1)"
          return 1
        }
        heavy_deep="${1}"
        shift
        ;;
      --deep=*)
        heavy_deep="${arg#--deep=}"
        [[ "${heavy_deep}" =~ ^[1-9][0-9]*$ ]] || {
          hm_err "Użycie: disk --heavy --deep <N>  (N ≥ 1)"
          return 1
        }
        shift
        ;;
      help|-h|--help)
        hm_help_topic disk
        return 0
        ;;
      *)
        hm_err "Nieznane: ${arg}. disk help"
        return 1
        ;;
    esac
  done

  if [[ -n "${heavy_count}" || -n "${heavy_deep}" ]] && [[ "${do_heavy}" -ne 1 ]]; then
    hm_err "--count / --deep wymagają flagi --heavy."
    return 1
  fi

  # Bez flag = pełny raport jak dotychczas
  if [[ "${any_section}" -eq 0 ]]; then
    do_drive=1
    do_inodes=1
    do_home=1
  fi

  local need_sep=0
  if [[ "${do_drive}" -eq 1 ]]; then
    hm_disk_section_drive
    need_sep=1
  fi
  if [[ "${do_inodes}" -eq 1 ]]; then
    [[ "${need_sep}" -eq 1 ]] && echo
    hm_disk_section_inodes
    need_sep=1
  fi
  if [[ "${do_home}" -eq 1 ]]; then
    [[ "${need_sep}" -eq 1 ]] && echo
    hm_disk_section_home
    need_sep=1
  fi
  if [[ "${do_heavy}" -eq 1 ]]; then
    [[ "${need_sep}" -eq 1 ]] && echo
    hm_disk_section_heavy "${heavy_count:-3}" "${heavy_deep:-5}"
  fi

  # Podsumowanie % przy sekcji df
  if [[ "${do_drive}" -eq 1 ]]; then
    echo
    hm_disk_section_summary
  fi
}

_hm_cmd_register disk cmd_disk 0 df
