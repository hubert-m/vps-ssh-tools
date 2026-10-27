#!/usr/bin/env bash
# Instalacja / aktualizacja hmtools → /hm-tools
#
# Z GitHuba (zalecane — działa jako instalacja i update):
#   curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
#
# Wymuszenie reinstalacji tej samej wersji:
#   HMTOOLS_FORCE=1 curl -fsSL ... | bash
#
# Z lokalnego klona repo:
#   bash install.sh
#
set -euo pipefail

DEST="${HMTOOLS_DEST:-/hm-tools}"
BIN_LINK="${HMTOOLS_BIN_LINK:-/usr/local/bin/hmtools}"
REPO_SLUG="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
REPO_BRANCH="${HMTOOLS_BRANCH:-develop}"
FORCE="${HMTOOLS_FORCE:-0}"
API_BASE="https://api.github.com/repos/${REPO_SLUG}"

umask 022

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Uruchom jako root." >&2
  exit 1
fi

for need in curl tar; do
  if ! command -v "${need}" >/dev/null 2>&1; then
    echo "Brak wymaganej komendy: ${need}" >&2
    exit 1
  fi
done

IS_UPDATE=0
[[ -x "${DEST}/bin/hmtools" ]] && IS_UPDATE=1

installed_version() {
  if [[ -f "${DEST}/VERSION" ]]; then
    tr -d '[:space:]' < "${DEST}/VERSION"
    return 0
  fi
  if [[ -f "${DEST}/.installed" ]]; then
    awk -F= '/^version=/{print $2; exit}' "${DEST}/.installed" | tr -d '[:space:]'
    return 0
  fi
  echo ""
}

# Najnowszy tag z GitHuba (semver sort). Puste, jeśli brak tagów.
latest_repo_tag() {
  local json tags
  json="$(curl -fsSL --retry 3 --retry-delay 1 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: hmtools-installer' \
    "${API_BASE}/tags?per_page=100" 2>/dev/null || true)"
  if [[ -z "${json}" || "${json}" == "[]" ]]; then
    echo ""
    return 0
  fi
  # wyciągnij name; sort -V; ostatni = najnowszy
  tags="$(printf '%s' "${json}" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  if [[ -z "${tags}" ]]; then
    echo ""
    return 0
  fi
  printf '%s\n' "${tags}" | sort -V | tail -1
}

# Fallback gdy brak tagów: krótki SHA HEAD brancha
latest_branch_sha() {
  local json sha
  json="$(curl -fsSL --retry 3 --retry-delay 1 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: hmtools-installer' \
    "${API_BASE}/commits/${REPO_BRANCH}" 2>/dev/null || true)"
  sha="$(printf '%s' "${json}" | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' | head -1 \
    | sed -E 's/.*"([0-9a-f]+)"$/\1/' || true)"
  if [[ -n "${sha}" ]]; then
    echo "${REPO_BRANCH}@${sha:0:7}"
  else
    echo ""
  fi
}

resolve_target_version() {
  # Preferencja: HMTOOLS_VERSION (konkretny tag) → najnowszy tag → branch@sha
  if [[ -n "${HMTOOLS_VERSION:-}" ]]; then
    echo "${HMTOOLS_VERSION}"
    return 0
  fi
  local tag
  tag="$(latest_repo_tag)"
  if [[ -n "${tag}" ]]; then
    echo "${tag}"
    return 0
  fi
  latest_branch_sha
}

tarball_url_for_version() {
  local ver="$1"
  if [[ "${ver}" == *"@"* ]]; then
    # develop@abc1234 → tarball brancha (pełne drzewo brancha)
    echo "https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
  else
    echo "https://github.com/${REPO_SLUG}/archive/refs/tags/${ver}.tar.gz"
  fi
}

TARGET_VERSION="$(resolve_target_version)"
if [[ -z "${TARGET_VERSION}" ]]; then
  echo "Nie udało się ustalić wersji z GitHuba (tagi / branch)." >&2
  exit 1
fi

CURRENT_VERSION="$(installed_version)"

echo "Repozytorium : ${REPO_SLUG}"
echo "Wersja remote: ${TARGET_VERSION}"
if [[ -n "${CURRENT_VERSION}" ]]; then
  echo "Wersja local : ${CURRENT_VERSION}"
else
  echo "Wersja local : (brak — świeża instalacja)"
fi

if [[ "${IS_UPDATE}" -eq 1 && -n "${CURRENT_VERSION}" && "${CURRENT_VERSION}" == "${TARGET_VERSION}" && "${FORCE}" != "1" ]]; then
  echo
  echo "hmtools jest już w najnowszej wersji (${CURRENT_VERSION}). Nic do zrobienia."
  echo "Wymuszenie: HMTOOLS_FORCE=1 curl -fsSL ... | bash"
  echo "            lub: hmtools → update-hmtools --force"
  exit 0
fi

if [[ "${IS_UPDATE}" -eq 1 ]]; then
  echo "Aktualizacja hmtools w ${DEST} → ${TARGET_VERSION}"
else
  echo "Instalacja hmtools → ${DEST} (${TARGET_VERSION})"
fi

