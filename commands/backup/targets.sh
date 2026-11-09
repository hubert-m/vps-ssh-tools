#!/usr/bin/env bash
# backup targets / target add — cele rclone (S3/B2/SFTP) + lokalne


hm_backup_targets_list() {
  hm_load_config
  echo "${C_BOLD}Backup — cele${C_RESET}"
  local name spec def
  def="$(hm_backup_default_target_name)"
  echo "  Domyślny (RCLONE_REMOTE): ${RCLONE_REMOTE}  [name=${def}]"
  echo
  hm_table_begin
  hm_table_row NAME SPEC
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    spec="$(hm_backup_target_spec "${name}" 2>/dev/null || echo "?")"
    if [[ "${name}" == "${def}" ]]; then
      hm_table_row "${name}" "${spec}  (default)"
    else
      hm_table_row "${name}" "${spec}"
    fi
  done < <(hm_backup_target_names)
  hm_table_print
  echo
  hm_info "Dodaj: backup target add s3|b2|sftp|local --name <n> …"
  hm_info "Użyj:  backup site <d> --target <n>  |  backup full --targets a,b"
}

hm_backup_target_add() {
  hm_load_config
  local kind="${1:-}"
  shift || true
  local name="" bucket="" endpoint="" path="" remote="" region=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 || true ;;
      --name=*) name="${1#*=}"; shift ;;
      --bucket) bucket="${2:-}"; shift 2 || true ;;
      --bucket=*) bucket="${1#*=}"; shift ;;
      --endpoint) endpoint="${2:-}"; shift 2 || true ;;
      --endpoint=*) endpoint="${1#*=}"; shift ;;
      --path|--root) path="${2:-}"; shift 2 || true ;;
      --path=*|--root=*) path="${1#*=}"; shift ;;
      --remote) remote="${2:-}"; shift 2 || true ;;
      --remote=*) remote="${1#*=}"; shift ;;
      --region) region="${2:-}"; shift 2 || true ;;
      --region=*) region="${1#*=}"; shift ;;
      help|-h|--help)
        cat <<'EOF'
Użycie:
  backup target add s3|b2 --name <n> [--bucket …] [--endpoint …] [--path hmtools]
  backup target add sftp --name <n> --remote <rclone-remote> [--path …]
  backup target add local --name <n> [--path /backup/hmtools]
  backup target add rclone --name <n> --remote remote:path

