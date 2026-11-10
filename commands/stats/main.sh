#!/usr/bin/env bash
# stats — historia metryk (pliki TSV, bez sieci). Mapowanie strony jak health --ram/--cpu.

_hm_cmd_help stats <<'EOF'
Użycie:
  stats collect install|status|disable|run
  stats [day|week|month] [--metric cpu|ram|swap|load|io|net|disk|inodes] [--site domena] [--json]
  stats top [--since 24h|7d] [--metric cpu] [--json]
  stats at "YYYY-MM-DD HH:MM" [--site domena] [--json]

Kolektor co 5 min (cron). Surowe próbki 48 h, potem kubełki 15 min, retencja 90 dni.
Strona: /home/<domena> (jak health) albo cgroup user-<uid>.slice.
EOF

hm_stats_dir() {
  printf '%s' "${HM_STATS_DIR:-/var/lib/hmtools/stats}"
}

hm_stats_file() {
  printf '%s/samples.tsv' "$(hm_stats_dir)"
}

hm_stats_now() {
  if [[ -n "${HM_STATS_NOW:-}" ]]; then
    printf '%s' "${HM_STATS_NOW}"
    return 0
  fi
  date +%s
}

hm_stats_site_from_text() {
  local text="$1" d best="" best_len=0
  [[ -n "${text}" ]] || return 0
  [[ -n "${HM_SITES_LIST+x}" ]] || return 0
  for d in "${HM_SITES_LIST[@]:-}"; do
    [[ -n "${d}" ]] || continue
    if [[ "${text}" == *"/home/${d}"* ]]; then
      if [[ "${#d}" -gt "${best_len}" ]]; then
        best="${d}"
        best_len="${#d}"
      fi
    fi
  done
  printf '%s' "${best}"
}

hm_stats_site_from_cgroup() {
  local cg="$1" re='user-([0-9]+)[.]slice' uid="" u d
  [[ -n "${cg}" ]] || return 0
  [[ "${cg}" =~ ${re} ]] || return 0
  uid="${BASH_REMATCH[1]:-}"
  [[ -n "${uid}" && -f "${HM_STATS_UID_MAP:-}" ]] || return 0
  while read -r u d || [[ -n "${u}" ]]; do
    [[ "${u}" == "${uid}" ]] || continue
    printf '%s' "${d}"
    return 0
  done < "${HM_STATS_UID_MAP}"
}

hm_stats_resolve_site() {
  local text="$1" cg="$2" site=""
  site="$(hm_stats_site_from_text "${text}")"
  if [[ -z "${site}" ]]; then
    site="$(hm_stats_site_from_cgroup "${cg}")"
  fi
  printf '%s' "${site}"
}

hm_stats_ensure() {
  local d
  d="$(hm_stats_dir)"
  mkdir -p "${d}" 2>/dev/null || true
  chmod 0700 "${d}" 2>/dev/null || true
  touch "$(hm_stats_file)" 2>/dev/null || true
  chmod 0600 "$(hm_stats_file)" 2>/dev/null || true
}

