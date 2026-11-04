#!/usr/bin/env bash
# Sites: całkowite usunięcie serwisu (webs delete / delete-site)

# Stan inwentaryzacji (czyszczony przy każdym wywołaniu)
HM_DEL_DOMAIN=""
HM_DEL_ROOT=""
HM_DEL_DOCROOT=""
HM_DEL_USER=""
HM_DEL_SIZE=0
HM_DEL_VHOST_DIR=""
HM_DEL_HAS_OLS_MAP=0
HM_DEL_HAS_CP=0
HM_DEL_KEEP_DB=0
HM_DEL_KEEP_SSL=0
HM_DEL_KEEP_USER=0
HM_DEL_USER_SHARED=0
HM_DEL_USER_PROTECTED=0
HM_DEL_CHILD_OF_SHARED=0
HM_DEL_FORCE_NESTED=0
HM_DEL_CRON_COUNT=0
declare -a HM_DEL_DBS=()
declare -a HM_DEL_DB_USERS=()
declare -a HM_DEL_PM2=()
declare -a HM_DEL_SSL_PATHS=()
declare -a HM_DEL_CRON_NOTES=()
declare -a HM_DEL_NESTED_WARN=()
declare -a HM_DEL_NESTED_BLOCK=()
declare -a HM_DEL_NESTED_CHILDREN=()
declare -a HM_DEL_SKIP_DBS=()
declare -a HM_DEL_PLAN_STEPS=()
declare -a HM_DEL_PLAN_KEYS=()

hm_del_reset_inventory() {
  HM_DEL_DOMAIN=""
  HM_DEL_ROOT=""
  HM_DEL_DOCROOT=""
  HM_DEL_USER=""
  HM_DEL_SIZE=0
  HM_DEL_VHOST_DIR=""
  HM_DEL_HAS_OLS_MAP=0
  HM_DEL_HAS_CP=0
  HM_DEL_KEEP_DB=0
  HM_DEL_KEEP_SSL=0
  HM_DEL_KEEP_USER=0
  HM_DEL_USER_SHARED=0
  HM_DEL_USER_PROTECTED=0
  HM_DEL_CHILD_OF_SHARED=0
  # HM_DEL_FORCE_NESTED zachowujemy z CLI (nie kasujemy tu)
  HM_DEL_CRON_COUNT=0
  HM_DEL_DBS=()
  HM_DEL_DB_USERS=()
  HM_DEL_PM2=()
  HM_DEL_SSL_PATHS=()
  HM_DEL_CRON_NOTES=()
  HM_DEL_NESTED_WARN=()
  HM_DEL_NESTED_BLOCK=()
  HM_DEL_NESTED_CHILDREN=()
  HM_DEL_SKIP_DBS=()
  HM_DEL_PLAN_STEPS=()
  HM_DEL_PLAN_KEYS=()
}

# Czy domena jest na liście childów kasowanych z --force-nested?
hm_del_is_nested_child() {
  local d="${1:-}" nc
  [[ -n "${d}" ]] || return 1
  for nc in "${HM_DEL_NESTED_CHILDREN[@]:-}"; do
    [[ "${nc}" == "${d}" ]] && return 0
  done
  return 1
}

hm_is_safe_sites_root_config() {
  # SITES_ROOT musi mieć głębokość ≥ 2 i nie może być katalogiem systemowym.
  local raw="${1:-}" sr rest
  [[ -n "${raw}" ]] || return 1
  sr="$(realpath -m "${raw}" 2>/dev/null || echo "${raw}")"
  sr="${sr%/}"
  [[ -n "${sr}" && "${sr}" != "/" ]] || return 1
  case "${sr}" in
    /bin|/boot|/dev|/etc|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/sys|/usr|/var|/home|/opt|/srv|/tmp|/media|/mnt|/hm-tools)
      return 1
      ;;
  esac
  case "${sr}" in
    /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/libx32/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/usr/*)
      return 1
      ;;
  esac
  rest="${sr#/}"
  [[ "${rest}" == */* && "${rest}" != */ ]] || return 1
  return 0
}

