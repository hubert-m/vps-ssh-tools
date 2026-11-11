#!/usr/bin/env bash
# metrics export — plik tekstowy node_exporter (atomowy zapis) i timer cron.


_HM_METRICS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=json.sh
source "${_HM_METRICS_DIR}/json.sh"

_hm_cmd_help metrics <<'EOF'
Użycie:
  metrics export [--textfile ŚCIEŻKA]
      Zapis hmtools.prom (tmp + mv). Domyślnie
      /var/lib/node_exporter/textfile/hmtools.prom
  metrics timer [--yes]
      Cron co 15 min wołający metrics export.

Serie: wiek ostatniej udanej kopii per zakres, dni certów, stan usług,
uptime HTTP (gdy jest plik monitora), liczba banów, oczekujące poprawki.
EOF

hm_metrics_prom_body() {
  local line scope stamp age ok name unit active enabled
  local domain days status code up fw f2b bans upd
  local -A best=()
  local out="" have_backup=0 have_cert=0 have_svc=0 have_http=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r scope stamp age ok <<<"${line}"
    [[ "${ok}" == "true" || "${ok}" == "1" ]] || continue
    [[ "${age}" =~ ^[0-9]+$ ]] || continue
    [[ -n "${scope}" ]] || continue
    if [[ -z "${best[${scope}]:-}" || "${age}" -lt "${best[${scope}]}" ]]; then
      best["${scope}"]="${age}"
    fi
  done < <(hm_rows_backup_list)
  if [[ "${#best[@]}" -gt 0 ]]; then
    have_backup=1
    out+="# HELP hmtools_backup_age_seconds Wiek ostatniej udanej kopii"
    out+=$'\n'
    out+="# TYPE hmtools_backup_age_seconds gauge"
    out+=$'\n'
    for scope in "${!best[@]}"; do
      out+="hmtools_backup_age_seconds{target=\"$(hm_prom_label "${scope}")\"} ${best[${scope}]}"
      out+=$'\n'
    done
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r domain status days _ <<<"${line}"
    [[ "${days}" =~ ^-?[0-9]+$ ]] || continue
    [[ -n "${domain}" ]] || continue
    if [[ "${have_cert}" -eq 0 ]]; then
      have_cert=1
      out+="# HELP hmtools_cert_days_left Dni do wygaśnięcia certyfikatu"
      out+=$'\n'
      out+="# TYPE hmtools_cert_days_left gauge"
      out+=$'\n'
    fi
    out+="hmtools_cert_days_left{domain=\"$(hm_prom_label "${domain}")\"} ${days}"
    out+=$'\n'
  done < <(hm_rows_ssl)

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r name unit active enabled <<<"${line}"
    [[ "${active}" == "unknown" || -z "${active}" ]] && continue
    if [[ "${have_svc}" -eq 0 ]]; then
      have_svc=1
      out+="# HELP hmtools_service_up 1 gdy usługa jest active"
      out+=$'\n'
      out+="# TYPE hmtools_service_up gauge"
      out+=$'\n'
    fi
    if [[ "${active}" == "active" ]]; then
      up=1
    else
      up=0
    fi
    out+="hmtools_service_up{name=\"$(hm_prom_label "${name}")\"} ${up}"
    out+=$'\n'
  done < <(hm_rows_services)

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS=$'\t' read -r domain up code <<<"${line}"
    [[ -n "${domain}" ]] || continue
    if [[ "${have_http}" -eq 0 ]]; then
      have_http=1
      out+="# HELP hmtools_http_up 1 gdy ostatni check monitor http jest ok"
      out+=$'\n'
      out+="# TYPE hmtools_http_up gauge"
      out+=$'\n'
    fi
    if [[ "${up}" == "true" || "${up}" == "1" ]]; then
      up=1
    else
      up=0
    fi
    out+="hmtools_http_up{domain=\"$(hm_prom_label "${domain}")\"} ${up}"
    out+=$'\n'
  done < <(hm_rows_http)

  line="$(hm_rows_security_status | head -1 || true)"
  if [[ -n "${line}" ]]; then
    IFS=$'\t' read -r fw f2b bans upd <<<"${line}"
    [[ "${bans}" =~ ^[0-9]+$ ]] || bans=0
    out+="# HELP hmtools_fail2ban_bans Liczba banów Fail2Ban"
    out+=$'\n'
    out+="# TYPE hmtools_fail2ban_bans gauge"
    out+=$'\n'
    out+="hmtools_fail2ban_bans ${bans}"
    out+=$'\n'
    if [[ "${upd}" =~ ^[0-9]+$ ]]; then
      out+="# HELP hmtools_security_updates_pending Oczekujące poprawki security"
      out+=$'\n'
      out+="# TYPE hmtools_security_updates_pending gauge"
      out+=$'\n'
      out+="hmtools_security_updates_pending ${upd}"
      out+=$'\n'
    fi
  fi
  printf '%s' "${out}"
}