hm_stats_append() {
  local ts="$1" scope="$2" metric="$3" value="$4"
  [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "${ts}" "${scope}" "${metric}" "${value}" >> "$(hm_stats_file)"
}

hm_stats_collect_proc() {
  local ts="$1" line cpu_idle load disk
  [[ -r /proc/meminfo ]] || return 0
  awk -v ts="${ts}" '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { avail=$2 }
    /^SwapTotal:/ { st=$2 }
    /^SwapFree:/ { sf=$2 }
    END {
      if (total > 0) printf "%s\t-\tram\t%.2f\n", ts, (total-avail)*100/total
      if (st > 0) printf "%s\t-\tswap\t%.2f\n", ts, (st-sf)*100/st
    }
  ' /proc/meminfo | while IFS=$'\t' read -r a b c d; do
    hm_stats_append "${a}" "${b}" "${c}" "${d}"
  done
  if [[ -r /proc/loadavg ]]; then
    read -r load _ < /proc/loadavg || true
    hm_stats_append "${ts}" "-" "load" "${load}"
  fi
  if [[ -r /proc/stat ]]; then
    cpu_idle="$(awk '/^cpu / {print $5}' /proc/stat)"
    if [[ -f "$(hm_stats_dir)/cpu.prev" && "${cpu_idle}" =~ ^[0-9]+$ ]]; then
      # różnica idle nie jest procentem — zapisujemy tylko, gdy jest poprzedni total
      :
    fi
    awk -v ts="${ts}" '
      /^cpu / {
        idle=$5; total=0; for (i=2;i<=NF;i++) total+=$i
        print total, idle
      }
    ' /proc/stat > "$(hm_stats_dir)/cpu.cur"
    if [[ -f "$(hm_stats_dir)/cpu.prev" ]]; then
      cpu_idle="$(awk '
        NR==FNR { pt=$1; pi=$2; next }
        { t=$1-pt; id=$2-pi; if (t>0) printf "%.2f", (t-id)*100/t }
      ' "$(hm_stats_dir)/cpu.prev" "$(hm_stats_dir)/cpu.cur")"
      hm_stats_append "${ts}" "-" "cpu" "${cpu_idle}"
    fi
    mv "$(hm_stats_dir)/cpu.cur" "$(hm_stats_dir)/cpu.prev" 2>/dev/null || true
  fi
  if command -v df >/dev/null 2>&1; then
    disk="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    hm_stats_append "${ts}" "-" "disk" "${disk}"
    disk="$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    hm_stats_append "${ts}" "-" "inodes" "${disk}"
  fi
}

hm_stats_collect_delta() {
  local ts="$1" kind="$2" src="$3" now prev prevf delta
  [[ -r "${src}" ]] || return 0
  now="$(awk -v kind="${kind}" '
    {
      if (kind == "net") {
        if ($1 !~ /:$/ || $1 ~ /^lo:$/) next
        rx += $2
        tx += $10
      } else {
        name = $3
        if (name ~ /^(loop|ram|fd)/) next
        sectors += $6 + $10
      }
    }
    END {
      if (kind == "net") printf "%.0f", rx + tx
      else printf "%.0f", sectors * 512
    }
  ' "${src}")"
  [[ "${now}" =~ ^[0-9]+$ ]] || return 0
  prevf="$(hm_stats_dir)/${kind}.prev"
  if [[ -f "${prevf}" ]]; then
    prev="$(tr -d '[:space:]' < "${prevf}")"
    if [[ "${prev}" =~ ^[0-9]+$ && "${now}" -ge "${prev}" ]]; then
      delta="$((now - prev))"
      hm_stats_append "${ts}" "-" "${kind}" "${delta}"
    fi
  fi
  printf '%s\n' "${now}" > "${prevf}"
}

hm_stats_collect_sar() {
  local ts="$1" idle cpu
  [[ -f "${HM_STATS_SAR:-}" ]] || return 0
  idle="$(awk '/Average:/ && $2=="all" {print $NF}' "${HM_STATS_SAR}")"
  [[ "${idle}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  cpu="$(awk -v i="${idle}" 'BEGIN { printf "%.2f", 100-i }')"
  hm_stats_append "${ts}" "-" "cpu" "${cpu}"
}

hm_stats_collect_fixture() {
  local ts="$1" scope metric value
  [[ -f "${HM_STATS_FIXTURE:-}" ]] || return 0
  while read -r scope metric value || [[ -n "${scope}" ]]; do
    [[ -n "${scope}" && "${scope}" != \#* ]] || continue
    hm_stats_append "${ts}" "${scope}" "${metric}" "${value}"
  done < "${HM_STATS_FIXTURE}"
}

hm_stats_compact() {
  local file now raw_cut drop_cut tmp
  file="$(hm_stats_file)"
  [[ -f "${file}" ]] || return 0
  now="$(hm_stats_now)"
  raw_cut="$((now - 48 * 3600))"
  drop_cut="$((now - 90 * 86400))"
  tmp="${file}.tmp"
  awk -F '\t' -v raw="${raw_cut}" -v drop="${drop_cut}" '
    {
      if (NF < 4) next
      ts = $1 + 0
      if (ts < drop + 0) next
      if (ts >= raw + 0) {
        printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4
        next
      }
      b = int(ts / 900) * 900
      k = b SUBSEP $2 SUBSEP $3
      sum[k] += $4
      cnt[k]++
      bt[k] = b
      sc[k] = $2
      mt[k] = $3
    }
    END {
      for (k in sum) {
        printf "%s\t%s\t%s\t%.4f\n", bt[k], sc[k], mt[k], sum[k] / cnt[k]
      }
    }
  ' "${file}" > "${tmp}" || return 1
  mv "${tmp}" "${file}"
}

hm_stats_collect_run() {
  local ts
  hm_stats_ensure
  ts="$(hm_stats_now)"
  if [[ -f "${HM_STATS_FIXTURE:-}" ]]; then
    hm_stats_collect_fixture "${ts}"
  else
    hm_stats_collect_proc "${ts}"
    hm_stats_collect_delta "${ts}" net "${HM_STATS_NET_FILE:-/proc/net/dev}"
    hm_stats_collect_delta "${ts}" io "${HM_STATS_IO_FILE:-/proc/diskstats}"
    hm_stats_collect_sar "${ts}"
  fi
  hm_stats_compact
}

hm_stats_cron_path() {
  printf '%s' "${HM_STATS_CRON:-/etc/cron.d/hmtools-stats}"
}

hm_stats_collect_cmd() {
  local sub="${1:-run}" f bin
  case "${sub}" in
    run) hm_stats_collect_run ;;
    status|show|"")
      f="$(hm_stats_cron_path)"
      if [[ -f "${f}" ]]; then
        echo "stats collect: włączony (${f})"
      else
        echo "stats collect: wyłączony"
      fi
      if [[ -f "$(hm_stats_file)" ]]; then
        echo "  próbek: $(wc -l < "$(hm_stats_file)" | tr -d '[:space:]')  bajtów: $(wc -c < "$(hm_stats_file)" | tr -d '[:space:]')"
      fi
      ;;
    install|enable|on)
      f="$(hm_stats_cron_path)"
      bin="$(command -v hmtools 2>/dev/null || echo "${HMTOOLS_ROOT:-/opt/hmtools}/bin/hmtools")"
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "stats collect install" \
          "Cron co 5 min dopisuje metryki. Nie wysyła ich w sieć." \
          "Zapis ${f}" || return 1
      fi
      mkdir -p "$(dirname "${f}")" 2>/dev/null || true
      cat > "${f}" <<EOF
# hmtools — kolektor metryk (stats collect run)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
*/5 * * * * root ${bin} -c "stats collect run" >> ${LOG_DIR:-/hm-tools/logs}/stats.log 2>&1
EOF
      chmod 644 "${f}" 2>/dev/null || true
      echo "stats collect: włączony (${f})"
      ;;
    disable|off)
      f="$(hm_stats_cron_path)"
      if [[ ! -f "${f}" ]]; then
        echo "stats collect: już wyłączony"
        return 0
      fi
      if declare -F hm_confirm_plan >/dev/null 2>&1; then
        hm_confirm_plan "stats collect disable" \
          "Zatrzymanie kolektora." \
          "Usunięcie ${f}" || return 1
      fi
      rm -f "${f}"
      echo "stats collect: wyłączony"
      ;;
    *)
      hm_err "Użycie: stats collect install|status|disable|run"
      return 1
      ;;
  esac
}

