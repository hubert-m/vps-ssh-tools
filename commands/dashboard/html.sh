#!/usr/bin/env bash
# Statyczny HTML z obiektów --json. Tekst z danych jest escapowany.

hm_html_escape() {
  local s="${1:-}" out="" i c
  local len="${#s}"
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "${c}" in
      '&') out+='&amp;' ;;
      '<') out+='&lt;' ;;
      '>') out+='&gt;' ;;
      '"') out+='&quot;' ;;
      "'") out+='&#39;' ;;
      *) out+="${c}" ;;
    esac
  done
  printf '%s' "${out}"
}

hm_html_cell() {
  local raw="${1:-}"
  case "${raw}" in
    *restic.pass*|*id_rsa*|*id_ed25519*|*/etc/shadow*|*.token*|*'BEGIN '*|*PRIVATE*|*password=*)
      printf '[ukryte]'
      return 0
      ;;
  esac
  hm_html_escape "${raw}"
}

# Pole z płaskiego obiektu JSON. Cudzysłów w wartości jest odkodowany.
hm_html_field() {
  local obj="${1:-}" key="${2:-}"
  printf '%s' "${obj}" | awk -v key="${key}" '
    {
      obj = obj $0
    }
    END {
      needle = "\"" key "\":"
      i = index(obj, needle)
      if (i == 0) exit
      i += length(needle)
      c = substr(obj, i, 1)
      if (c == "\"") {
        i++
        out = ""
        while (i <= length(obj)) {
          c = substr(obj, i, 1)
          if (c == "\\") {
            i++
            if (i <= length(obj)) out = out substr(obj, i, 1)
          } else if (c == "\"") {
            break
          } else {
            out = out c
          }
          i++
        }
        printf "%s", out
      } else {
        rest = substr(obj, i)
        if (match(rest, /^-?[0-9]+|true|false/)) {
          printf "%s", substr(rest, RSTART, RLENGTH)
        }
      }
    }
  '
}

hm_html_objects() {
  local json="${1:-}" body
  body="${json#*[}"
  body="${body%]*}"
  [[ -n "${body}" && "${body}" != "${json}" ]] || return 0
  printf '%s' "${body}" | awk 'BEGIN { RS = "\\},\\{" }
    {
      line = $0
      gsub(/\n/, "", line)
      if (line == "") next
      if (substr(line, 1, 1) != "{") line = "{" line
      if (substr(line, length(line), 1) != "}") line = line "}"
      print line
    }
  '
}

hm_html_table_json() {
  local title="${1:-}" file="${2:-}"
  shift 2 || true
  local -a keys=("$@")
  printf '<h2>%s</h2>\n' "$(hm_html_escape "${title}")"
  if [[ ! -s "${file}" ]]; then
    printf '<p>brak danych</p>\n'
    return 0
  fi
  local json obj k val any=0
  json="$(cat "${file}")"
  printf '<table>\n<tr>'
  for k in "${keys[@]}"; do
    printf '<th>%s</th>' "$(hm_html_escape "${k}")"
  done
  printf '</tr>\n'
  while IFS= read -r obj || [[ -n "${obj}" ]]; do
    [[ -n "${obj}" ]] || continue
    any=1
    printf '<tr>'
    for k in "${keys[@]}"; do
      val="$(hm_html_field "${obj}" "${k}")"
      printf '<td>%s</td>' "$(hm_html_cell "${val}")"
    done
    printf '</tr>\n'
  done < <(hm_html_objects "${json}")
  printf '</table>\n'
  if [[ "${any}" -eq 0 ]]; then
    printf '<p>brak wierszy</p>\n'
  fi
}

hm_html_kv() {
  local label="${1:-}" value="${2:-}"
  printf '<tr><th>%s</th><td>%s</td></tr>\n' \
    "$(hm_html_escape "${label}")" "$(hm_html_cell "${value}")"
}
