#!/usr/bin/env bash
# Runtime .NET dla site new: kanał z releases-index, unit Kestrel, bez mieszania feedów.

if [[ -n "${HMTOOLS_SITE_DOTNET_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
HMTOOLS_SITE_DOTNET_LOADED=1

hm_dotnet_json_str() {
  local s="$1"
  s="${s#*:}"
  s="${s//\"/}"
  s="${s//,/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

hm_dotnet_index_rows() {
  local file="$1" line channel="" runtime="" sdk="" rtype="" phase="" eol=""
  [[ -f "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      *'"channel-version"'*) channel="$(hm_dotnet_json_str "${line}")" ;;
      *'"latest-runtime"'*) runtime="$(hm_dotnet_json_str "${line}")" ;;
      *'"latest-sdk"'*) sdk="$(hm_dotnet_json_str "${line}")" ;;
      *'"release-type"'*) rtype="$(hm_dotnet_json_str "${line}")" ;;
      *'"support-phase"'*) phase="$(hm_dotnet_json_str "${line}")" ;;
      *'"eol-date"'*) eol="$(hm_dotnet_json_str "${line}")" ;;
      *'}'*)
        if [[ -n "${channel}" ]]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${channel}" "${rtype}" "${phase}" "${eol}" "${runtime}" "${sdk}"
          channel=""
          runtime=""
          sdk=""
          rtype=""
          phase=""
          eol=""
        fi
        ;;
    esac
  done < "${file}"
}

hm_dotnet_default_lts() {
  local file="$1" channel rtype phase eol runtime sdk best=""
  while IFS=$'\t' read -r channel rtype phase eol runtime sdk; do
    [[ "${rtype}" == "lts" && "${phase}" == "active" ]] || continue
    if [[ -z "${best}" || "${channel}" > "${best}" ]]; then
      best="${channel}"
    fi
  done < <(hm_dotnet_index_rows "${file}")
  [[ -n "${best}" ]] || return 1
  printf '%s\n' "${best}"
}