hm_stats_window_sec() {
  case "${1:-day}" in
    day|24h) printf '86400' ;;
    week|7d) printf '604800' ;;
    month|30d|90d) printf '7776000' ;;
    *) printf '86400' ;;
  esac
}

hm_stats_series() {
  local from="$1" scope="$2" metric="$3" file
  file="$(hm_stats_file)"
  [[ -f "${file}" ]] || return 0
  awk -F '\t' -v from="${from}" -v scope="${scope}" -v metric="${metric}" '
    $1+0 >= from && $2 == scope && $3 == metric { print $1 "\t" $4 }
  ' "${file}" | sort -n | cut -f2
}

hm_stats_show_one() {
  local period="$1" metric="$2" scope="$3" json="$4" from line min avg max p95 spark pts
  from="$(( $(hm_stats_now) - $(hm_stats_window_sec "${period}") ))"
  line="$(hm_stats_series "${from}" "${scope}" "${metric}" | awk '
    { v[n++] = $1 + 0; sum += $1 }
    END {
      if (n == 0) { print "empty"; exit 0 }
      for (i = 0; i < n; i++) s[i] = v[i]
      for (i = 1; i < n; i++) {
        x = s[i]; j = i - 1
        while (j >= 0 && s[j] > x) { s[j + 1] = s[j]; j-- }
        s[j + 1] = x
      }
      pi = int(0.95 * n)
      if (pi + 0 < 0.95 * n) pi++
      if (pi < 1) pi = 1
      if (pi > n) pi = n
      buckets = 24
      if (n < buckets) buckets = n
      chars = "_.:-=+*#"
      bmax = 0
      for (b = 0; b < buckets; b++) {
        lo = int(b * n / buckets)
        hi = int((b + 1) * n / buckets)
        if (hi <= lo) hi = lo + 1
        bs = 0; bc = 0
        for (k = lo; k < hi && k < n; k++) { bs += v[k]; bc++ }
        ba_v[b] = (bc > 0) ? bs / bc : 0
        if (ba_v[b] > bmax) bmax = ba_v[b]
      }
      spark = ""; pts = ""
      for (b = 0; b < buckets; b++) {
        level = 0
        if (bmax > 0) level = int(7 * ba_v[b] / bmax)
        if (level < 0) level = 0
        if (level > 7) level = 7
        spark = spark substr(chars, level + 1, 1)
        pts = pts ((b > 0) ? "," : "") sprintf("%.2f", ba_v[b])
      }
      printf "ok\t%.4f\t%.4f\t%.4f\t%.4f\t%s\t%s\n", s[0], sum / n, s[n - 1], s[pi - 1], spark, pts
    }
  ')"
  if [[ "${line}" == "empty" || -z "${line}" ]]; then
    if [[ "${json}" -eq 1 ]]; then
      printf '{"metric":"%s","scope":"%s","empty":true}' "${metric}" "${scope}"
    else
      echo "stats ${metric} (${scope}): brak próbek"
    fi
    return 0
  fi
  IFS=$'\t' read -r _ min avg max p95 spark pts <<<"${line}"
  if [[ "${json}" -eq 1 ]]; then
    printf '{"metric":"%s","scope":"%s","min":%s,"avg":%s,"max":%s,"p95":%s,"spark":"%s","points":[%s]}' \
      "${metric}" "${scope}" "${min}" "${avg}" "${max}" "${p95}" "${spark}" "${pts}"
  else
    printf 'stats %s (%s)  min=%s avg=%s max=%s p95=%s\n' "${metric}" "${scope}" "${min}" "${avg}" "${max}" "${p95}"
    printf '%s\n' "${spark}"
  fi
}

