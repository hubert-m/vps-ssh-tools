#!/usr/bin/env bash
# Moduł: chrome — diagnostyka Chrome/Chromium (headless)

_hm_cmd_help chrome <<'EOF'
Użycie:
  chrome | info | status   Binarka, wersja, CDP, unit, liczba kart
  chrome which             Tylko ścieżka binarki
  chrome version           Pełne --version (lub CDP Browser)
  chrome cdp               Wersja protokołu / V8 / User-Agent (bez tokenu WS)
  chrome test              Smoke: CDP /json/version albo --headless --dump-dom
  chrome tabs [--all]      Otwarte karty (CDP /json/list, tylko localhost)
  chrome open <url> [--yes]
                           Nowa karta: http, https albo about:blank
  chrome tab close <id> [--yes]
  chrome tab activate <id> [--yes]
  chrome disk              Rozmiar buildów Puppeteer, /tmp i cache profilu
  chrome clean [--execute] [--yes]
                           Domyślnie dry-run. Zostawia działającą binarkę,
                           cookies i historię
  chrome ps                PID, RAM, nasłuch portu debuggera
  chrome restart [--yes]   systemctl restart znanego unitu headless
  chrome log [N]           journalctl (N=1..200, domyślnie 40)

Aliasy: chromium, headless
Detekcja: PATH → ścieżki systemowe → systemd (chrome-headless) →
  Puppeteer ~/.cache/puppeteer/chrome → CDP :9222
Nadpisanie: FORCE_CHROME_BIN=/ścieżka  FORCE_CHROME_CDP=http://127.0.0.1:9222
CDP (karty, open, close) tylko dla 127.0.0.1, localhost i ::1.
Wyjście nie zawiera webSocketDebuggerUrl.
EOF

_HM_CHROME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cdp.sh
source "${_HM_CHROME_DIR}/cdp.sh"
# shellcheck source=clean.sh
source "${_HM_CHROME_DIR}/clean.sh"

hm_chrome_require() {
  hm_detect_chrome 2>/dev/null || true
  if [[ -n "${FORCE_CHROME_BIN:-}" ]]; then
    if [[ -x "${FORCE_CHROME_BIN}" ]]; then
      CHROME="yes"
      CHROME_BIN="${FORCE_CHROME_BIN}"
      # zawsze FORCE — nie zostawiaj etykiety z hm_detect_chrome (bin:chromium)
      CHROME_SOURCE="override:FORCE_CHROME_BIN"
    elif [[ "${_HM_FORCE_CHROME_WARNED:-0}" != "1" ]]; then
      _HM_FORCE_CHROME_WARNED=1
      hm_warn "FORCE_CHROME_BIN nie jest wykonywalne: ${FORCE_CHROME_BIN}"
    fi
  fi
  if [[ "${CHROME:-no}" != "yes" ]]; then
    hm_err "Brak Chrome/Chromium — nie wykryto binarki ani CDP."
    hm_info "Szukane: PATH (google-chrome…), /opt/google/chrome, systemd chrome-headless,"
    hm_info "  /home/*/.cache/puppeteer/chrome/…/chrome, CDP http://127.0.0.1:9222"
    hm_info "Nadpisanie: FORCE_CHROME_BIN=…  FORCE_CHROME_CDP=…  | detect"
    return 1
  fi
  return 0
}

hm_chrome_require_bin() {
  hm_chrome_require || return 1
  if [[ -z "${CHROME_BIN:-}" || ! -x "${CHROME_BIN}" ]]; then
    hm_err "Wykryto Chrome (CDP/usługa), ale brak lokalnej binarki do tej komendy."
    hm_info "Ustaw FORCE_CHROME_BIN=… albo użyj: chrome info / chrome test (CDP)."
    return 1
  fi
  return 0
}

cmd_chrome_info() {
  # Nie wołaj hm_detect_all — wystarczy chrome (+ już znany stos ze startu)
  hm_chrome_require || true
  if [[ -n "${CHROME_BIN:-}" && -x "${CHROME_BIN}" && -z "${CHROME_VERSION:-}" ]]; then
    hm_chrome_fetch_version "${CHROME_BIN}" || true
  fi
  # odśwież CDP (port mógł wstać po detect na starcie)
  if [[ -z "${CHROME_CDP_URL:-}" ]]; then
    hm_chrome_cdp_probe 2>/dev/null || true
  fi
  echo "${C_BOLD}Chrome / Chromium (headless)${C_RESET}"
  echo "  Detected : ${CHROME:-no}${CHROME_SOURCE:+  [${CHROME_SOURCE}]}"
  echo "  Binary   : ${CHROME_BIN:--}"
  echo "  Version  : ${CHROME_VERSION:-${CHROME_CDP_BROWSER:--}}"
  if [[ -n "${CHROME_SERVICE:-}" ]]; then
    local st="unknown"
    if hm_have_cmd systemctl; then
      st="$(systemctl is-active "${CHROME_SERVICE}" 2>/dev/null || echo inactive)"
    fi
    echo "  Service  : ${CHROME_SERVICE} (${st})"
  fi
  if [[ -n "${CHROME_CDP_URL:-}" ]]; then
    echo "  CDP      : $(hm_chrome_cdp_url_display)  (${CHROME_CDP_BROWSER:-ok})"
  else
    echo "  CDP      : —"
  fi
  hm_chrome_info_extra || true
  if [[ -n "${CHROME_BIN:-}" && -x "${CHROME_BIN}" ]]; then
    echo "  Headless : tak (--headless; smoke: chrome test)"
  elif [[ -n "${CHROME_CDP_URL:-}" ]]; then
    echo "  Headless : daemon CDP (smoke: chrome test → /json/version)"
  else
    echo "  Headless : —"
  fi
}

