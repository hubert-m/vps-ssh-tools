#!/usr/bin/env bash
# Chrome DevTools HTTP — tylko loopback. Bez webSocketDebuggerUrl w wyjściu.

if [[ -n "${HM_CHROME_CDP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HM_CHROME_CDP_LOADED=1

# Host z URL CDP (bez userinfo i portu).
hm_chrome_cdp_host() {
  local url="${1:-${CHROME_CDP_URL:-}}"
  local rest host
  case "${url}" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  rest="${url#*://}"
  rest="${rest%%/*}"
  rest="${rest##*@}"
  if [[ "${rest}" == \[* ]]; then
    host="${rest#\[}"
    host="${host%%\]*}"
  else
    host="${rest%%:*}"
  fi
  [[ -n "${host}" ]] || return 1
  printf '%s' "${host}"
}

hm_chrome_cdp_is_loopback() {
  local url="${1:-${CHROME_CDP_URL:-}}" host
  host="$(hm_chrome_cdp_host "${url}")" || return 1
  case "${host}" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}

hm_chrome_cdp_port() {
  local url="${1:-${CHROME_CDP_URL:-}}" rest port
  case "${url}" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  rest="${url#*://}"
  rest="${rest%%/*}"
  rest="${rest##*@}"
  if [[ "${rest}" =~ ^\[.*\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "${rest}" =~ ^[^:]+:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [[ "${port}" -ge 1 && "${port}" -le 65535 ]] || return 1
  printf '%s' "${port}"
}

# Do wypisania: bez user:hasło@.
hm_chrome_cdp_url_display() {
  local url="${1:-${CHROME_CDP_URL:-}}"
  if [[ "${url}" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@([^[:space:]]+)$ ]]; then
    printf '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  printf '%s' "${url}"
}

hm_chrome_service_allowed() {
  local u="${1:-}"
  u="${u%.service}"
  case "${u}" in
    chrome-headless|chromium-headless|google-chrome-headless) return 0 ;;
    *) return 1 ;;
  esac
}

hm_chrome_unit() {
  local u="${CHROME_SERVICE:-}"
  u="${u%.service}"
  hm_chrome_service_allowed "${u}" || return 1
  printf '%s' "${u}"
}

hm_chrome_target_id_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{8,64}$ ]]
}

hm_chrome_cdp_path_ok() {
  local path="${1:-}" id
  case "${path}" in
    *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*'|'*) return 1 ;;
  esac
  case "${path}" in
    /json/version|/json/list|/json) return 0 ;;
    /json/close/*|/json/activate/*)
      id="${path##*/}"
      [[ "${path}" == "/json/close/${id}" || "${path}" == "/json/activate/${id}" ]] || return 1
      hm_chrome_target_id_ok "${id}"
      ;;
    /json/new\?*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

hm_chrome_one_line() {
  local s="${1:-}" max="${2:-180}" i c code out="" word redacted=""
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  local len="${#s}"
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    printf -v code '%d' "'${c}" 2>/dev/null || code=32
    if (( code < 32 || code == 127 || (code >= 128 && code <= 159) )); then
      continue
    fi
    out+="${c}"
  done
  for word in ${out}; do
    if [[ "${word}" == *:*@* ]]; then
      word="[redacted]@${word##*@}"
    fi
    redacted+="${word} "
  done
  s="${redacted% }"
  if [[ "${#s}" -gt "${max}" ]]; then
    s="${s:0:${max}}…"
  fi
  printf '%s' "${s}"
}

