#!/usr/bin/env bash
# Regresja: Tab complete nazw Supervisora
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT}/lib/complete/helpers.sh"

hm_supervisor_list_names() {
  cat <<'EOF'
opinieofirmach-worker:opinieofirmach-worker_00
scraper-worker:scraper-worker_00
EOF
}

fail=0
out="$(hm_complete_filter_supervisor "opini")"
if printf '%s\n' "${out}" | grep -qx 'opinieofirmach-worker:opinieofirmach-worker_00'; then
  echo "OK   prefix opini → worker"
else
  echo "FAIL prefix: ${out}"
  fail=1
fi

out="$(hm_complete_filter_supervisor "scraper")"
if printf '%s\n' "${out}" | grep -qx 'scraper-worker:scraper-worker_00'; then
  echo "OK   substring scraper"
else
  echo "FAIL scraper: ${out}"
  fail=1
fi

out="$(hm_complete_filter_supervisor "al")"
if printf '%s\n' "${out}" | grep -qx 'all'; then
  echo "OK   all suggested"
else
  echo "FAIL all: ${out}"
  fail=1
fi

if grep -q 're_sup_action' "${ROOT}/lib/complete/tab.sh" \
  && grep -q 'hm_complete_filter_supervisor' "${ROOT}/lib/complete/tab.sh"; then
  echo "OK   tab.sh wired"
else
  echo "FAIL tab.sh missing supervisor name complete"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