hm_metrics_atomic_write() {
  local dest="${1:-}" body="${2:-}" dir tmp
  [[ -n "${dest}" ]] || {
    hm_err "Brak ścieżki pliku metryk."
    return 1
  }
  dir="$(dirname "${dest}")"
  mkdir -p "${dir}" || {
    hm_err "Nie mogę utworzyć katalogu ${dir}."
    return 1
  }
  tmp="$(mktemp "${dir}/hmtools.prom.XXXXXX")" || {
    hm_err "Nie mogę utworzyć pliku tymczasowego w ${dir}."
    return 1
  }
  if ! printf '%s\n' "${body}" >"${tmp}"; then
    rm -f "${tmp}"
    hm_err "Zapis metryk nie powiódł się."
    return 1
  fi
  if ! mv -f "${tmp}" "${dest}"; then
    rm -f "${tmp}"
    hm_err "Podmiana ${dest} nie powiodła się."
    return 1
  fi
  return 0
}

hm_metrics_export() {
  local dest="${HM_METRICS_TEXTFILE:-/var/lib/node_exporter/textfile/hmtools.prom}"
  local body=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --textfile)
        dest="${2:-}"
        [[ -n "${dest}" ]] || {
          hm_err "Użycie: metrics export --textfile ŚCIEŻKA"
          return 1
        }
        shift 2 || true
        ;;
      --textfile=*)
        dest="${1#*=}"
        shift
        ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  body="$(hm_metrics_prom_body)" || return 1
  hm_metrics_atomic_write "${dest}" "${body}" || return 1
  printf '%s\n' "${dest}"
}

hm_metrics_timer() {
  local yes=0 dest cron
  dest="${HM_METRICS_TEXTFILE:-/var/lib/node_exporter/textfile/hmtools.prom}"
  cron="${HM_METRICS_CRON:-/etc/cron.d/hmtools-metrics}"
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --yes|-y) yes=1; shift ;;
      *)
        hm_err "Nieznana flaga: ${1}"
        return 1
        ;;
    esac
  done
  local bin="hmtools"
  if [[ -n "${HMTOOLS_ROOT:-}" && -x "${HMTOOLS_ROOT}/hmtools" ]]; then
    bin="${HMTOOLS_ROOT}/hmtools"
  fi
  local line="*/15 * * * * root ${bin} metrics export --textfile ${dest}"
  if [[ "${yes}" -ne 1 ]]; then
    if ! hm_confirm_plan "metrics timer" \
      "Dopisze cron co 15 minut." \
      "Zapis ${cron}" \
      "${line}"; then
      return 1
    fi
  fi
  local dir
  dir="$(dirname "${cron}")"
  mkdir -p "${dir}" || {
    hm_err "Nie mogę utworzyć ${dir}."
    return 1
  }
  printf '%s\n%s\n' "# hmtools metrics" "${line}" >"${cron}" || {
    hm_err "Zapis ${cron} nie powiódł się."
    return 1
  }
  printf '%s\n' "${cron}"
}

cmd_metrics() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    export)
      hm_metrics_export "$@"
      ;;
    timer)
      hm_metrics_timer "$@"
      ;;
    help|-h|--help|"")
      hm_help_topic metrics
      ;;
    *)
      hm_err "Nieznane: metrics ${sub}. metrics help"
      return 1
      ;;
  esac
}

_hm_cmd_register metrics cmd_metrics 1