# Wartość string JSON na głębokości 1 (płaski obiekt). Brak klucza → rc 1.
hm_chrome_json_string_field() {
  local obj="${1:-}" want="${2:-}"
  local i len=0 c buf="" mode="seek" key="" uhex=""
  local in_str=0 esc=0 depth=0
  [[ -n "${want}" ]] || return 1
  len=${#obj}
  [[ "${len}" -le 2000000 ]] || return 1
  for ((i = 0; i < len; i++)); do
    c="${obj:i:1}"
    if [[ "${in_str}" -eq 1 ]]; then
      if [[ "${esc}" -eq 2 ]]; then
        uhex+="${c}"
        if [[ "${#uhex}" -eq 4 ]]; then
          if [[ "${uhex}" =~ ^[0-9A-Fa-f]{4}$ ]]; then
            buf+="$(printf "\\u%s" "${uhex}" 2>/dev/null || true)"
          else
            buf+="${uhex}"
          fi
          uhex=""
          esc=0
        fi
        continue
      fi
      if [[ "${esc}" -eq 1 ]]; then
        case "${c}" in
          n) buf+=$'\n' ;;
          t) buf+=$'\t' ;;
          r) buf+=$'\r' ;;
          u) esc=2; uhex="" ;;
          *) buf+="${c}" ;;
        esac
        [[ "${esc}" -eq 2 ]] || esc=0
        continue
      fi
      if [[ "${c}" == '\' ]]; then
        esc=1
        continue
      fi
      if [[ "${c}" == '"' ]]; then
        in_str=0
        if [[ "${mode}" == "key" ]]; then
          key="${buf}"
          mode="colon"
        elif [[ "${mode}" == "value" ]]; then
          if [[ "${key}" == "${want}" && "${depth}" -eq 1 ]]; then
            printf '%s' "${buf}"
            return 0
          fi
          mode="seek"
          key=""
        fi
        buf=""
        continue
      fi
      buf+="${c}"
      continue
    fi
    case "${c}" in
      '{')
        depth=$((depth + 1))
        [[ "${mode}" == "colon" ]] && mode="seek"
        ;;
      '}')
        depth=$((depth - 1))
        ;;
      '"')
        in_str=1
        buf=""
        if [[ "${mode}" == "colon" ]]; then
          mode="value"
        else
          mode="key"
        fi
        ;;
      ',')
        mode="seek"
        key=""
        ;;
      [[:space:]]|':')
        ;;
      *)
        ;;
    esac
  done
  return 1
}

hm_chrome_split_objects() {
  local raw="${1:-}"
  local i len=0 c depth=0 in_str=0 esc=0 obj=""
  len=${#raw}
  [[ "${len}" -le 2000000 ]] || return 1
  for ((i = 0; i < len; i++)); do
    c="${raw:i:1}"
    if [[ "${in_str}" -eq 1 ]]; then
      obj+="${c}"
      if [[ "${esc}" -eq 1 ]]; then
        esc=0
      elif [[ "${c}" == '\' ]]; then
        esc=1
      elif [[ "${c}" == '"' ]]; then
        in_str=0
      fi
      continue
    fi
    case "${c}" in
      '"')
        in_str=1
        [[ "${depth}" -gt 0 ]] && obj+="${c}"
        ;;
      '{')
        if [[ "${depth}" -eq 0 ]]; then
          obj="{"
          depth=1
        else
          depth=$((depth + 1))
          obj+="${c}"
        fi
        ;;
      '}')
        if [[ "${depth}" -le 0 ]]; then
          obj=""
          continue
        fi
        obj+="${c}"
        depth=$((depth - 1))
        if [[ "${depth}" -eq 0 && -n "${obj}" ]]; then
          printf '%s\0' "${obj}"
          obj=""
        fi
        ;;
      *)
        [[ "${depth}" -gt 0 ]] && obj+="${c}"
        ;;
    esac
  done
  return 0
}

hm_chrome_format_targets_bash() {
  local raw obj type id title url
  raw="$(cat || true)"
  [[ -n "${raw}" ]] || return 0
  while IFS= read -r -d '' obj; do
    [[ -n "${obj}" ]] || continue
    type="$(hm_chrome_json_string_field "${obj}" type || true)"
    id="$(hm_chrome_json_string_field "${obj}" id || true)"
    title="$(hm_chrome_json_string_field "${obj}" title || true)"
    url="$(hm_chrome_json_string_field "${obj}" url || true)"
    hm_chrome_target_id_ok "${id}" || continue
    type="$(hm_chrome_one_line "${type}" 32)"
    title="$(hm_chrome_one_line "${title}" 80)"
    url="$(hm_chrome_one_line "${url}" 180)"
    printf '%s\t%s\t%s\t%s\n' "${type}" "${id}" "${title}" "${url}"
  done < <(hm_chrome_split_objects "${raw}")
  return 0
}