hm_is_safe_site_root_to_delete() {
  # Ścieżka musi być /home/<cos>… lub /var/www/<cos>…; blokada katalogów systemowych.
  local raw="${1:-}"
  local p
  [[ -n "${raw}" ]] || return 1
  p="$(realpath -m "${raw}" 2>/dev/null || echo "${raw}")"
  p="${p%/}"
  [[ -n "${p}" && "${p}" != "/" ]] || return 1
  case "${p}" in
    /|/home|/var|/var/www|/usr|/etc|/root|/tmp|/hm-tools|/bin|/boot|/dev|/lib|/lib64|/proc|/run|/sbin|/sys|/opt|/srv|/media|/mnt)
      return 1
      ;;
  esac
  if [[ -n "${OLS_ROOT:-}" ]]; then
    local ols
    ols="$(realpath -m "${OLS_ROOT}" 2>/dev/null || echo "${OLS_ROOT}")"
    ols="${ols%/}"
    [[ "${p}" == "${ols}" || "${p}" == "${ols}"/* ]] && return 1
  fi
  # co najmniej /home/X lub /var/www/X (2+ segmenty po leading /)
  if [[ "${p}" =~ ^/home/[^/]+(/.*)?$ ]]; then
    return 0
  fi
  if [[ "${p}" =~ ^/var/www/[^/]+(/.*)?$ ]]; then
    return 0
  fi
  # opcjonalny SITES_ROOT z hmtools.conf (np. /srv/www/<domena>) — tylko gdy sam SITES_ROOT jest bezpieczny
  if [[ -n "${SITES_ROOT:-}" ]] && hm_is_safe_sites_root_config "${SITES_ROOT}"; then
    local sr
    sr="$(realpath -m "${SITES_ROOT%/}" 2>/dev/null || echo "${SITES_ROOT%/}")"
    sr="${sr%/}"
    if [[ "${p}" == "${sr}" ]]; then
      return 1
    fi
    if [[ "${p}" == "${sr}/"* ]]; then
      local rest="${p#"${sr}/"}"
      # wymaga co najmniej jednego segmentu pod SITES_ROOT (nie sam SITES_ROOT)
      [[ -n "${rest}" && "${rest}" != *".."* ]] && return 0
    fi
  fi
  return 1
}

# UID_MIN z /etc/login.defs (domyślnie 1000) — konta systemowe poniżej są chronione.
hm_unix_uid_min() {
  local m
  m="$(awk '/^UID_MIN/{print $2; exit}' /etc/login.defs 2>/dev/null || true)"
  [[ "${m}" =~ ^[0-9]+$ ]] || m=1000
  printf '%s' "${m}"
}

hm_del_user_is_protected() {
  local u="${1:-}"
  local cur uid umin
  [[ -n "${u}" ]] || return 0
  case "${u}" in
    root|nobody|nogroup|www-data|lsadm|cyberpanel|mysql|mariadb|postfix|dovecot|sshd|ubuntu|debian|centos|almalinux|rocky|apache|nginx|daemon|messagebus|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|backup|list|irc|gnats|systemd-*)
      return 0
      ;;
  esac
  cur="${SUDO_USER:-${USER:-}}"
  [[ -n "${cur}" && "${u}" == "${cur}" ]] && return 0
  # UID < UID_MIN (np. daemon=1, messagebus) — zawsze chronione, niezależnie od nazwy
  if id "${u}" >/dev/null 2>&1; then
    uid="$(id -u "${u}" 2>/dev/null || echo "")"
    umin="$(hm_unix_uid_min)"
    if [[ "${uid}" =~ ^[0-9]+$ && "${uid}" -lt "${umin}" ]]; then
      return 0
    fi
  fi
  return 1
}

hm_del_db_owned_by_other() {
  local dbname="$1" skip_domain="$2"
  local q other
  hm_is_valid_db_name "${dbname}" || return 1
  q="$(hm_sql_quote "${dbname}")"
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    other="$(hm_mysql_exec cyberpanel -e "
SELECT w.domain FROM databases_databases d
INNER JOIN websiteFunctions_websites w ON d.website_id = w.id
WHERE d.dbName = ${q} AND w.domain <> $(hm_sql_quote "${skip_domain}")
LIMIT 1;
" 2>/dev/null || true)"
    if [[ -n "${other}" ]]; then
      # force-nested: DB „należąca” do childa w CP i tak jest w kaskadzie
      hm_del_is_nested_child "${other}" && return 1
      return 0
    fi
  fi
  local d row root doc user name _u _s origin
  for d in "${HM_SITES_LIST[@]}"; do
    [[ "${d}" == "${skip_domain}" ]] && continue
    hm_del_is_nested_child "${d}" && continue
    row="$(hm_resolve_site_paths "${d}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ root doc _ _ _ rest <<<"${row}"
    root="$(hm_tsv_unfield "${root}")"
    doc="$(hm_tsv_unfield "${doc}")"
    user="$(hm_tsv_unfield "${rest%%|*}")"
    while IFS=$'\t' read -r name _u _s origin; do
      [[ "${name}" == "${dbname}" ]] || continue
      case "${origin}" in
        confirmed|user-match|wp-config|.env|.env-url|configuration.php) return 0 ;;
      esac
    done < <(hm_dbs_for_site "${d}" "${doc}" "${root}" "${user}" 2>/dev/null || true)
  done
  return 1
}

hm_del_mysql_users_for_db() {
  local dbname="$1"
  local q u seen="|"
  hm_is_valid_db_name "${dbname}" || return 0
  q="$(hm_sql_quote "${dbname}")"
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    while IFS= read -r u; do
      [[ -n "${u}" ]] || continue
      [[ "${seen}" == *"|${u}|"* ]] && continue
      seen="${seen}${u}|"
      printf '%s\n' "${u}"
    done < <(hm_mysql_exec cyberpanel -e "
SELECT DISTINCT dbUser FROM databases_databases WHERE dbName = ${q} AND dbUser <> '';
" 2>/dev/null || true)
  fi
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    [[ "${seen}" == *"|${u}|"* ]] && continue
    seen="${seen}${u}|"
    printf '%s\n' "${u}"
  done < <(hm_mysql_exec -e "
SELECT DISTINCT User FROM mysql.db WHERE Db = ${q} AND User <> '';
" 2>/dev/null || true)
}

hm_del_mysql_user_exclusive() {
  # true jeśli użytkownik nie ma uprawnień do innych baz niż listed
  local dbuser="$1"
  shift
  local -a keep_dbs=("$@")
  local q cnt other
  [[ -n "${dbuser}" && "${dbuser}" != "root" ]] || return 1
  hm_is_valid_db_name "${dbuser}" || return 1
  q="$(hm_sql_quote "${dbuser}")"
  while IFS= read -r other; do
    [[ -n "${other}" ]] || continue
    local hit=0 k
    for k in "${keep_dbs[@]}"; do
      [[ "${other}" == "${k}" ]] && hit=1 && break
    done
    [[ "${hit}" -eq 0 ]] && return 1
  done < <(hm_mysql_exec -e "
SELECT DISTINCT Db FROM mysql.db WHERE User = ${q} AND Host = 'localhost';
" 2>/dev/null || true)
  if [[ "${PANEL:-}" == "cyberpanel" ]]; then
    while IFS= read -r other; do
      [[ -n "${other}" ]] || continue
      local hit=0 k
      for k in "${keep_dbs[@]}"; do
        [[ "${other}" == "${k}" ]] && hit=1 && break
      done
      [[ "${hit}" -eq 0 ]] && return 1
    done < <(hm_mysql_exec cyberpanel -e "
SELECT DISTINCT dbName FROM databases_databases WHERE dbUser = ${q};
" 2>/dev/null || true)
  fi
  return 0
}

hm_del_ols_mentions_domain() {
  local domain="$1"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  # OLS/CyberPanel: virtualHost / virtualhost (case-insensitive)
  grep -Eiq "(^|[[:space:]])virtualhost[[:space:]]+${domain}([[:space:]]|\{|$)" "${conf}" 2>/dev/null \
    || grep -Eiq "^[[:space:]]*map[[:space:]]+${domain}([[:space:]]|$)" "${conf}" 2>/dev/null
}

hm_del_cyberpanel_has_domain() {
  local domain="$1" q
  hm_is_valid_domain "${domain}" || return 1
  [[ "${PANEL:-}" == "cyberpanel" ]] || return 1
  q="$(hm_sql_quote "${domain}")"
  local n
  n="$(hm_mysql_exec cyberpanel -e "
SELECT COUNT(*) FROM (
  SELECT id FROM websiteFunctions_websites WHERE domain = ${q}
  UNION ALL
  SELECT id FROM websiteFunctions_childdomains WHERE domain = ${q}
) t;
" 2>/dev/null || echo 0)"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]] && return 0
  n="$(hm_mysql_exec cyberpanel -e "
SELECT COUNT(*) FROM websites_website WHERE domainName = ${q};
" 2>/dev/null || echo 0)"
  [[ "${n}" =~ ^[0-9]+$ && "${n}" -gt 0 ]]
}

hm_site_collect_delete_inventory() {
  local domain="$1"
  local keep_db="${2:-0}" keep_ssl="${3:-0}" keep_user="${4:-0}"
  local force_nested="${5:-${HM_DEL_FORCE_NESTED:-0}}"
  hm_del_reset_inventory
  HM_DEL_KEEP_DB="${keep_db}"
  HM_DEL_KEEP_SSL="${keep_ssl}"
  HM_DEL_KEEP_USER="${keep_user}"
  HM_DEL_FORCE_NESTED="${force_nested}"
  HM_DEL_DOMAIN="${domain}"

  hm_detect_all
  hm_discover_sites

  local row root docroot logs vhost php rest user status
  local vh_root=""
  row="$(hm_resolve_site_paths "${domain}")"
  IFS=$'\t' read -r domain root docroot logs vhost php rest <<<"${row}"
  root="$(hm_tsv_unfield "${root}")"
  docroot="$(hm_tsv_unfield "${docroot}")"
  logs="$(hm_tsv_unfield "${logs}")"
  vhost="$(hm_tsv_unfield "${vhost}")"
  php="$(hm_tsv_unfield "${php}")"
  user="$(hm_tsv_unfield "${rest%%|*}")"
  status="${rest##*|}"
  HM_DEL_ROOT="$(realpath -m "${root}" 2>/dev/null || echo "${root}")"
  HM_DEL_DOCROOT="$(realpath -m "${docroot}" 2>/dev/null || echo "${docroot}")"
  HM_DEL_USER="${user}"
  vh_root="${HM_DEL_ROOT}"

  if [[ -z "${HM_DEL_ROOT}" ]]; then
    hm_err "Nie ustalono katalogu strony dla ${domain}."
    return 1
  fi
  if ! hm_is_safe_site_root_to_delete "${HM_DEL_ROOT}"; then
    hm_err "Ścieżka strony nie przeszła kontroli bezpieczeństwa: ${HM_DEL_ROOT}"
    return 1
  fi

  # nested / shared — najpierw wykryj współdzielony vhRoot / user, potem ewentualnie zawęź do docroot (child)
  local other oroot odoc orest ou
  local share_vhroot=0
  local looks_like_master_doc=0
  for other in "${HM_SITES_LIST[@]}"; do
    [[ -n "${other}" ]] || continue
    [[ "${other}" == "${domain}" ]] && continue
    row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ oroot odoc _ _ _ orest <<<"${row}"
    oroot="$(hm_tsv_unfield "${oroot}")"
    odoc="$(hm_tsv_unfield "${odoc}")"
    oroot="$(realpath -m "${oroot}" 2>/dev/null || echo "${oroot}")"
    odoc="$(realpath -m "${odoc}" 2>/dev/null || echo "${odoc}")"
    ou="$(hm_tsv_unfield "${orest%%|*}")"
    if [[ -n "${HM_DEL_USER}" && -n "${ou}" && "${ou}" == "${HM_DEL_USER}" ]]; then
      HM_DEL_USER_SHARED=1
    fi
    if [[ -n "${oroot}" && -n "${vh_root}" && "${oroot}" == "${vh_root}" ]]; then
      share_vhroot=1
    fi
  done

  if [[ -n "${HM_DEL_DOCROOT}" && ( "${HM_DEL_DOCROOT}" == "${vh_root}/public_html" || "${HM_DEL_DOCROOT}" == "${vh_root}/html" ) ]]; then
    looks_like_master_doc=1
  fi

  # Child / nested docroot (CyberPanel: ten sam vhRoot, docroot głębiej niż public_html)
  if [[ "${share_vhroot}" -eq 1 \
        && -n "${HM_DEL_DOCROOT}" \
        && "${HM_DEL_DOCROOT}" == "${vh_root}"/* \
        && "${HM_DEL_DOCROOT}" != "${vh_root}" \
        && "${looks_like_master_doc}" -eq 0 ]]; then
    if ! hm_is_safe_site_root_to_delete "${HM_DEL_DOCROOT}"; then
      hm_err "Docroot child nie przeszedł kontroli bezpieczeństwa: ${HM_DEL_DOCROOT}"
      return 1
    fi
    hm_info "Domena podrzędna (współdzielony vhRoot) — operacje na docroot: ${HM_DEL_DOCROOT} (nie cały ${vh_root})"
    HM_DEL_ROOT="${HM_DEL_DOCROOT}"
    HM_DEL_CHILD_OF_SHARED=1
  fi

  # Ostrzeżenia / twarde bloki nachodzenia (po ewentualnym zawężeniu ROOT)
  for other in "${HM_SITES_LIST[@]}"; do
    [[ -n "${other}" ]] || continue
    [[ "${other}" == "${domain}" ]] && continue
    row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
    [[ -n "${row}" ]] || continue
    IFS=$'\t' read -r _ oroot odoc _ _ _ orest <<<"${row}"
    oroot="$(hm_tsv_unfield "${oroot}")"
    odoc="$(hm_tsv_unfield "${odoc}")"
    oroot="$(realpath -m "${oroot}" 2>/dev/null || echo "${oroot}")"
    odoc="$(realpath -m "${odoc}" 2>/dev/null || echo "${odoc}")"
    # Usunięcie HM_DEL_ROOT skasowałoby cudzy root/docroot
    if [[ -n "${oroot}" && "${oroot}" != "${HM_DEL_ROOT}" && "${oroot}" == "${HM_DEL_ROOT}"/* ]]; then
      HM_DEL_NESTED_BLOCK+=("ścieżka ${other} (${oroot}) leży wewnątrz ${HM_DEL_ROOT} — zostałaby skasowana")
      HM_DEL_NESTED_CHILDREN+=("${other}")
    elif [[ -n "${odoc}" && "${odoc}" != "${HM_DEL_ROOT}" && "${odoc}" == "${HM_DEL_ROOT}"/* ]]; then
      HM_DEL_NESTED_BLOCK+=("docroot ${other} (${odoc}) leży wewnątrz ${HM_DEL_ROOT} — zostałby skasowany (zarchiwizuj child najpierw)")
      HM_DEL_NESTED_CHILDREN+=("${other}")
    elif [[ -n "${oroot}" && "${HM_DEL_ROOT}" == "${oroot}"/* ]]; then
      HM_DEL_NESTED_WARN+=("katalog ${HM_DEL_ROOT} leży wewnątrz ${other} (${oroot})")
    fi
  done

  if [[ "${#HM_DEL_NESTED_BLOCK[@]}" -gt 0 && "${HM_DEL_FORCE_NESTED}" -ne 1 ]]; then
    local nb
    hm_err "ODMOWA: archive/delete usunąłby dane innych domen (nested). Zarchiwizuj najpierw domeny podrzędne albo użyj --force-nested."
    for nb in "${HM_DEL_NESTED_BLOCK[@]}"; do
      hm_err "  • ${nb}"
    done
    HM_DEL_NESTED_CHILDREN=()
    return 1
  fi
  if [[ "${#HM_DEL_NESTED_BLOCK[@]}" -gt 0 && "${HM_DEL_FORCE_NESTED}" -eq 1 ]]; then
    local nb
    for nb in "${HM_DEL_NESTED_BLOCK[@]}"; do
      HM_DEL_NESTED_WARN+=("FORCE-NESTED: ${nb}")
    done
    # User „współdzielony” tylko z childami w kaskadzie → traktuj jako exclusive (cron/userdel OK)
    if [[ -n "${HM_DEL_USER}" && "${#HM_DEL_NESTED_CHILDREN[@]}" -gt 0 ]]; then
      HM_DEL_USER_SHARED=0
      for other in "${HM_SITES_LIST[@]}"; do
        [[ -n "${other}" && "${other}" != "${domain}" ]] || continue
        hm_del_is_nested_child "${other}" && continue
        row="$(hm_resolve_site_paths "${other}" 2>/dev/null || true)"
        [[ -n "${row}" ]] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ orest <<<"${row}"
        ou="$(hm_tsv_unfield "${orest%%|*}")"
        if [[ -n "${ou}" && "${ou}" == "${HM_DEL_USER}" ]]; then
          HM_DEL_USER_SHARED=1
          break
        fi
      done
      if [[ "${HM_DEL_USER_SHARED}" -eq 0 ]]; then
        hm_info "FORCE-NESTED: user ${HM_DEL_USER} exclusive po kaskadzie childów — cron/userdel w planie."
      fi
    fi
  else
    HM_DEL_NESTED_CHILDREN=()
  fi

  if [[ -d "${HM_DEL_ROOT}" ]]; then
    HM_DEL_SIZE="$(hm_dir_size_bytes "${HM_DEL_ROOT}" 2>/dev/null || echo 0)"
  fi

  if hm_del_user_is_protected "${HM_DEL_USER}"; then
    HM_DEL_USER_PROTECTED=1
  fi
  if [[ -n "${HM_DEL_USER}" ]] && ! id "${HM_DEL_USER}" >/dev/null 2>&1; then
    HM_DEL_USER=""
  fi

  # DB (master + ewentualnie childy przy force-nested)
  local name dbuser size origin skip reason
  local -a will_drop_dbs=()
  local seen_db="|"
  local -a _db_scan_domains=("${domain}")
  local nc nrow ncroot ncdoc ncrest ncuser sp
  if [[ "${HM_DEL_FORCE_NESTED}" -eq 1 ]]; then
    for nc in "${HM_DEL_NESTED_CHILDREN[@]:-}"; do
      [[ -n "${nc}" ]] && _db_scan_domains+=("${nc}")
    done
  fi
  for nc in "${_db_scan_domains[@]}"; do
    [[ -n "${nc}" ]] || continue
    if [[ "${nc}" == "${domain}" ]]; then
      ncroot="${root}"
      ncdoc="${docroot}"
      ncuser="${user}"
    else
      nrow="$(hm_resolve_site_paths "${nc}" 2>/dev/null || true)"
      [[ -n "${nrow}" ]] || continue
      IFS=$'\t' read -r _ ncroot ncdoc _ _ _ ncrest <<<"${nrow}"
      ncroot="$(hm_tsv_unfield "${ncroot}")"
      ncdoc="$(hm_tsv_unfield "${ncdoc}")"
      ncuser="$(hm_tsv_unfield "${ncrest%%|*}")"
      if [[ "${HM_DEL_KEEP_SSL}" -eq 0 ]]; then
        for sp in \
          "/etc/letsencrypt/live/${nc}" \
          "/etc/letsencrypt/archive/${nc}" \
          "/etc/letsencrypt/renewal/${nc}.conf" \
          "/root/.acme.sh/${nc}" \
          "/root/.acme.sh/${nc}_ecc"
        do
          [[ -e "${sp}" ]] && HM_DEL_SSL_PATHS+=("${sp}")
        done
      fi
    fi
    while IFS=$'\t' read -r name dbuser size origin; do
      [[ -n "${name}" ]] || continue
      [[ "${seen_db}" == *"|${name}|"* ]] && continue
      skip=0
      reason=""
      if hm_del_db_owned_by_other "${name}" "${domain}"; then
        skip=1
        reason="współdzielona z inną domeną"
      fi
      case "${origin}" in
        prefix-match)
          skip=1
          reason="${reason:+${reason}; }tylko prefix-match"
          ;;
      esac
      if [[ "${skip}" -eq 1 ]]; then
        HM_DEL_SKIP_DBS+=("${name}|${origin}|${reason}")
      else
        HM_DEL_DBS+=("${name}|${dbuser}|${size}|${origin}")
        will_drop_dbs+=("${name}")
        seen_db="${seen_db}${name}|"
      fi
    done < <(hm_dbs_for_site "${nc}" "${ncdoc}" "${ncroot}" "${ncuser}" 2>/dev/null || true)
  done

  # DB users exclusive to these DBs
  local u seen_u="|"
  for name in "${will_drop_dbs[@]}"; do
    [[ -n "${name}" ]] || continue
    while IFS= read -r u; do
      [[ -n "${u}" ]] || continue
      [[ "${seen_u}" == *"|${u}|"* ]] && continue
      seen_u="${seen_u}${u}|"
      if hm_del_mysql_user_exclusive "${u}" "${will_drop_dbs[@]}"; then
        HM_DEL_DB_USERS+=("${u}")
      fi
    done < <(hm_del_mysql_users_for_db "${name}")
  done

  # PM2 (tymczasowy kontekst strony — bez zmiany REPL)
  hm_site_context_push
  HM_SITE_DOMAIN="${domain}"
  HM_SITE_ROOT="${HM_DEL_ROOT}"
  HM_SITE_USER="${HM_DEL_USER}"
  local pname pid status cwd script port mem restarts pm2home
  while IFS='|' read -r pname pid status cwd script port mem restarts; do
    [[ -n "${pname}" ]] || continue
    pm2home=""
    if [[ -n "${HM_DEL_USER}" ]]; then
      local uh
      uh="$(getent passwd "${HM_DEL_USER}" 2>/dev/null | cut -d: -f6 || true)"
      [[ -n "${uh}" && -d "${uh}/.pm2" ]] && pm2home="${uh}/.pm2"
    fi
    [[ -z "${pm2home}" ]] && pm2home="$(hm_pm2_home_dirs 2>/dev/null | head -1 || true)"
    HM_DEL_PM2+=("${pname}|${pid}|${port:-}|${pm2home:-}")
  done < <(hm_pm2_parse_apps 2>/dev/null | hm_pm2_match_site "${domain}" "${HM_DEL_ROOT}" || true)
  hm_site_context_pop

  # OLS vhost dir + conf maps
  if [[ -n "${OLS_VHOSTS:-}" && -d "${OLS_VHOSTS}/${domain}" ]]; then
    HM_DEL_VHOST_DIR="${OLS_VHOSTS}/${domain}"
  fi
  if hm_del_ols_mentions_domain "${domain}"; then
    HM_DEL_HAS_OLS_MAP=1
  fi

  # CyberPanel
  if hm_del_cyberpanel_has_domain "${domain}"; then
    HM_DEL_HAS_CP=1
  fi

  # Cron — nie kasujemy crontab przy współdzielonym/chronionym userze
  if [[ -n "${HM_DEL_USER}" ]]; then
    local cron_out
    cron_out="$(crontab -u "${HM_DEL_USER}" -l 2>/dev/null || true)"
    if [[ -n "${cron_out}" ]]; then
      HM_DEL_CRON_COUNT="$(printf '%s\n' "${cron_out}" | grep -cvE '^[[:space:]]*(#|$)' || echo 0)"
      [[ "${HM_DEL_CRON_COUNT}" =~ ^[0-9]+$ ]] || HM_DEL_CRON_COUNT=0
      if [[ "${HM_DEL_CRON_COUNT}" -gt 0 ]]; then
        if [[ "${HM_DEL_USER_SHARED}" -eq 1 || "${HM_DEL_USER_PROTECTED}" -eq 1 ]]; then
          HM_DEL_CRON_NOTES+=("crontab ${HM_DEL_USER}: ${HM_DEL_CRON_COUNT} wpisów — POMIJAM (user współdzielony/chroniony)")
          HM_DEL_CRON_COUNT=0
        else
          HM_DEL_CRON_NOTES+=("crontab użytkownika ${HM_DEL_USER} (${HM_DEL_CRON_COUNT} wpisów)")
        fi
      fi
    fi
  fi
  local cf
  for cf in /etc/cron.d/*; do
    [[ -f "${cf}" ]] || continue
    if grep -Eq "${domain}|${HM_DEL_ROOT}" "${cf}" 2>/dev/null; then
      HM_DEL_CRON_NOTES+=("plik cron: ${cf}")
    fi
  done
  if [[ -f /etc/crontab ]] && grep -Eq "${domain}|${HM_DEL_ROOT}" /etc/crontab 2>/dev/null; then
    HM_DEL_CRON_NOTES+=("wpisy w /etc/crontab")
  fi

  # SSL
  local sp
  for sp in \
    "/etc/letsencrypt/live/${domain}" \
    "/etc/letsencrypt/archive/${domain}" \
    "/etc/letsencrypt/renewal/${domain}.conf" \
    "/root/.acme.sh/${domain}" \
    "/root/.acme.sh/${domain}_ecc"
  do
    [[ -e "${sp}" ]] && HM_DEL_SSL_PATHS+=("${sp}")
  done

  return 0
}

hm_site_build_delete_plan() {
  HM_DEL_PLAN_STEPS=()
  HM_DEL_PLAN_KEYS=()
  local domain="${HM_DEL_DOMAIN}"

  if [[ "${#HM_DEL_PM2[@]}" -gt 0 ]]; then
    local desc="" line
    for line in "${HM_DEL_PM2[@]}"; do
      IFS='|' read -r pname pid port pm2home <<<"${line}"
      desc="${desc:+${desc}, }${pname} (PID ${pid}${port:+, port ${port}})"
    done
    HM_DEL_PLAN_STEPS+=("Zatrzymanie i usunięcie ${#HM_DEL_PM2[@]} procesu/ów PM2/Node.js (${desc}) + pm2 save")
    HM_DEL_PLAN_KEYS+=("pm2")
  fi

  # pkill -u ubija wszystkie lsphp usera — pomiń gdy współdzielony/chroniony
  if [[ -n "${HM_DEL_USER}" && "${HM_DEL_USER_SHARED}" -eq 0 && "${HM_DEL_USER_PROTECTED}" -eq 0 ]]; then
    HM_DEL_PLAN_STEPS+=("Zatrzymanie procesów workerów LSPHP użytkownika ${HM_DEL_USER} (pkill -u ${HM_DEL_USER} lsphp)")
    HM_DEL_PLAN_KEYS+=("lsphp")
  fi

  if [[ "${HM_DEL_CRON_COUNT}" -gt 0 && -n "${HM_DEL_USER}" \
        && "${HM_DEL_USER_SHARED}" -eq 0 && "${HM_DEL_USER_PROTECTED}" -eq 0 ]]; then
    HM_DEL_PLAN_STEPS+=("Usunięcie crontaba użytkownika ${HM_DEL_USER} (crontab -r — ${HM_DEL_CRON_COUNT} aktywnych wpisów)")
    HM_DEL_PLAN_KEYS+=("cron")
  fi

  if [[ "${HM_DEL_KEEP_DB}" -eq 0 && "${#HM_DEL_DBS[@]}" -gt 0 ]]; then
    local dline dname duser dsize dorigin parts=""
    for dline in "${HM_DEL_DBS[@]}"; do
      IFS='|' read -r dname duser dsize dorigin <<<"${dline}"
      parts="${parts:+${parts}; }${dname} ($(hm_human_size "${dsize}"))"
    done
    local users_desc=""
    if [[ "${#HM_DEL_DB_USERS[@]}" -gt 0 ]]; then
      users_desc=" oraz użytkownika/ów DB $(printf "'%s'@localhost " "${HM_DEL_DB_USERS[@]}")"
    fi
    HM_DEL_PLAN_STEPS+=("Usunięcie baz MySQL: ${parts}${users_desc}")
    HM_DEL_PLAN_KEYS+=("db")
  fi

  if [[ "${#HM_DEL_NESTED_CHILDREN[@]}" -gt 0 ]]; then
    local ch_list
    ch_list="$(IFS=', '; echo "${HM_DEL_NESTED_CHILDREN[*]}")"
    HM_DEL_PLAN_STEPS+=("FORCE-NESTED: usunięcie child domen (${ch_list}): vhost OLS + map + SSL + wpisy CP childdomains (bez osobnego usera — współdzielony z masterem)")
    HM_DEL_PLAN_KEYS+=("nested-children")
  fi

  if [[ "${HM_DEL_HAS_CP}" -eq 1 ]]; then
    HM_DEL_PLAN_STEPS+=("Usunięcie wpisu domeny ${domain} z bazy CyberPanel (websiteFunctions_websites / childdomains / databases_databases)")
    HM_DEL_PLAN_KEYS+=("cyberpanel")
  fi

  if [[ -n "${HM_DEL_VHOST_DIR}" || "${HM_DEL_HAS_OLS_MAP}" -eq 1 ]]; then
    HM_DEL_PLAN_STEPS+=("Usunięcie konfiguracji vhosta OLS (${HM_DEL_VHOST_DIR:-—}) oraz mapowań z ${OLS_CONF:-httpd_config.conf} (kopia .hmtools.bak)")
    HM_DEL_PLAN_KEYS+=("ols")
  fi

  if [[ "${HM_DEL_KEEP_SSL}" -eq 0 && "${#HM_DEL_SSL_PATHS[@]}" -gt 0 ]]; then
    HM_DEL_PLAN_STEPS+=("Usunięcie certyfikatów SSL (${HM_DEL_SSL_PATHS[*]})")
    HM_DEL_PLAN_KEYS+=("ssl")
  fi

  HM_DEL_PLAN_STEPS+=("Trwałe usunięcie katalogu serwisu: ${HM_DEL_ROOT} ($(hm_human_size "${HM_DEL_SIZE}"))")
  HM_DEL_PLAN_KEYS+=("files")

  if [[ "${HM_DEL_KEEP_USER}" -eq 0 && -n "${HM_DEL_USER}" && "${HM_DEL_USER_SHARED}" -eq 0 && "${HM_DEL_USER_PROTECTED}" -eq 0 ]]; then
    HM_DEL_PLAN_STEPS+=("Usunięcie dedykowanego użytkownika systemowego Unix: ${HM_DEL_USER} (userdel)")
    HM_DEL_PLAN_KEYS+=("user")
  fi

  HM_DEL_PLAN_STEPS+=("Przeładowanie OpenLiteSpeed (ols reload) i odświeżenie cache domen hmtools")
  HM_DEL_PLAN_KEYS+=("reload")
}

hm_site_print_delete_inventory() {
  local domain="${HM_DEL_DOMAIN}"
  echo "${C_BOLD}Inwentaryzacja — ${domain}${C_RESET}"
  echo "  Katalog   : ${HM_DEL_ROOT} ($(hm_human_size "${HM_DEL_SIZE}"))$([[ "${HM_DEL_CHILD_OF_SHARED}" -eq 1 ]] && echo ' [CHILD→docroot]' || true)$([[ "${HM_DEL_FORCE_NESTED}" -eq 1 ]] && echo ' [FORCE-NESTED]' || true)"
  echo "  Docroot   : ${HM_DEL_DOCROOT:--}"
  echo "  User Unix : ${HM_DEL_USER:--}$([[ "${HM_DEL_USER_SHARED}" -eq 1 ]] && echo ' [WSPÓŁDZIELONY]' || true)$([[ "${HM_DEL_USER_PROTECTED}" -eq 1 ]] && echo ' [CHRONIONY]' || true)"
  echo "  Vhost OLS : ${HM_DEL_VHOST_DIR:--}"
  echo "  CyberPanel: $([[ "${HM_DEL_HAS_CP}" -eq 1 ]] && echo tak || echo nie)"
  echo "  PM2       : ${#HM_DEL_PM2[@]} proces(ów)"
  if [[ "${#HM_DEL_NESTED_CHILDREN[@]}" -gt 0 ]]; then
    echo "  Nested    : ${#HM_DEL_NESTED_CHILDREN[@]} child(ów) w kaskadzie: $(IFS=', '; echo "${HM_DEL_NESTED_CHILDREN[*]}")"
  fi
  if [[ "${HM_DEL_KEEP_DB}" -eq 1 ]]; then
    echo "  Bazy      : ${#HM_DEL_DBS[@]} wykrytych (zachowane: --keep-db), ${#HM_DEL_SKIP_DBS[@]} pominiętych"
  else
    echo "  Bazy      : ${#HM_DEL_DBS[@]} do usunięcia, ${#HM_DEL_SKIP_DBS[@]} pominiętych"
  fi
  echo "  SSL paths : ${#HM_DEL_SSL_PATHS[@]}"
  local w
  for w in "${HM_DEL_NESTED_WARN[@]}"; do
    [[ -n "${w}" ]] || continue
    hm_warn "  ${w}"
  done
  for w in "${HM_DEL_SKIP_DBS[@]}"; do
    [[ -n "${w}" ]] || continue
    IFS='|' read -r n o r <<<"${w}"
    hm_warn "  Pomijam DB ${n} (${o}${r:+; ${r}})"
  done
  for w in "${HM_DEL_CRON_NOTES[@]}"; do
    [[ -n "${w}" ]] || continue
    echo "  Cron      : ${w}"
  done
  echo
}

hm_ols_remove_domain_from_conf() {
  local domain="$1"
  local conf="${OLS_CONF:-}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 0
  cp -a "${conf}" "${conf}.hmtools.bak" 2>/dev/null || true
  local tmp
  tmp="$(mktemp)"
  # virtualHost / virtualhost / map — case-insensitive; też osierocone
  # „# hmtools restore — <domena>” (zostawały po archive/delete, kumulowały się).
  # Bufor prev: kasując marker/blok/mapę usuwamy też poprzedzającą pustą linię
  # (restore dopisywał „\\n# hmtools restore” — bez tego plik puchnie po cyklach).
  # Zapis: cat > conf (nie mv z mktemp) — zachowuje mode/owner jak lib/ols.sh.
  awk -v dom="${domain}" '
    BEGIN { skip=0; depth=0; have_prev=0; prev="" }
    function flush_prev() {
      if (have_prev) print prev
      have_prev=0
      prev=""
    }
    function drop_prev_if_blank() {
      if (have_prev && prev ~ /^[[:space:]]*$/) {
        have_prev=0
        prev=""
      }
    }
    function hold(l) {
      flush_prev()
      prev=l
      have_prev=1
    }
    {
      line=$0
      first=$1
      second=$2
      gsub(/\{/,"",second)
    }
    # komentarz markera restore: „# hmtools restore — <domena>”
    line ~ /^[[:space:]]*#/ && line ~ /hmtools[[:space:]]+restore/ {
      n = split(line, parts, /[[:space:]]+/)
      if (n >= 1 && parts[n] == dom) {
        drop_prev_if_blank()
        next
      }
    }
    tolower(first)=="virtualhost" {
      if (second == dom) {
        drop_prev_if_blank()
        skip=1
        depth=0
        if (line ~ /\{/) depth=1
        next
      }
    }
    skip {
      if (line ~ /\{/) depth++
      if (line ~ /\}/) {
        depth--
        if (depth <= 0) { skip=0; depth=0 }
      }
      next
    }
    tolower(first)=="map" && second == dom {
      drop_prev_if_blank()
      next
    }
    { hold(line) }
    END { flush_prev() }
  ' "${conf}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
  if ! cat "${tmp}" > "${conf}"; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
}

hm_site_execute_delete() {
  local domain="${HM_DEL_DOMAIN}"
  local total="${#HM_DEL_PLAN_KEYS[@]}"
  local i=0 key
  [[ "${total}" -gt 0 ]] || return 0

  for key in "${HM_DEL_PLAN_KEYS[@]}"; do
    i=$((i + 1))
    case "${key}" in
      pm2)
        hm_progress_bar "${i}" "${total}" "PM2 delete…"
        local line pname pid port pm2home
        for line in "${HM_DEL_PM2[@]}"; do
          IFS='|' read -r pname pid port pm2home <<<"${line}"
          if [[ -n "${pm2home}" && -d "${pm2home}" ]]; then
            hm_pm2_run_as_owner "${pm2home}" delete "${pname}" 2>/dev/null || hm_warn "pm2 delete ${pname} nieudany"
            hm_pm2_run_as_owner "${pm2home}" save 2>/dev/null || true
            hm_ok "PM2: usunięto ${pname}"
          else
            hm_warn "Brak PM2_HOME dla ${pname} — pominięto."
          fi
        done
        ;;
      lsphp)
        hm_progress_bar "${i}" "${total}" "pkill lsphp…"
        if [[ "${HM_DEL_USER_SHARED}" -eq 1 || "${HM_DEL_USER_PROTECTED}" -eq 1 ]]; then
          hm_warn "Pominięto pkill lsphp — użytkownik ${HM_DEL_USER} współdzielony/chroniony."
        else
          pkill -u "${HM_DEL_USER}" -f 'lsphp' 2>/dev/null || true
          hm_ok "LSPHP workery użytkownika ${HM_DEL_USER} zatrzymane."
        fi
        ;;
      cron)
        hm_progress_bar "${i}" "${total}" "crontab -r…"
        if [[ "${HM_DEL_USER_SHARED}" -eq 1 || "${HM_DEL_USER_PROTECTED}" -eq 1 ]]; then
          hm_warn "Pominięto crontab -r — użytkownik ${HM_DEL_USER} współdzielony/chroniony."
        else
          crontab -u "${HM_DEL_USER}" -r 2>/dev/null || true
          hm_ok "Crontab użytkownika ${HM_DEL_USER} usunięty."
        fi
        ;;
      db)
        hm_progress_bar "${i}" "${total}" "DROP DATABASE…"
        local dline dname duser dsize dorigin uq
        for dline in "${HM_DEL_DBS[@]}"; do
          IFS='|' read -r dname duser dsize dorigin <<<"${dline}"
          hm_mysql_exec -e "DROP DATABASE IF EXISTS \`${dname}\`;" 2>/dev/null \
            && hm_ok "DROP DATABASE ${dname}" \
            || hm_warn "DROP DATABASE ${dname} nieudany"
          if [[ "${PANEL:-}" == "cyberpanel" ]]; then
            hm_mysql_exec cyberpanel -e "DELETE FROM databases_databases WHERE dbName=$(hm_sql_quote "${dname}");" 2>/dev/null || true
          fi
        done
        for duser in "${HM_DEL_DB_USERS[@]}"; do
          [[ -n "${duser}" ]] || continue
          uq="$(hm_sql_quote "${duser}")"
          hm_mysql_exec -e "DROP USER IF EXISTS ${uq}@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null \
            && hm_ok "DROP USER '${duser}'@'localhost'" \
            || hm_warn "DROP USER ${duser} nieudany"
        done
        ;;
      nested-children)
        hm_progress_bar "${i}" "${total}" "FORCE-NESTED childy…"
        local child cvh cdq
        for child in "${HM_DEL_NESTED_CHILDREN[@]}"; do
          [[ -n "${child}" ]] || continue
          hm_info "Kaskada child: ${child}"
          if declare -F hm_ols_remove_domain_from_conf >/dev/null 2>&1; then
            hm_ols_remove_domain_from_conf "${child}" || true
          fi
          if [[ -n "${OLS_VHOSTS:-}" && -n "${child}" && -d "${OLS_VHOSTS}/${child}" ]]; then
            rm -rf -- "${OLS_VHOSTS:?}/${child:?}"
            hm_ok "Usunięto vhost child ${OLS_VHOSTS}/${child}"
          fi
          cdq="$(hm_sql_quote "${child}")"
          if [[ "${PANEL:-}" == "cyberpanel" ]]; then
            hm_mysql_exec cyberpanel -e "
DELETE FROM websiteFunctions_childdomains WHERE domain = ${cdq};
DELETE FROM websiteFunctions_websites WHERE domain = ${cdq};
" 2>/dev/null || true
          fi
        done
        hm_ok "Child domeny (OLS/CP) wyczyszczone."
        ;;
      cyberpanel)
        hm_progress_bar "${i}" "${total}" "CyberPanel DB…"
        local dq
        dq="$(hm_sql_quote "${domain}")"
        # childdomains pod masterem (FK) + ewentualne wiersze child jako website
        hm_mysql_exec cyberpanel -e "
DELETE c FROM websiteFunctions_childdomains c
  INNER JOIN websiteFunctions_websites w ON c.master_id = w.id
  WHERE w.domain = ${dq};
DELETE FROM websiteFunctions_childdomains WHERE domain = ${dq};
DELETE FROM websiteFunctions_websites WHERE domain = ${dq};
" 2>/dev/null || true
        hm_mysql_exec cyberpanel -e "
DELETE FROM websites_website WHERE domainName = ${dq};
" 2>/dev/null || true
        hm_ok "Wpisy CyberPanel dla ${domain} usunięte (jeśli istniały)."
        ;;
      ols)
        hm_progress_bar "${i}" "${total}" "OLS vhost…"
        hm_ols_remove_domain_from_conf "${domain}"
        if [[ -n "${HM_DEL_VHOST_DIR}" && -d "${HM_DEL_VHOST_DIR}" ]]; then
          rm -rf -- "${HM_DEL_VHOST_DIR}"
          hm_ok "Usunięto vhost dir ${HM_DEL_VHOST_DIR}"
        else
          hm_ok "Mapowania OLS wyczyszczone (brak katalogu vhost)."
        fi
        ;;
      ssl)
        hm_progress_bar "${i}" "${total}" "SSL…"
        local sp
        for sp in "${HM_DEL_SSL_PATHS[@]}"; do
          rm -rf -- "${sp}"
          hm_ok "Usunięto ${sp}"
        done
        ;;
      files)
        hm_progress_bar "${i}" "${total}" "rm -rf katalog…"
        if ! hm_is_safe_site_root_to_delete "${HM_DEL_ROOT}"; then
          hm_err "Przerwano: ścieżka niebezpieczna przy egzekucji: ${HM_DEL_ROOT}"
          return 1
        fi
        rm -rf -- "${HM_DEL_ROOT}"
        hm_ok "Usunięto katalog ${HM_DEL_ROOT}"
        ;;
      user)
        hm_progress_bar "${i}" "${total}" "userdel…"
        pkill -9 -u "${HM_DEL_USER}" 2>/dev/null || true
        if userdel "${HM_DEL_USER}" 2>/dev/null; then
          hm_ok "Usunięto użytkownika ${HM_DEL_USER}"
        else
          hm_warn "userdel ${HM_DEL_USER} nieudany (może mieć jeszcze procesy/pliki)."
        fi
        ;;
      reload)
        hm_progress_bar "${i}" "${total}" "ols reload…"
        hm_ols_reload_soft || hm_warn "ols reload nieudany"
        HM_SITES_LIST=()
        hm_discover_sites 2>/dev/null || true
        if [[ "${HM_SITE_DOMAIN:-}" == "${domain}" ]]; then
          hm_clear_site_context
          hm_info "Wyczyszczono kontekst strony — wracasz do hmtools>"
        fi
        hm_ok "OLS przeładowany, lista domen odświeżona."
        ;;
    esac
  done
  hm_progress_done "Usuwanie ${domain} zakończone."
}

hm_site_delete() {
  local domain="${1:-}"
  shift || true
  local keep_db=0 keep_ssl=0 keep_user=0 force_nested=0
  local a
  for a in "$@"; do
    case "${a}" in
      --keep-db) keep_db=1 ;;
      --keep-ssl) keep_ssl=1 ;;
      --keep-user) keep_user=1 ;;
      --force-nested) force_nested=1 ;;
      --help|-h)
        cat <<'EOF'
Użycie: webs delete <numer|domena> [--keep-db] [--keep-ssl] [--keep-user] [--force-nested]
        delete-site <numer|domena> [...]
        (w kontekście) delete-site [--keep-db] [--keep-ssl] [--keep-user] [--force-nested]

Aliasy: webs remove|destroy|rm

Operacja NIEODWRACALNA — wymaga wpisania yes oraz dokładnej nazwy domeny.
--force-nested: świadomie usuń mimo że pod katalogiem są docrooty innych domen.
EOF
        return 0
        ;;
      -*)
        hm_err "Nieznana flaga: ${a}"
        return 1
        ;;
      *)
        if [[ -z "${domain}" ]]; then
          domain="${a}"
        else
          hm_err "Za dużo argumentów: ${a}"
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "${domain}" ]]; then
    domain="${HM_SITE_DOMAIN:-}"
  fi
  [[ -n "${domain}" ]] || {
    hm_err "Użycie: delete-site <numer|domena>  (lub use <domena> → delete-site)"
    return 1
  }

  domain="$(hm_find_site_by_arg "${domain}")" || return 1

  hm_status_line "Inwentaryzacja zasobów ${domain}…"
  if ! hm_site_collect_delete_inventory "${domain}" "${keep_db}" "${keep_ssl}" "${keep_user}" "${force_nested}"; then
    hm_status_clear
    return 1
  fi
  hm_status_clear

  hm_site_print_delete_inventory
  hm_site_build_delete_plan

  if [[ "${#HM_DEL_PLAN_STEPS[@]}" -eq 0 ]]; then
    hm_err "Brak kroków do wykonania — przerwano."
    return 1
  fi

  local warn_extra="" warn_data
  if [[ "${#HM_DEL_NESTED_WARN[@]}" -gt 0 || "${#HM_DEL_NESTED_BLOCK[@]}" -gt 0 ]]; then
    warn_extra=" Wykryto nachodzące ścieżki innych domen — sprawdź ostrzeżenia powyżej!"
  fi
  if [[ "${force_nested}" -eq 1 ]]; then
    warn_extra="${warn_extra} FORCE-NESTED włączone."
  fi
  if [[ "${keep_db}" -eq 1 ]]; then
    warn_data="pliki strony zostaną bezpowrotnie skasowane z VPS (bazy MySQL zachowane: --keep-db)"
  else
    warn_data="pliki i bazy zostaną bezpowrotnie skasowane z VPS"
  fi

  if ! hm_confirm_plan_critical "${domain}" \
    "CAŁKOWITE USUNIĘCIE SERWISU WEBOWEGO: ${domain}" \
    "Operacja jest NIEODWRACALNA — ${warn_data}!${warn_extra} (Najpierw kopia: backup site ${domain})" \
    "${HM_DEL_PLAN_STEPS[@]}"; then
    return 1
  fi

  hm_site_execute_delete
}

cmd_delete_site() {
  hm_site_delete "$@"
}