# --- Znajdź drzewo źródeł (lokalny klon vs curl|bash) ---
SRC=""
TMP_ROOT=""
CLEANUP() {
  if [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap CLEANUP EXIT

resolve_local_src() {
  local base=""
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && "${BASH_SOURCE[0]}" != "-" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    if [[ -f "${BASH_SOURCE[0]}" ]]; then
      base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
  fi
  if [[ -n "${base}" && -x "${base}/bin/hmtools" && -d "${base}/lib" && -d "${base}/commands" ]]; then
    echo "${base}"
    return 0
  fi
  return 1
}

local_git_version() {
  local base="$1"
  if [[ -d "${base}/.git" ]] && command -v git >/dev/null 2>&1; then
    # dokładny tag na HEAD, inaczej describe, inaczej short sha
    local v
    v="$(git -C "${base}" describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "${v}" ]]; then
      echo "${v}"
      return 0
    fi
    v="$(git -C "${base}" describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "${v}" ]]; then
      local sha
      sha="$(git -C "${base}" rev-parse --short HEAD 2>/dev/null || true)"
      echo "${v}+${sha}"
      return 0
    fi
    echo "${REPO_BRANCH}@$(git -C "${base}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    return 0
  fi
  echo ""
}

fetch_remote_src() {
  local url
  url="$(tarball_url_for_version "${TARGET_VERSION}")"
  TMP_ROOT="$(mktemp -d /tmp/hmtools-install-XXXXXX)"
  local tarball="${TMP_ROOT}/repo.tar.gz"
  echo "Pobieranie ${url} ..."
  if ! curl -fsSL --retry 3 --retry-delay 1 "${url}" -o "${tarball}"; then
    echo "Nie udało się pobrać archiwum z GitHuba (${TARGET_VERSION})." >&2
    exit 1
  fi
  tar -xzf "${tarball}" -C "${TMP_ROOT}"
  local extracted
  extracted="$(find "${TMP_ROOT}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -z "${extracted}" || ! -x "${extracted}/bin/hmtools" ]]; then
    echo "Nieprawidłowe archiwum repozytorium." >&2
    exit 1
  fi
  echo "${extracted}"
}

INSTALL_VERSION="${TARGET_VERSION}"
USE_LOCAL=0
if SRC="$(resolve_local_src)"; then
  USE_LOCAL=1
  echo "Tryb: lokalne źródło (${SRC})"
  local_v="$(local_git_version "${SRC}")"
  if [[ -n "${local_v}" ]]; then
    INSTALL_VERSION="${local_v}"
  fi
  # Przy lokalnym klonie też pomiń, jeśli ta sama wersja (chyba że FORCE)
  if [[ "${IS_UPDATE}" -eq 1 && -n "${CURRENT_VERSION}" && "${CURRENT_VERSION}" == "${INSTALL_VERSION}" && "${FORCE}" != "1" ]]; then
    echo
    echo "hmtools jest już w wersji lokalnego źródła (${CURRENT_VERSION}). Nic do zrobienia."
    exit 0
  fi
else
  echo "Tryb: pobranie z GitHuba (wersja ${TARGET_VERSION})"
  SRC="$(fetch_remote_src)"
fi

# --- Zachowaj istniejącą konfigurację ---
CONF_BACKUP=""
if [[ -f "${DEST}/config/hmtools.conf" ]]; then
  CONF_BACKUP="$(mktemp /tmp/hmtools.conf.XXXXXX)"
  cp -a "${DEST}/config/hmtools.conf" "${CONF_BACKUP}"
  echo "Zachowano istniejącą konfigurację (hmtools.conf)."
fi

mkdir -p "${DEST}"

install_tree() {
  local from="$1"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git/' \
      --exclude 'config/hmtools.conf' \
      --exclude 'VERSION' \
      --exclude '.installed' \
      --exclude '*.plan.md' \
      "${from}/" "${DEST}/"
  else
    local d
    for d in bin lib commands scripts; do
      rm -rf "${DEST}/${d}"
      cp -a "${from}/${d}" "${DEST}/"
    done
    mkdir -p "${DEST}/config"
    cp -a "${from}/config/hmtools.conf.example" "${DEST}/config/"
    [[ -f "${from}/README.md" ]] && cp -a "${from}/README.md" "${DEST}/"
    [[ -f "${from}/install.sh" ]] && cp -a "${from}/install.sh" "${DEST}/"
  fi
}

install_tree "${SRC}"

mkdir -p "${DEST}/config"
if [[ -n "${CONF_BACKUP}" && -f "${CONF_BACKUP}" ]]; then
  cp -a "${CONF_BACKUP}" "${DEST}/config/hmtools.conf"
  rm -f "${CONF_BACKUP}"
elif [[ ! -f "${DEST}/config/hmtools.conf" ]]; then
  cp "${DEST}/config/hmtools.conf.example" "${DEST}/config/hmtools.conf"
  echo "Utworzono ${DEST}/config/hmtools.conf (z przykładu)."
fi

chmod +x "${DEST}/bin/hmtools"
chmod +x "${DEST}/install.sh" 2>/dev/null || true
chmod +x "${DEST}/scripts/"*.sh 2>/dev/null || true

ln -sfn "${DEST}/bin/hmtools" "${BIN_LINK}"

# Zapis wersji
printf '%s\n' "${INSTALL_VERSION}" > "${DEST}/VERSION"
cat > "${DEST}/.installed" <<EOF
repo=${REPO_SLUG}
version=${INSTALL_VERSION}
branch=${REPO_BRANCH}
installed_at=$(date -Iseconds 2>/dev/null || date)
mode=$([ "${IS_UPDATE}" -eq 1 ] && echo update || echo install)
source=$([ "${USE_LOCAL}" -eq 1 ] && echo local || echo github)
EOF

echo
echo "Symlink: ${BIN_LINK} → ${DEST}/bin/hmtools"
echo "Wersja  : ${INSTALL_VERSION}"
if [[ "${IS_UPDATE}" -eq 1 ]]; then
  echo "Aktualizacja zakończona."
else
  echo "Instalacja zakończona."
fi
echo "Uruchom: hmtools"
echo "Update:  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/install.sh | bash"
echo "         lub: hmtools → update-hmtools"
echo "Konfiguracja Google Drive: hmtools → backup setup"