hm_chrome_format_targets_py() {
  python3 -c "$(cat <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    data = [data]
if not isinstance(data, list):
    sys.exit(0)

def one(s, n):
    if s is None:
        s = ""
    s = str(s)
    s = s.replace("\n", " ").replace("\r", " ").replace("\t", " ").replace("\x1b", "")
    if len(s) > n:
        s = s[:n] + "…"
    return s

for t in data:
    if not isinstance(t, dict):
        continue
    i = t.get("id") or ""
    if not isinstance(i, str):
        i = str(i)
    if len(i) < 8 or len(i) > 64:
        continue
    ok = True
    for ch in i:
        if ch.isalnum() or ch in "_-":
            continue
        ok = False
        break
    if not ok:
        continue
    sys.stdout.write("%s\t%s\t%s\t%s\n" % (
        one(t.get("type"), 32), i, one(t.get("title"), 80), one(t.get("url"), 180)))
PY
)"
}

hm_chrome_format_targets() {
  local raw
  raw="$(cat || true)"
  [[ -n "${raw}" ]] || return 0
  if [[ "${HM_CHROME_JSON_BASH:-}" != "1" ]] && hm_have_cmd python3; then
    if printf '%s' "${raw}" | hm_chrome_format_targets_py; then
      return 0
    fi
  fi
  printf '%s' "${raw}" | hm_chrome_format_targets_bash
  return 0
}

hm_chrome_print_version_fields() {
  local raw key val
  raw="$(cat || true)"
  for key in Browser Protocol-Version V8-Version WebKit-Version User-Agent; do
    val="$(hm_chrome_json_string_field "${raw}" "${key}" || true)"
    val="$(hm_chrome_one_line "${val}" 200)"
    printf '%s\t%s\n' "${key}" "${val}"
  done
}

hm_chrome_url_allowed() {
  local u="${1:-}"
  [[ "${#u}" -ge 1 && "${#u}" -le 2000 ]] || return 1
  [[ "${u}" != *$'\n'* && "${u}" != *$'\r'* && "${u}" != *$'\t'* ]] || return 1
  case "${u}" in
    *[[:cntrl:]]*|*[\'\"\\\`\$]*) return 1 ;;
    *' '*) return 1 ;;
  esac
  if [[ "${u}" =~ [^[:ascii:]] ]]; then
    return 1
  fi
  if [[ "${u}" == "about:blank" ]]; then
    return 0
  fi
  case "${u}" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  local rest="${u#*://}"
  [[ "${rest}" != *"@"* ]] || return 1
  local hostport="${rest%%/*}"
  hostport="${hostport%%\?*}"
  hostport="${hostport%%\#*}"
  [[ -n "${hostport}" && "${hostport}" != ":"* ]] || return 1
  return 0
}

hm_chrome_urlencode() {
  local s="${1:-}" i c hex out=""
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "${c}" in
      [a-zA-Z0-9._~-]) out+="${c}" ;;
      *)
        printf -v hex '%%%02X' "'${c}"
        out+="${hex}"
        ;;
    esac
  done
  printf '%s' "${out}"
}

hm_chrome_open_path() {
  local enc
  hm_chrome_url_allowed "${1:-}" || return 1
  enc="$(hm_chrome_urlencode "${1}")"
  printf '%s' "/json/new?${enc}"
}

hm_chrome_cdp_curl() {
  local method="${1:-}" path="${2:-}" raw
  case "${method}" in
    GET|PUT) ;;
    *) return 1 ;;
  esac
  hm_chrome_cdp_is_loopback || return 1
  hm_chrome_cdp_path_ok "${path}" || return 1
  hm_have_cmd curl || return 1
  if [[ "${method}" == "PUT" ]]; then
    raw="$(curl -sf -g --path-as-is --max-redirs 0 --proto '=http,https' \
      --max-time 8 --max-filesize 2097152 \
      -X PUT --data-binary '' \
      -- "${CHROME_CDP_URL}${path}" 2>/dev/null || true)"
  else
    raw="$(curl -sf -g --path-as-is --max-redirs 0 --proto '=http,https' \
      --max-time 8 --max-filesize 2097152 \
      -X GET \
      -- "${CHROME_CDP_URL}${path}" 2>/dev/null || true)"
  fi
  [[ -n "${raw}" ]] || return 1
  printf '%s' "${raw}"
}