cmd_chrome_test() {
  hm_chrome_require || return 1

  # Preferuj żywy CDP (typowy chrome-headless.service + Puppeteer)
  if [[ -z "${CHROME_CDP_URL:-}" ]]; then
    hm_chrome_cdp_probe 2>/dev/null || true
  fi
  if [[ -n "${CHROME_CDP_URL:-}" ]]; then
    echo "${C_BOLD}Chrome CDP smoke test${C_RESET}"
    echo "  URL: $(hm_chrome_cdp_url_display)/json/version"
    local raw
    raw="$(curl -sf --max-time 3 "${CHROME_CDP_URL}/json/version" 2>/dev/null || true)"
    if [[ -n "${raw}" ]] && printf '%s' "${raw}" | grep -qiE '"Browser"|"webSocketDebuggerUrl"'; then
      hm_ok "CDP OK — $(printf '%s' "${raw}" | sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      return 0
    fi
    hm_warn "CDP ${CHROME_CDP_URL} nie odpowiada — próbuję lokalny --headless…"
  fi

  hm_chrome_require_bin || return 1
  echo "${C_BOLD}Chrome headless smoke test${C_RESET}"
  echo "  Bin: ${CHROME_BIN}"
  hm_status_line "Uruchamianie --headless --dump-dom about:blank..."
  local out rc=0
  out="$(
    hm_run_timeout 15 "${CHROME_BIN}" \
      --headless \
      --disable-gpu \
      --no-sandbox \
      --disable-dev-shm-usage \
      --dump-dom \
      about:blank \
      2>/dev/null
  )" || rc=$?
  hm_status_clear
  if [[ "${rc}" -eq 0 ]] && printf '%s' "${out}" | grep -qiE '<html|<!doctype'; then
    hm_ok "Headless OK (otrzymano DOM z about:blank)"
    return 0
  fi
  if [[ "${rc}" -eq 0 && -n "${out}" ]]; then
    hm_ok "Headless zakończony (rc=0), fragment wyjścia:"
    printf '%s\n' "${out}" | head -5 | sed 's/^/  /'
    return 0
  fi
  hm_err "Headless FAIL (rc=${rc})"
  hm_info "Sprawdź zależności lib (np. na serwerze bez GUI) oraz chrome test ponownie."
  return 1
}

cmd_chrome() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|info|status|show)
      cmd_chrome_info
      ;;
    which|path|bin)
      hm_chrome_require_bin || return 1
      printf '%s\n' "${CHROME_BIN}"
      ;;
    version|ver|-v|--version)
      hm_chrome_require || return 1
      if [[ -n "${CHROME_BIN:-}" && -x "${CHROME_BIN}" ]]; then
        # Nie: `if ! cmd; then rc=$?` — po `!` $? = 0 (sukces negacji), gubi 124.
        local vrc=0
        hm_run_timeout 3 "${CHROME_BIN}" --version || vrc=$?
        if [[ "${vrc}" -ne 0 ]]; then
          if [[ "${vrc}" -eq 124 ]]; then
            hm_err "Timeout (3s) przy „${CHROME_BIN} --version” — binarka nie odpowiada (zawieszona?)."
          else
            hm_err "Nie udało się odczytać wersji (rc=${vrc}): ${CHROME_BIN}"
          fi
          return "${vrc}"
        fi
        return 0
      fi
      if [[ -z "${CHROME_CDP_URL:-}" ]]; then
        hm_chrome_cdp_probe 2>/dev/null || true
      fi
      if [[ -n "${CHROME_CDP_BROWSER:-}" ]]; then
        printf '%s\n' "${CHROME_CDP_BROWSER}"
        return 0
      fi
      hm_err "Brak binarki i CDP — nie da się odczytać wersji."
      return 1
      ;;
    test|smoke|check)
      cmd_chrome_test
      ;;
    cdp|protocol)
      cmd_chrome_cdp "$@"
      ;;
    tabs|targets|pages)
      cmd_chrome_tabs "$@"
      ;;
    open|new)
      cmd_chrome_open "$@"
      ;;
    tab)
      cmd_chrome_tab "$@"
      ;;
    disk|du)
      cmd_chrome_disk "$@"
      ;;
    clean|cleanup)
      cmd_chrome_clean "$@"
      ;;
    ps|proc|pid)
      cmd_chrome_ps "$@"
      ;;
    restart)
      cmd_chrome_restart "$@"
      ;;
    log|logs|journal)
      cmd_chrome_log "$@"
      ;;
    help|-h|--help)
      hm_help_topic chrome
      ;;
    *)
      hm_err "Nieznana podkomenda: ${sub}. Zobacz: chrome help"
      return 1
      ;;
  esac
}

_hm_cmd_register chrome cmd_chrome 0 chromium headless
