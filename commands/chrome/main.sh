#!/usr/bin/env bash
# Moduł: chrome — diagnostyka Chrome/Chromium (headless)

_hm_cmd_help chrome <<'EOF'
Użycie:
  chrome | info | status   Binarka, wersja, źródło detekcji
  chrome which             Tylko ścieżka binarki
  chrome version           Pełne --version
  chrome test              Smoke headless (--dump-dom about:blank)

Aliasy: chromium, headless
Nadpisanie: FORCE_CHROME_BIN=/ścieżka w hmtools.conf
EOF

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
  if [[ "${CHROME:-no}" != "yes" || -z "${CHROME_BIN:-}" || ! -x "${CHROME_BIN}" ]]; then
    hm_err "Brak Chrome/Chromium — nie wykryto binarki."
    hm_info "Szukane: google-chrome-stable, google-chrome, chromium, chromium-browser, chrome, /snap/bin/chromium"
    hm_info "Nadpisanie: FORCE_CHROME_BIN=/ścieżka w hmtools.conf   | detect"
    return 1
  fi
  return 0
}

cmd_chrome_info() {
  # Nie wołaj hm_detect_all — wystarczy chrome (+ już znany stos ze startu)
  hm_chrome_require || true
  if [[ "${CHROME:-no}" == "yes" && -n "${CHROME_BIN:-}" && -z "${CHROME_VERSION:-}" ]]; then
    hm_chrome_fetch_version "${CHROME_BIN}" || true
  fi
  echo "${C_BOLD}Chrome / Chromium (headless)${C_RESET}"
  echo "  Detected : ${CHROME:-no}${CHROME_SOURCE:+  [${CHROME_SOURCE}]}"
  echo "  Binary   : ${CHROME_BIN:--}"
  echo "  Version  : ${CHROME_VERSION:--}"
  if [[ "${CHROME:-no}" == "yes" && -n "${CHROME_BIN:-}" ]]; then
    echo "  Headless : tak (--headless; smoke: chrome test)"
  else
    echo "  Headless : —"
  fi
}

cmd_chrome_test() {
  hm_chrome_require || return 1
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
  case "${sub}" in
    ""|info|status|show)
      cmd_chrome_info
      ;;
    which|path|bin)
      hm_chrome_require || return 1
      printf '%s\n' "${CHROME_BIN}"
      ;;
    version|ver|-v|--version)
      hm_chrome_require || return 1
      if ! hm_run_timeout 3 "${CHROME_BIN}" --version; then
        local vrc=$?
        if [[ "${vrc}" -eq 124 ]]; then
          hm_err "Timeout (3s) przy „${CHROME_BIN} --version” — binarka nie odpowiada (zawieszona?)."
        else
          hm_err "Nie udało się odczytać wersji (rc=${vrc}): ${CHROME_BIN}"
        fi
        return "${vrc}"
      fi
      ;;
    test|smoke|check)
      cmd_chrome_test
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