hm_chrome_active_port_from_file() {
  local f="${1:-}" line port
  [[ -f "${f}" && ! -L "${f}" ]] || return 1
  IFS= read -r line < "${f}" || return 1
  [[ "${line}" =~ ^[0-9]{1,5}$ ]] || return 1
  port=$((10#${line}))
  [[ "${port}" -ge 1 && "${port}" -le 65535 ]] || return 1
  printf '%s' "${port}"
}

hm_chrome_cdp_from_active_port() {
  local data port file raw br
  declare -F hm_chrome_user_data_dir >/dev/null 2>&1 || return 1
  data="$(hm_chrome_user_data_dir 2>/dev/null || true)"
  [[ -n "${data}" ]] || return 1
  file="${data}/DevToolsActivePort"
  port="$(hm_chrome_active_port_from_file "${file}" 2>/dev/null || true)"
  [[ -n "${port}" ]] || return 1
  hm_have_cmd curl || return 1
  raw="$(curl -sf -g --path-as-is --max-redirs 0 --proto '=http,https' \
    --max-time 2 --max-filesize 65536 \
    -- "http://127.0.0.1:${port}/json/version" 2>/dev/null || true)"
  [[ -n "${raw}" ]] || return 1
  br="$(hm_chrome_json_string_field "${raw}" Browser || true)"
  [[ -n "${br}" ]] || return 1
  CHROME_CDP_URL="http://127.0.0.1:${port}"
  CHROME_CDP_BROWSER="${br}"
  return 0
}

hm_chrome_ensure_cdp() {
  if declare -F hm_chrome_require >/dev/null 2>&1; then
    hm_chrome_require || return 1
  fi
  if [[ -z "${CHROME_CDP_URL:-}" ]] && declare -F hm_chrome_cdp_probe >/dev/null 2>&1; then
    hm_chrome_cdp_probe 2>/dev/null || true
  fi
  if [[ -z "${CHROME_CDP_URL:-}" ]]; then
    hm_chrome_cdp_from_active_port || true
  fi
  if [[ -z "${CHROME_CDP_URL:-}" ]]; then
    hm_err "Brak CDP. Uruchom Chrome z --remote-debugging-port albo ustaw FORCE_CHROME_CDP=http://127.0.0.1:PORT."
    return 1
  fi
  if ! hm_chrome_cdp_is_loopback; then
    hm_err "CDP $(hm_chrome_cdp_url_display) nie jest na localhost. Karty, open i close działają tylko dla 127.0.0.1, localhost i ::1."
    return 1
  fi
  return 0
}

hm_chrome_addr_is_loopback() {
  local a="${1:-}" host
  if [[ "${a}" == \[* ]]; then
    host="${a#\[}"
    host="${host%%\]*}"
  else
    host="${a%:*}"
  fi
  case "${host}" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}

hm_chrome_listen_addrs() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if [[ "${HMTOOLS_TEST:-}" == "1" && -n "${HM_CHROME_SS_FILE:-}" ]]; then
    awk -v port="${port}" '
      {
        for (i = 1; i <= NF; i++) {
          if ($i ~ ":" port "$") print $i
        }
      }
    ' "${HM_CHROME_SS_FILE}"
    return 0
  fi
  hm_have_cmd ss || return 1
  ss -H -ltn 2>/dev/null | awk -v port="${port}" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ":" port "$") print $i
      }
    }
  '
}