hm_stats_show() {
  local period="$1"
  shift || true
  local metric="" site="" json=0 scope="-" a first=1
  local -a metrics=()
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --metric)
        metric="${1:-}"
        shift || true
        ;;
      --metric=*) metric="${a#--metric=}" ;;
      --site)
        site="${1:-}"
        shift || true
        ;;
      --site=*) site="${a#--site=}" ;;
      *)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
    esac
  done
  if [[ -n "${site}" ]]; then
    scope="${site}"
  fi
  if [[ -n "${metric}" ]]; then
    metrics=("${metric}")
  else
    metrics=(cpu ram swap load io net disk inodes)
  fi
  if [[ "${json}" -eq 1 ]]; then
    printf '['
  fi
  for a in "${metrics[@]}"; do
    if [[ "${json}" -eq 1 ]]; then
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
    fi
    hm_stats_show_one "${period}" "${a}" "${scope}" "${json}"
  done
  if [[ "${json}" -eq 1 ]]; then
    printf ']\n'
  fi
}

hm_stats_top() {
  local since="24h" metric="cpu" json=0 a from file
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --metric)
        metric="${1:-cpu}"
        shift || true
        ;;
      --metric=*) metric="${a#--metric=}" ;;
      --since)
        since="${1:-24h}"
        shift || true
        ;;
      --since=*) since="${a#--since=}" ;;
      *)
        hm_err "Nieznany argument: ${a}"
        return 1
        ;;
    esac
  done
  from="$(( $(hm_stats_now) - $(hm_stats_window_sec "${since}") ))"
  file="$(hm_stats_file)"
  [[ -f "${file}" ]] || { echo "stats top: brak próbek"; return 0; }
  if [[ "${json}" -eq 1 ]]; then
    printf '{"metric":"%s","sites":[' "${metric}"
  else
    echo "stats top ${metric} (od ${since})"
  fi
  local first=1 scope avg
  while IFS=$'\t' read -r scope avg; do
    [[ -n "${scope}" ]] || continue
    if [[ "${json}" -eq 1 ]]; then
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '{"site":"%s","avg":%s}' "${scope}" "${avg}"
    else
      printf '  %s  %s\n' "${scope}" "${avg}"
    fi
  done < <(awk -F '\t' -v from="${from}" -v metric="${metric}" '
    $1+0 >= from && $2 != "-" && $3 == metric { sum[$2] += $4; n[$2]++ }
    END { for (s in sum) printf "%s\t%.4f\n", s, sum[s] / n[s] }
  ' "${file}" | sort -t "$(printf '\t')" -k2,2 -nr)
  if [[ "${json}" -eq 1 ]]; then
    printf ']}\n'
  fi
}

