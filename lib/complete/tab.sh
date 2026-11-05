#!/usr/bin/env bash
# Complete: bind -x Tab handler + setup readline

# Wywoływane przez: bind -x '"\t": hm_tab_complete'
# WAŻNE:
# - przy 0/1 wyniku NIE wolno nic pisać na stdout/stderr (prompt znika)
# - funkcja MUSI kończyć się statusem 0: przy set -e bind -x zabija cały hmtools
#   (np. ostatnie `[[ … ]] && …` przy parzystej liczbie kandydatów → exit 1)
hm_tab_complete() {
  # bind -x działa w tym samym shellu co REPL (set -euo pipefail)
  set +e

  local line="${READLINE_LINE-}"
  local point="${READLINE_POINT-0}"
  [[ "${point}" -gt ${#line} ]] && point=${#line}

  local left="${line:0:point}"
  local right="${line:point}"

  # początek aktualnego słowa (bez =~ — bezpieczne dla bind -x)
  local start=${#left}
  local ch
  while [[ ${start} -gt 0 ]]; do
    ch="${left:start-1:1}"
    case "${ch}" in
      [[:space:]]) break ;;
    esac
    start=$((start - 1))
  done
  local prefix="${left:0:start}"
  local partial="${left:start}"

  # pierwsze słowo komendy
  local cmd="" rest_line
  rest_line="${line#"${line%%[![:space:]]*}"}"
  cmd="${rest_line%%[[:space:]]*}"

  local -a matches=()
  local m
  local re_empty='^[[:space:]]*$'
  local re_backup_site='backup[[:space:]]+(site|restore|list)[[:space:]]'
  local re_cron_site='cron[[:space:]]+site[[:space:]]'
  local re_cron_user='cron[[:space:]]+(user|edit)[[:space:]]'
  local re_pm2_site='(pm2|node|apps)[[:space:]]+site[[:space:]]'
  local re_pm2_action='(pm2|node|apps)[[:space:]]+(restart|reload|stop|start|delete|del|logs|log)[[:space:]]'
  local re_sup_action='supervisor[[:space:]]+(start|stop|restart|logs|log|tail)[[:space:]]'
  local re_mysql_db='(mysql|dbs|db)[[:space:]]+(dump|dump-local|local-dump|import|cli|console|shell|optimize|optimise)[[:space:]]'
  local re_mysql_dump_flags='(mysql|dbs|db)[[:space:]]+dump[[:space:]]+[^[:space:]]+[[:space:]]'
  local re_sec_scan='(security|sec)[[:space:]]+scan[[:space:]]'
  local re_access_site='access[[:space:]]+(status|stat|info)[[:space:]]'
  local re_access_ssh_site='access[[:space:]]+ssh[[:space:]]+(status|passwd|password)[[:space:]]'
  local re_access_ssh_keys_site='access[[:space:]]+ssh[[:space:]]+keys[[:space:]]+(list|ls|add|remove|rm|del)[[:space:]]'
  local re_access_shell_site='access[[:space:]]+ssh[[:space:]]+shell[[:space:]]+(enable|disable|on|off)[[:space:]]'
  local re_access_ftp_site='access[[:space:]]+ftp[[:space:]]+(list|ls|add|create|passwd|password|delete|del|rm)[[:space:]]'
  local re_ols_dom='(ols|lsws)[[:space:]]+(htaccess|hta|cache|lscache|proxy)[[:space:]]+(check|enable|on|status|show|flush|clear|purge)[[:space:]]'
  local re_redis_flush='redis[[:space:]]+flushdb[[:space:]]'
  local re_redis_kill='redis[[:space:]]+client[[:space:]]+kill[[:space:]]'

  if [[ "${prefix}" =~ $re_empty ]]; then
    while IFS= read -r m; do
      [[ -n "${m}" ]] && matches+=("${m}")
    done < <(hm_complete_commands "${partial}")
  else
    case "${cmd}" in
      help|h|\?)
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_commands "${partial}")
        for m in info size logs clean htaccess proxy perms; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      logs|log)
        for m in errors stats top follow live help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      health|status)
        if [[ "${prefix}" =~ health[[:space:]]+watch[[:space:]] ]]; then
          for m in install status disable help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ health[[:space:]]+--check[[:space:]] ]]; then
          for m in --disk --ssl-days --services --notify --json; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in --ram --cpu --count --check watch help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      notify)
        for m in status test setup help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      security|sec)
        if [[ "${prefix}" =~ $re_sec_scan ]]; then
          hm_complete_push_sites "${partial}"
        elif [[ "${prefix}" =~ (security|sec)[[:space:]]+ssh[[:space:]]+set[[:space:]] ]]; then
          for m in port password-auth root-login; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ (security|sec)[[:space:]]+ssh[[:space:]] ]]; then
          for m in set confirm help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status ports ssh fail2ban ban unban scan help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      firewall|fw)
        if [[ "${prefix}" =~ (firewall|fw)[[:space:]]+(allow|deny)[[:space:]] ]]; then
          for m in --from --comment --force --yes; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status allow deny remove whitelist help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      limits)
        if [[ "${prefix}" =~ limits[[:space:]]+set[[:space:]] ]]; then
          for m in --cpu --mem --io --tasks --disk --inodes --yes; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status check set clear show table help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      htaccess|hta)
        for m in check enable help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      vhost|vhconf)
        if [[ "${prefix}" =~ vhost[[:space:]]+show[[:space:]] ]]; then
          for m in --section rewrite context extprocessor module; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in show edit rollback help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      rewrite)
        if [[ "${prefix}" =~ rewrite[[:space:]]+preset[[:space:]] ]]; then
          for m in https www non-www spa list remove help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in preset help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      headers)
        if [[ "${prefix}" =~ headers[[:space:]]+preset[[:space:]] ]]; then
          for m in security remove help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in show preset help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      cache)
        if [[ "${prefix}" =~ cache[[:space:]]+settings[[:space:]] ]]; then
          for m in --ttl --exclude help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status flush settings help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      proxy)
        for m in status set-port help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      clean)
        for m in --lscache help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      disk|df)
        for m in --drive --inodes --home --heavy --count --deep help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      use|enter|cd)
        hm_ensure_sites_cached
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_filter_sites "${partial}")
        ;;
      delete-site|deletesite|destroy-site)
        local re_del_flags='delete-site[[:space:]]+[^[:space:]]+[[:space:]]'
        if [[ "${prefix}" =~ $re_del_flags || "${partial}" == --* ]]; then
          for m in --keep-db --keep-ssl --keep-user; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        fi
        ;;
      webs|sites|list)
        local re_webs_del='(webs|sites)[[:space:]]+(delete|remove|destroy|rm)[[:space:]]'
        local re_webs_arch='(webs|sites)[[:space:]]+archive[[:space:]]'
        if [[ "${prefix}" =~ $re_webs_del ]]; then
          if [[ "${partial}" == --* ]]; then
            for m in --keep-db --keep-ssl --keep-user; do
              [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
            done
          else
            hm_ensure_sites_cached
            while IFS= read -r m; do
              [[ -n "${m}" ]] && matches+=("${m}")
            done < <(hm_complete_filter_sites "${partial}")
          fi
        elif [[ "${prefix}" =~ $re_webs_arch ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in delete remove destroy rm archive --quick -q --suspended; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      suspend)
        for m in --reason --page --allow-ip help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        if [[ "${prefix}" =~ --page[[:space:]] ]]; then
          for m in maintenance 503; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      unsuspend)
        for m in help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      openbasedir)
        for m in status on off help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      archive-site)
        hm_ensure_sites_cached
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_filter_sites "${partial}")
        ;;
      backup)
        local re_backup_arch='backup[[:space:]]+archive[[:space:]]'
        if [[ "${prefix}" =~ $re_backup_arch ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        elif [[ "${prefix}" =~ $re_backup_site ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
          if [[ "${prefix}" == *list* && "full" == "${partial}"* ]]; then
            matches+=("full")
          fi
        else
          for m in setup config path root show status targets target full site local inc archive list restore prune schedule test help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        if [[ "${prefix}" =~ backup[[:space:]]+target[[:space:]] ]]; then
          for m in add help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ backup[[:space:]]+inc[[:space:]] ]]; then
          for m in init site list restore forget help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ backup[[:space:]]+(site|full|local|inc)[[:space:]] ]]; then
          for m in --target --targets --keep --yes; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      ols|lsws)
        local re_ols_sub='(ols|lsws)[[:space:]]+(htaccess|hta|cache|lscache|proxy|admin|webadmin|vhost|vhconf)[[:space:]]'
        if [[ "${prefix}" =~ $re_ols_dom ]]; then
          # ols cache flush <domena|all>
          hm_complete_push_sites "${partial}"
          if [[ "${prefix}" =~ cache|lscache ]]; then
            [[ -z "${partial}" || "all" == "${partial}"* ]] && matches+=("all")
          fi
        elif [[ "${prefix}" =~ $re_ols_sub ]]; then
          case "${BASH_REMATCH[2]}" in
            htaccess|hta)
              for m in check enable help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              # ols htaccess <domena> (bez check/enable)
              hm_complete_push_sites "${partial}"
              ;;
            cache|lscache)
              for m in status flush settings all help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              hm_complete_push_sites "${partial}"
              ;;
            proxy)
              for m in status set-port help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              hm_complete_push_sites "${partial}"
              ;;
            admin|webadmin)
              for m in status pass help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
            vhost|vhconf)
              for m in show edit rollback help; do
                [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
              done
              ;;
          esac
        else
          for m in status reload restart log logs error stats top htaccess cache proxy admin vhost help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      ssl)
        local re_ssl_dns='ssl[[:space:]]+issue[[:space:]].*--dns[[:space:]]+$'
        local re_ssl_dom='ssl[[:space:]]+(renew|renewal|issue|mail|self-signed|selfsigned|diagnose|diag)[[:space:]]'
        if [[ "${prefix}" =~ $re_ssl_dns ]]; then
          for m in pdns cloudflare; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ ssl[[:space:]]+issue[[:space:]] ]]; then
          if [[ "${partial}" == --* ]]; then
            for m in --with-www --aliases --wildcard --dns; do
              [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
            done
          else
            hm_ensure_sites_cached
            while IFS= read -r m; do
              [[ -n "${m}" ]] && matches+=("${m}")
            done < <(hm_complete_filter_sites "${partial}")
          fi
        elif [[ "${prefix}" =~ $re_ssl_dom ]]; then
          hm_ensure_sites_cached
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_sites "${partial}")
        else
          for m in issue renew renewal hostname mail self-signed diagnose help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      renew-ssl|ssl-renew)
        hm_ensure_sites_cached
        while IFS= read -r m; do
          [[ -n "${m}" ]] && matches+=("${m}")
        done < <(hm_complete_filter_sites "${partial}")
        ;;
      mysql|dbs|db)
        local re_mysql_heavy='(mysql|dbs|db)[[:space:]]+heavy[[:space:]]'
        if [[ "${prefix}" =~ $re_mysql_dump_flags ]]; then
          for m in --local help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_mysql_db ]]; then
          if [[ "${partial}" == --* ]]; then
            for m in --local help; do
              [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
            done
          else
            while IFS= read -r m; do
              [[ -n "${m}" ]] && matches+=("${m}")
            done < <(hm_complete_filter_mysql_dbs "${partial}")
          fi
        elif [[ "${prefix}" =~ $re_mysql_heavy ]]; then
          for m in --min-size help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in list ls heavy dump dump-local import cli top processlist optimize create help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      perms|perm)
        for m in check fix help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      cron|crons)
        if [[ "${prefix}" =~ $re_cron_site ]]; then
          hm_complete_push_sites "${partial}"
        elif [[ "${prefix}" =~ $re_cron_user ]]; then
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_cron_users "${partial}")
          # edit może dostać też domenę zamiast usera
          hm_complete_push_sites "${partial}"
        else
          for m in list ls all global system users site user edit help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      pm2|node|apps)
        if [[ "${prefix}" =~ $re_pm2_site ]]; then
          hm_complete_push_sites "${partial}"
        elif [[ "${prefix}" =~ $re_pm2_action ]]; then
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_pm2 "${partial}")
        else
          for m in list ls status all proxy site ports raw restart reload stop start logs save help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      php)
        local re_php_ver='php[[:space:]]+(update|upgrade|set)[[:space:]]'
        local re_php_ext_inst='php[[:space:]]+ext[[:space:]]+install[[:space:]]'
        local re_php_ext='php[[:space:]]+ext[[:space:]]'
        local re_php_ini_set='php[[:space:]]+ini[[:space:]]+set[[:space:]]'
        local re_php_ini='php[[:space:]]+ini[[:space:]]'
        if [[ "${prefix}" =~ $re_php_ver ]]; then
          local root="${OLS_ROOT:-/usr/local/lsws}" d base bn br oldnull
          oldnull="$(shopt -p nullglob || true)"
          shopt -s nullglob
          for d in "${root}"/lsphp*; do
            [[ -d "${d}" ]] || continue
            base="$(basename "${d}")"
            bn="${base#lsphp}"
            if [[ "${bn}" =~ ^[0-9][0-9]$ ]]; then
              br="${bn:0:1}.${bn:1:1}"
              [[ "${br}" == "${partial}"* || "${bn}" == "${partial}"* ]] && matches+=("${br}")
            fi
          done
          eval "${oldnull}" 2>/dev/null || shopt -u nullglob
        elif [[ "${prefix}" =~ $re_php_ext_inst ]]; then
          for m in imagick redis memcached intl zip soap gd mbstring bcmath opcache apcu; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ext ]]; then
          for m in list ls install modules help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ini_set ]]; then
          for m in memory_limit upload_max_filesize post_max_size max_execution_time max_input_vars opcache.enable; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_php_ini ]]; then
          for m in set show help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in update upgrade set ext ini restart ps help --refresh -r check-update --phpnet; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      update)
        if [[ "${prefix}" =~ update[[:space:]]+auto-security[[:space:]] ]]; then
          for m in on off; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ update[[:space:]]+(packages|security|ols|cyberpanel)[[:space:]] ]]; then
          for m in --yes --exclude; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in check security packages ols cyberpanel auto-security help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      update-php|php-update)
        local root="${OLS_ROOT:-/usr/local/lsws}" d base bn br oldnull
        oldnull="$(shopt -p nullglob || true)"
        shopt -s nullglob
        for d in "${root}"/lsphp*; do
          [[ -d "${d}" ]] || continue
          base="$(basename "${d}")"
          bn="${base#lsphp}"
          if [[ "${bn}" =~ ^[0-9][0-9]$ ]]; then
            br="${bn:0:1}.${bn:1:1}"
            [[ "${br}" == "${partial}"* || "${bn}" == "${partial}"* || "${base}" == "${partial}"* ]] && matches+=("${br}")
          fi
        done
        eval "${oldnull}" 2>/dev/null || shopt -u nullglob
        ;;
      redis)
        local re_redis_cfg='redis[[:space:]]+config[[:space:]]'
        local re_redis_client='redis[[:space:]]+client[[:space:]]'
        if [[ "${prefix}" =~ $re_redis_flush ]]; then
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_redis_dbs "${partial}")
        elif [[ "${prefix}" =~ $re_redis_kill ]]; then
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_redis_clients "${partial}")
        elif [[ "${prefix}" =~ $re_redis_cfg ]]; then
          for m in get set help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_redis_client ]]; then
          for m in kill help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status detect info memory dbs keyspace clients slowlog monitor sites who config flushdb flushall restart client help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      access)
        local re_access_ssh_keys='access[[:space:]]+ssh[[:space:]]+keys[[:space:]]'
        local re_access_ssh='access[[:space:]]+ssh[[:space:]]'
        local re_access_ftp='access[[:space:]]+ftp[[:space:]]'
        local re_access_shell='access[[:space:]]+ssh[[:space:]]+shell[[:space:]]'
        if [[ "${prefix}" =~ $re_access_site \
           || "${prefix}" =~ $re_access_ssh_site \
           || "${prefix}" =~ $re_access_ssh_keys_site \
           || "${prefix}" =~ $re_access_shell_site \
           || "${prefix}" =~ $re_access_ftp_site ]]; then
          hm_complete_push_sites "${partial}"
        elif [[ "${prefix}" =~ $re_access_ssh_keys ]]; then
          for m in list ls add remove rm del help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_access_shell ]]; then
          for m in enable disable on off help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_access_ssh ]]; then
          for m in status passwd password shell keys help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ $re_access_ftp ]]; then
          for m in list ls add create passwd password delete del rm help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status ssh ftp help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      chrome|chromium|headless)
        for m in info status which version test help; do
          [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
        done
        ;;
      supervisor)
        if [[ "${prefix}" =~ $re_sup_action ]]; then
          while IFS= read -r m; do
            [[ -n "${m}" ]] && matches+=("${m}")
          done < <(hm_complete_filter_supervisor "${partial}")
        else
          for m in status all info start stop restart reread update logs ctl help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      docker)
        if [[ "${prefix}" =~ docker[[:space:]]+compose[[:space:]] ]]; then
          for m in ls list pull up; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ docker[[:space:]]+prune[[:space:]] ]]; then
          for m in --images --volumes --dry-run --execute; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ docker[[:space:]]+(logs|restart|stop|start)[[:space:]] ]]; then
          :
        else
          for m in status all logs restart stop start compose prune help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      git)
        if [[ "${prefix}" =~ git[[:space:]]+attach[[:space:]] ]]; then
          for m in --branch --path --yes; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ git[[:space:]]+key[[:space:]] ]]; then
          for m in --force help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in status key attach path help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
      deploy)
        if [[ "${prefix}" =~ deploy[[:space:]]+rollback[[:space:]] ]]; then
          for m in --yes; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        elif [[ "${prefix}" =~ deploy[[:space:]]+config[[:space:]] ]]; then
          for m in --init help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        else
          for m in rollback config log --branch --no-build --force --yes help; do
            [[ "${m}" == "${partial}"* ]] && matches+=("${m}")
          done
        fi
        ;;
    esac
  fi

  local n="${#matches[@]}"
  if [[ "${n}" -eq 0 ]]; then
    set -e
    return 0
  fi

  if [[ "${n}" -eq 1 ]]; then
    READLINE_LINE="${prefix}${matches[0]}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#matches[0]} ))
    set -e
    return 0
  fi

  # wiele trafień: najpierw tylko wspólny prefix (BEZ listy = prompt zostaje)
  local common
  common="$(printf '%s\n' "${matches[@]}" | hm_complete_common_prefix)"
  if [[ -n "${common}" && "${#common}" -gt ${#partial} ]]; then
    READLINE_LINE="${prefix}${common}${right}"
    READLINE_POINT=$(( ${#prefix} + ${#common} ))
    set -e
    return 0
  fi

  # drugi Tab przy tym samym partial — pokaż kandydatów; readline (-p) odtworzy prompt
  printf '\n'
  local col=0
  for m in "${matches[@]}"; do
    printf '  %-36s' "${m}"
    col=$((col + 1))
    if [[ $((col % 2)) -eq 0 ]]; then
      printf '\n'
    fi
  done
  if [[ $((col % 2)) -ne 0 ]]; then
    printf '\n'
  fi

  set -e
  return 0
}

hm_setup_readline_complete() {
  [[ -t 0 ]] || return 0
  bind -x '"\t": hm_tab_complete' 2>/dev/null || true
  bind 'set completion-ignore-case on' 2>/dev/null || true
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  bind 'set skip-completed-text on' 2>/dev/null || true
  # horizontals scroll czasem zostawia „ucięty” prompt po bind -x
  bind 'set horizontal-scroll-mode off' 2>/dev/null || true
}