hm_chrome_info_listen() {
  local port lines bad=0 any=0 line shown=""
  port="$(hm_chrome_cdp_port 2>/dev/null || true)"
  [[ -n "${port}" ]] || return 0
  lines="$(hm_chrome_listen_addrs "${port}" 2>/dev/null || true)"
  [[ -n "${lines}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    any=1
    if ! hm_chrome_addr_is_loopback "${line}"; then
      bad=1
    fi
    if [[ -n "${shown}" ]]; then
      shown+=", ${line}"
    else
      shown="${line}"
    fi
  done <<< "${lines}"
  [[ "${any}" -eq 1 ]] || return 0
  if [[ "${bad}" -eq 1 ]]; then
    hm_warn "  Listen   : port ${port} słucha szerzej niż localhost (${shown}). Karty i tak idą tylko na $(hm_chrome_cdp_url_display)."
  else
    echo "  Listen   : ${shown}"
  fi
}

hm_chrome_page_count() {
  local raw n
  raw="$(hm_chrome_cdp_curl GET /json/list 2>/dev/null || true)"
  [[ -n "${raw}" ]] || return 1
  n="$(printf '%s' "${raw}" | hm_chrome_format_targets | awk -F '\t' '$1=="page"{c++} END{print c+0}')"
  [[ "${n}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${n}"
}

hm_chrome_info_extra() {
  local raw proto v8 pages
  if [[ -z "${CHROME_CDP_URL:-}" ]] || ! hm_chrome_cdp_is_loopback; then
    if [[ -n "${CHROME_CDP_URL:-}" ]]; then
      echo "  Tabs     : — (CDP spoza localhost)"
    else
      echo "  Tabs     : —"
    fi
    return 0
  fi
  raw="$(hm_chrome_cdp_curl GET /json/version 2>/dev/null || true)"
  if [[ -n "${raw}" ]]; then
    proto="$(hm_chrome_json_string_field "${raw}" Protocol-Version || true)"
    v8="$(hm_chrome_json_string_field "${raw}" V8-Version || true)"
    proto="$(hm_chrome_one_line "${proto}" 40)"
    v8="$(hm_chrome_one_line "${v8}" 40)"
    if [[ -n "${proto}" || -n "${v8}" ]]; then
      echo "  Protocol : ${proto:--}    V8: ${v8:--}"
    fi
  fi
  if pages="$(hm_chrome_page_count 2>/dev/null)"; then
    echo "  Tabs     : ${pages} stron (chrome tabs)"
  else
    echo "  Tabs     : —"
  fi
  hm_chrome_info_listen || true
  return 0
}

hm_chrome_find_target() {
  local want="${1:-}" raw type id title url
  hm_chrome_target_id_ok "${want}" || return 1
  raw="$(hm_chrome_cdp_curl GET /json/list)" || return 1
  while IFS=$'\t' read -r type id title url; do
    [[ -n "${id}" ]] || continue
    if [[ "${id}" == "${want}" ]]; then
      printf '%s\t%s\t%s\t%s\n' "${type}" "${id}" "${title}" "${url}"
      return 0
    fi
  done < <(printf '%s' "${raw}" | hm_chrome_format_targets)
  return 1
}

hm_chrome_confirm() {
  local title="$1" warning="$2" yes="$3"
  shift 3 || true
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "${title}" "${warning}" --yes "$@"
  else
    hm_confirm_plan "${title}" "${warning}" "$@"
  fi
}

cmd_chrome_tabs() {
  local pages=1 a raw type id title url shown=0 other=0
  for a in "$@"; do
    case "${a}" in
      --all) pages=0 ;;
      --pages) pages=1 ;;
      -h|--help)
        hm_info "Użycie: chrome tabs [--pages|--all]"
        hm_info "Domyślnie tylko type=page. Token debuggera nie jest wypisywany."
        return 0
        ;;
      *)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
    esac
  done
  hm_chrome_ensure_cdp || return 1
  raw="$(hm_chrome_cdp_curl GET /json/list)" || {
    hm_err "CDP /json/list nie odpowiada."
    return 1
  }
  echo "${C_BOLD:-}Karty Chrome${C_RESET:-}  ($(hm_chrome_cdp_url_display))"
  hm_table_begin
  hm_table_row TYPE ID TITLE URL
  while IFS=$'\t' read -r type id title url; do
    [[ -n "${id}" ]] || continue
    if [[ "${pages}" -eq 1 && "${type}" != "page" ]]; then
      other=$((other + 1))
      continue
    fi
    shown=$((shown + 1))
    hm_table_row "${type:--}" "${id}" "${title:--}" "${url:--}"
  done < <(printf '%s' "${raw}" | hm_chrome_format_targets)
  if [[ "${shown}" -eq 0 ]]; then
    hm_info "Brak kart do pokazania."
  else
    hm_table_print
  fi
  if [[ "${other}" -gt 0 ]]; then
    hm_info "Ukryte targety (worker/browser): ${other}. Pokaż: chrome tabs --all"
  fi
  return 0
}