hm_stats_at() {
  local when="" site="" json=0 a target file best dt
  while [[ $# -gt 0 ]]; do
    a="$1"
    shift
    case "${a}" in
      --json) json=1 ;;
      --site)
        site="${1:-}"
        shift || true
        ;;
      --site=*) site="${a#--site=}" ;;
      *)
        if [[ -z "${when}" ]]; then
          when="${a}"
        else
          when="${when} ${a}"
        fi
        ;;
    esac
  done
  [[ -n "${when}" ]] || { hm_err "Użycie: stats at \"YYYY-MM-DD HH:MM\""; return 1; }
  if [[ "${when}" =~ ^[0-9]+$ ]]; then
    target="${when}"
  else
    target="$(date -d "${when}" +%s 2>/dev/null || true)"
  fi
  [[ "${target}" =~ ^[0-9]+$ ]] || { hm_err "Nieczytelna data: ${when}"; return 1; }
  file="$(hm_stats_file)"
  [[ -f "${file}" ]] || { echo "stats at: brak próbek"; return 0; }
  best="$(awk -F '\t' -v t="${target}" '
    {
      if (NF < 4) next
      d = $1 - t
      if (d < 0) d = -d
      if (d <= 300 && (have == 0 || d < bestd)) {
        best = $1
        bestd = d
        have = 1
      }
    }
    END { if (best != "") print best }
  ' "${file}")"
  if [[ -z "${best}" ]]; then
    echo "stats at: brak próbki w promieniu 5 min"
    return 0
  fi
  if [[ "${json}" -eq 1 ]]; then
    printf '{"ts":%s,"samples":[' "${best}"
  else
    echo "stats at ${best}"
  fi
  local first=1 scope metric value
  while IFS=$'\t' read -r dt scope metric value; do
    [[ "${dt}" == "${best}" ]] || continue
    [[ -z "${site}" || "${scope}" == "${site}" || "${scope}" == "-" ]] || continue
    if [[ "${json}" -eq 1 ]]; then
      [[ "${first}" -eq 1 ]] || printf ','
      first=0
      printf '{"scope":"%s","metric":"%s","value":%s}' "${scope}" "${metric}" "${value}"
    else
      printf '  %s  %s  %s\n' "${scope}" "${metric}" "${value}"
    fi
  done < "${file}"
  if [[ "${json}" -eq 1 ]]; then
    printf ']}\n'
  fi
}

cmd_stats() {
  local sub="${1:-day}"
  shift || true
  case "${sub}" in
    collect) hm_stats_collect_cmd "${1:-run}" ;;
    top) hm_stats_top "$@" ;;
    at) hm_stats_at "$@" ;;
    day|week|month) hm_stats_show "${sub}" "$@" ;;
    help|-h|--help)
      hm_help_topic stats 2>/dev/null || true
      ;;
    --*)
      hm_stats_show day "${sub}" "$@"
      ;;
    *)
      hm_err "Użycie: stats [day|week|month|top|at|collect]"
      return 1
      ;;
  esac
}

_hm_cmd_register stats cmd_stats 0