Sekrety (klucze S3) tylko w rclone.conf (0600) — hmtools nie zapisuje haseł.
EOF
        return 0
        ;;
      *)
        hm_err "Nieznany argument: $1"; return 1 ;;
    esac
  done

  case "${kind}" in
    s3|b2|sftp|local|rclone) ;;
    ""|help|-h|--help)
      hm_backup_target_add help; return 0 ;;
    *)
      hm_err "Typ: s3|b2|sftp|local|rclone"; return 1 ;;
  esac

  [[ -n "${name}" ]] || { hm_err "Wymagane --name"; return 1; }

  local spec=""
  case "${kind}" in
    local)
      spec="${path:-${BACKUP_LOCAL_ROOT:-/backup/hmtools}}"
      [[ "${spec}" == /* ]] || spec="/${spec}"
      ;;
    rclone|sftp)
      if [[ -n "${remote}" ]]; then
        if [[ "${remote}" == *:* ]]; then
          spec="${remote}"
        else
          path="${path:-hmtools}"
          path="${path#/}"; path="${path%/}"
          spec="${remote}:${path}"
        fi
      else
        hm_err "sftp/rclone: podaj --remote (nazwa z rclone listremotes lub remote:path)"
        return 1
      fi
      ;;
    s3|b2)
      # Interaktywnie / non-interactive: utworzenie remote rclone typu s3
      hm_rclone_check || return 1
      local rname="${name}"
      path="${path:-hmtools}"
      path="${path#/}"; path="${path%/}"
      if [[ -z "${bucket}" ]]; then
        if [[ -t 0 ]]; then
          read -r -p "Bucket: " bucket
        fi
      fi
      [[ -n "${bucket}" ]] || { hm_err "Wymagany --bucket"; return 1; }
      if ! hm_confirm_plan "backup target add ${kind} — ${name}" \
        "Sekrety (access_key/secret) wpiszesz w rclone — nie trafią do hmtools.conf/applog." \
        "Remote rclone: ${rname} (type s3${endpoint:+, endpoint=${endpoint}})" \
        "Zapis BACKUP_TARGET_${name}=${rname}:${bucket}/${path}" \
        "chmod 600 rclone.conf (domyślnie ~/.config/rclone/)"; then
        return 0
      fi
      # Non-interactive create jeśli brak remote
      if ! rclone listremotes 2>/dev/null | grep -qx "${rname}:"; then
        hm_info "Tworzenie rclone remote ${rname} (provider=${kind})…"
        local -a conf_args=(create "${rname}" s3)
        if [[ "${kind}" == "b2" ]]; then
          conf_args+=(provider=Other env_auth=false)
          [[ -n "${endpoint}" ]] || endpoint="s3.us-west-004.backblazeb2.com"
        else
          conf_args+=(provider=AWS env_auth=false)
        fi
        [[ -n "${endpoint}" ]] && conf_args+=("endpoint=${endpoint}")
        [[ -n "${region}" ]] && conf_args+=("region=${region}")
        hm_info "Podaj access_key_id / secret_access_key gdy rclone zapyta (nie logujemy)."
        # rclone config create może przyjąć klucze z env RCLONE_CONFIG_* — nie wymuszamy
        if [[ -t 0 ]]; then
          local ak sk
          read -r -p "access_key_id: " ak
          read -r -s -p "secret_access_key: " sk
          echo
          # nie używamy hm_run — sekrety w argv widoczne w ps; rclone config update z env
          export RCLONE_CONFIG_"${rname}"_TYPE=s3
          # Bezpieczniej: plik 0600 + rclone config create z --non-interactive gdzie możliwe
          local cfg_tmp
          cfg_tmp="$(hm_mktemp .rclone)"
          chmod 600 "${cfg_tmp}"
          {
            echo "[${rname}]"
            echo "type = s3"
            if [[ "${kind}" == "b2" ]]; then
              echo "provider = Other"
              echo "endpoint = ${endpoint}"
            else
              echo "provider = AWS"
              [[ -n "${region}" ]] && echo "region = ${region}"
              [[ -n "${endpoint}" ]] && echo "endpoint = ${endpoint}"
            fi
            echo "access_key_id = ${ak}"
            echo "secret_access_key = ${sk}"
          } > "${cfg_tmp}"
          # Merge do rclone.conf bez echo sekretów
          local rconf="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
          mkdir -p "$(dirname "${rconf}")"
          touch "${rconf}"
          chmod 600 "${rconf}"
          # usuń starą sekcję
          if grep -qE "^\\[${rname}\\]" "${rconf}" 2>/dev/null; then
            awk -v sec="[${rname}]" '
              $0==sec {skip=1; next}
              /^\[/ {skip=0}
              !skip {print}
            ' "${rconf}" > "${cfg_tmp}.base"
            cat "${cfg_tmp}.base" "${cfg_tmp}" > "${rconf}"
            rm -f "${cfg_tmp}.base"
          else
            printf '\n' >> "${rconf}"
            cat "${cfg_tmp}" >> "${rconf}"
          fi
          rm -f "${cfg_tmp}"
          unset ak sk
          hm_ok "Zapisano remote ${rname} w rclone.conf (0600)."
        else
          hm_err "Brak TTY — utwórz remote ręcznie: rclone config, potem: backup target add rclone --name ${name} --remote ${rname}:${bucket}/${path}"
          return 1
        fi
      fi
      spec="${rname}:${bucket}/${path}"
      hm_backup_target_save "${name}" "${spec}" || return 1
      hm_ok "Cel ${name} → ${spec}"
      return 0
      ;;
  esac

  if ! hm_confirm_plan "backup target add ${kind} — ${name}" \
    "" \
    "Zapis BACKUP_TARGET / BACKUP_TARGETS w hmtools.conf (bez sekretów)" \
    "Spec: ${spec}"; then
    return 0
  fi
  hm_backup_target_save "${name}" "${spec}" || return 1
  hm_ok "Cel ${name} → ${spec}"
}

cmd_backup_targets() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    ""|list|ls|show)
      hm_backup_targets_list
      ;;
    add)
      hm_backup_target_add "$@"
      ;;
    help|-h|--help)
      echo "Użycie: backup targets | backup target add s3|b2|sftp|local|rclone …"
      ;;
    *)
      # backup target add …
      if [[ "${sub}" == "add" ]] || [[ "${1:-}" == "add" ]]; then
        hm_backup_target_add "$@"
      else
        hm_err "Użycie: backup targets | backup target add …"
        return 1
      fi
      ;;
  esac
}