cmd_chrome_open() {
  local url="" yes=0 a path raw line type id title turl
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help)
        hm_info "Użycie: chrome open <http(s)://…|about:blank> [--yes]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -n "${url}" ]]; then
          hm_err "Podaj jeden URL."
          return 1
        fi
        url="${a}"
        ;;
    esac
  done
  if [[ -z "${url}" ]]; then
    hm_err "Użycie: chrome open <http(s)://…|about:blank> [--yes]"
    return 1
  fi
  if ! hm_chrome_url_allowed "${url}"; then
    hm_err "URL odrzucony. Dozwolone: http, https, about:blank. Bez file/javascript/data i bez user:hasło@."
    return 1
  fi
  hm_chrome_ensure_cdp || return 1
  path="$(hm_chrome_open_path "${url}")" || return 1
  hm_chrome_cdp_path_ok "${path}" || return 1
  hm_chrome_confirm "Nowa karta Chrome" \
    "Chrome otworzy ten adres w działającej instancji." \
    "${yes}" \
    "PUT ${path%%\?*}  ${url}" || {
    hm_info "Anulowano."
    return 1
  }
  raw="$(hm_chrome_cdp_curl PUT "${path}")" || {
    hm_err "Nie udało się otworzyć karty (Chrome 111+ wymaga PUT /json/new)."
    return 1
  }
  line="$(printf '%s' "${raw}" | hm_chrome_format_targets | head -1 || true)"
  if [[ -z "${line}" ]]; then
    hm_ok "Wysłano otwarcie karty."
    return 0
  fi
  IFS=$'\t' read -r type id title turl <<< "${line}"
  hm_ok "Otwarto kartę ${id}"
  echo "  title : ${title:--}"
  echo "  url   : ${turl:--}"
  return 0
}

hm_chrome_tab_act() {
  local act="$1"
  shift || true
  local id="" yes=0 a row type title url endpoint label
  for a in "$@"; do
    case "${a}" in
      --yes|-y) yes=1 ;;
      -h|--help)
        hm_info "Użycie: chrome tab ${act} <id> [--yes]"
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -n "${id}" ]]; then
          hm_err "Podaj jedno id."
          return 1
        fi
        id="${a}"
        ;;
    esac
  done
  if ! hm_chrome_target_id_ok "${id}"; then
    hm_err "Nieprawidłowe id karty."
    return 1
  fi
  hm_chrome_ensure_cdp || return 1
  row="$(hm_chrome_find_target "${id}")" || {
    hm_err "Brak karty o id ${id}. Sprawdź: chrome tabs --all"
    return 1
  }
  IFS=$'\t' read -r type id title url <<< "${row}"
  if [[ "${act}" == "close" ]]; then
    endpoint="/json/close/${id}"
    label="Zamknąć kartę"
  else
    endpoint="/json/activate/${id}"
    label="Aktywować kartę"
  fi
  hm_chrome_cdp_path_ok "${endpoint}" || return 1
  hm_chrome_confirm "${label}" \
    "Operacja na żywej instancji Chrome." \
    "${yes}" \
    "${type:-target} ${id}" \
    "${title:--}" \
    "${url:--}" || {
    hm_info "Anulowano."
    return 1
  }
  hm_chrome_cdp_curl GET "${endpoint}" >/dev/null || {
    hm_err "CDP odrzuciło ${act} dla ${id}."
    return 1
  }
  if [[ "${act}" == "close" ]]; then
    hm_ok "Zamknięto kartę ${id}"
  else
    hm_ok "Aktywowano kartę ${id}"
  fi
  return 0
}

cmd_chrome_tab() {
  local act="${1:-}"
  shift || true
  case "${act}" in
    close|rm|del|delete) hm_chrome_tab_act close "$@" ;;
    activate|focus) hm_chrome_tab_act activate "$@" ;;
    ""|help|-h|--help)
      hm_info "Użycie: chrome tab close <id> [--yes] | chrome tab activate <id> [--yes]"
      ;;
    *)
      hm_err "Użycie: chrome tab close <id> | chrome tab activate <id>"
      return 1
      ;;
  esac
}

cmd_chrome_cdp() {
  local raw key val
  hm_chrome_ensure_cdp || return 1
  raw="$(hm_chrome_cdp_curl GET /json/version)" || {
    hm_err "CDP /json/version nie odpowiada."
    return 1
  }
  echo "${C_BOLD:-}CDP${C_RESET:-}  $(hm_chrome_cdp_url_display)"
  while IFS=$'\t' read -r key val; do
    [[ -n "${key}" ]] || continue
    printf '  %-18s %s\n' "${key}" "${val:--}"
  done < <(printf '%s' "${raw}" | hm_chrome_print_version_fields)
  return 0
}