hm_dotnet_feeds_mixed() {
  local dir="${1:-${HM_DOTNET_SOURCES:-}}" f ms=0 ub=0
  [[ -d "${dir}" ]] || return 1
  for f in "${dir}"/*; do
    [[ -f "${f}" ]] || continue
    if grep -q 'packages.microsoft.com' "${f}"; then
      ms=1
    fi
    if grep -q 'archive.ubuntu.com' "${f}" && grep -q 'dotnet' "${f}"; then
      ub=1
    fi
  done
  [[ "${ms}" -eq 1 && "${ub}" -eq 1 ]]
}

hm_dotnet_publish_allowed() {
  [[ "${HM_DOTNET_KIND:-sdk}" != "aspnetcore-runtime" ]]
}

hm_dotnet_write_secret() {
  local path="$1" key="$2" val="$3"
  mkdir -p "$(dirname "${path}")"
  umask 077
  printf '%s=%s\n' "${key}" "${val}" >> "${path}"
  chmod 0600 "${path}" 2>/dev/null || true
}

hm_dotnet_redact() {
  local line="$1" envf="$2" kv val rest part rhs
  [[ -f "${envf}" ]] || { printf '%s\n' "${line}"; return 0; }
  while IFS= read -r kv || [[ -n "${kv}" ]]; do
    val="${kv#*=}"
    [[ -n "${val}" ]] || continue
    line="${line//${val}/***}"
    rest="${val}"
    while [[ -n "${rest}" ]]; do
      if [[ "${rest}" == *";"* ]]; then
        part="${rest%%;*}"
        rest="${rest#*;}"
      else
        part="${rest}"
        rest=""
      fi
      [[ -n "${part}" ]] && line="${line//${part}/***}"
      if [[ "${part}" == *"="* ]]; then
        rhs="${part#*=}"
        [[ "${#rhs}" -ge 6 ]] && line="${line//${rhs}/***}"
      fi
    done
  done < "${envf}"
  printf '%s\n' "${line}"
}

hm_dotnet_unit_path() {
  local domain="$1"
  printf '%s/hm-app-%s.service' "${HM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}" "${domain}"
}

hm_dotnet_write_unit() {
  local domain="$1" dll="$2" port="$3" home="$4" unit
  unit="$(hm_dotnet_unit_path "${domain}")"
  mkdir -p "$(dirname "${unit}")"
  cat > "${unit}" <<EOF
[Unit]
Description=hmtools ${domain}
After=network.target

[Service]
Type=simple
User=${HM_SITE_USER:-www-data}
WorkingDirectory=${home}/current
ExecStart=/usr/bin/dotnet ${home}/current/${dll}
Environment=ASPNETCORE_URLS=http://127.0.0.1:${port}
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
EnvironmentFile=-${home}/shared/.env
KillSignal=SIGINT
Restart=always
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=${home}/shared

[Install]
WantedBy=multi-user.target
EOF
}

hm_dotnet_systemctl() {
  if [[ -n "${HM_DOTNET_SYSTEMCTL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "${HM_DOTNET_SYSTEMCTL_LOG}"
    return 0
  fi
  [[ "${HMTOOLS_TEST:-}" == "1" ]] && return 0
  systemctl "$@"
}

hm_site_dotnet_home() {
  if declare -F hm_site_home >/dev/null 2>&1; then
    hm_site_home "$1"
    return
  fi
  printf '%s/%s' "${HM_SITE_HOME_BASE:-/home}" "$1"
}

hm_site_dotnet_provision() {
  local domain="$1" channel="$2" kind="$3" source="$4" dll="$5" port="${6:-5000}"
  local home unit mem
  [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || { hm_err "Zła domena."; return 1; }
  [[ "${dll}" =~ ^[A-Za-z0-9._-]+\.dll$ ]] || { hm_err "Zła nazwa DLL."; return 1; }
  [[ "${port}" =~ ^[0-9]+$ ]] || { hm_err "Zły port Kestrel."; return 1; }
  case "${kind}" in
    aspnetcore-runtime|sdk) ;;
    *) hm_err "Rodzaj .NET: aspnetcore-runtime albo sdk."; return 1 ;;
  esac
  case "${source}" in
    microsoft-repo|dotnet-install) ;;
    *) hm_err "Źródło .NET: microsoft-repo albo dotnet-install."; return 1 ;;
  esac
  if hm_dotnet_feeds_mixed; then
    hm_err "Wykryto jednocześnie feed Microsoft i pakiety Ubuntu dla .NET. Nie mieszaj źródeł."
    return 1
  fi
  mem="${HM_DOTNET_MEM_MB:-4096}"
  if [[ "${kind}" == "sdk" && "${mem}" -lt 2048 ]]; then
    hm_warn "dotnet publish przy mniej niż 2 GB RAM może zostać ubity."
  fi
  if [[ -n "${HM_DOTNET_INSTALL_LOG:-}" ]]; then
    printf '%s %s %s\n' "${source}" "${kind}" "${channel}" >> "${HM_DOTNET_INSTALL_LOG}"
  fi
  home="$(hm_site_dotnet_home "${domain}")"
  mkdir -p "${home}/shared/keys" "${home}/current"
  if [[ -n "${HM_DOTNET_SECRET:-}" ]]; then
    hm_dotnet_write_secret "${home}/shared/.env" "ConnectionStrings__Default" "${HM_DOTNET_SECRET}"
  fi
  hm_dotnet_write_unit "${domain}" "${dll}" "${port}" "${home}"
  unit="$(hm_dotnet_unit_path "${domain}")"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${unit}" || {
      hm_err "Unit nie przechodzi systemd-analyze verify."
      return 1
    }
  fi
  hm_dotnet_systemctl enable --now "hm-app-${domain}.service"
  hm_info "ASP.NET wymaga UseForwardedHeaders dla X-Forwarded-For i X-Forwarded-Proto."
  if ! hm_dotnet_publish_allowed; then
    hm_info "Bez SDK wgraj artefakt rsync do releases/, bez dotnet publish na tym hoście."
  fi
  HM_DOTNET_KIND="${kind}"
}
