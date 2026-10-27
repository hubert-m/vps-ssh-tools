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
  tags="$(printf '%s' "${json}" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' || true)"
  if [[ -z "${tags}" ]]; then
    echo ""
    return 0
  fi
  printf '%s\n' "${tags}" | sort -V | tail -1
}

# Fallback: plik VERSION z brancha (np. v0.1.0 zanim powstanie tag)
latest_version_file() {
  curl -fsSL --retry 2 \
    "https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/VERSION" 2>/dev/null \
    | tr -d '[:space:]' || true
}

# Ostateczny fallback: branch@sha
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
  # Preferencja: HMTOOLS_VERSION → najnowszy tag → VERSION z brancha → branch@sha
  if [[ -n "${HMTOOLS_VERSION:-}" ]]; then
    echo "${HMTOOLS_VERSION}"
    return 0
  fi
  local tag ver
  tag="$(latest_repo_tag)"
  if [[ -n "${tag}" ]]; then
    echo "${tag}"
    return 0
  fi
  ver="$(latest_version_file)"
  if [[ -n "${ver}" ]]; then
    echo "${ver}"
    return 0
  fi
  latest_branch_sha
}

# 1 = pobieraj tarball brancha zamiast taga (gdy wersja z VERSION, a taga jeszcze nie ma)
USE_BRANCH_TARBALL=0

tarball_url_for_version() {
  local ver="$1"
  if [[ "${USE_BRANCH_TARBALL}" == "1" || "${ver}" == *"@"* ]]; then
    echo "https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
  else
    # jeśli tag nie istnieje jeszcze na remote — fallback do brancha
    local code
    code="$(curl -sSL -o /dev/null -w '%{http_code}' \
      "https://github.com/${REPO_SLUG}/archive/refs/tags/${ver}.tar.gz" 2>/dev/null || echo 000)"
    if [[ "${code}" == "200" ]]; then
      echo "https://github.com/${REPO_SLUG}/archive/refs/tags/${ver}.tar.gz"
    else
      echo "https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    fi
  fi
}

print_changelog_file() {
  local ver="$1"
  local title="$2"
  local f="${DEST}/changelogs/${ver}.txt"
  if [[ ! -f "${f}" ]]; then
    f="$(ls -1 "${DEST}/changelogs"/v*.txt 2>/dev/null | sort -V | tail -1 || true)"
  fi
  if [[ -z "${f}" || ! -f "${f}" ]]; then
    return 0
  fi
  echo
  echo "════════════════════════════════════════"
  echo " ${title}"
  echo "════════════════════════════════════════"
  echo
  cat "${f}"
  echo
}

print_welcome() {
  cat <<EOF

════════════════════════════════════════
 Witaj w hmtools!
════════════════════════════════════════

Narzędzia zostały zainstalowane w: ${DEST}
Uruchomienie:

  hmtools

W środku:
  help              — lista komend
  webs              — lista stron na serwerze
  use <n|domena>    — wejście w kontekst strony
  version           — wersja + co nowego
  update-hmtools    — aktualizacja z GitHuba
  uninstall-hmtools — usunięcie hmtools z serwera
  exit              — wyjście

Dokumentacja: ${DEST}/README.md
Logi:         ${DEST}/logs/
Konfiguracja: ${DEST}/config/hmtools.conf

Google Drive (backupy):
  hmtools → backup setup

EOF
}

TARGET_VERSION="$(resolve_target_version)"
if [[ -z "${TARGET_VERSION}" ]]; then
  echo "Nie udało się ustalić wersji z GitHuba (tagi / branch)." >&2
  exit 1
fi

# Brak taga na GitHubie, ale znamy wersję z VERSION → bierzemy tarball brancha
if [[ -z "$(latest_repo_tag)" ]] && [[ "${TARGET_VERSION}" != *"@"* ]]; then
  USE_BRANCH_TARBALL=1
fi

CURRENT_VERSION="$(installed_version)"
PREV_VERSION="${CURRENT_VERSION}"

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
  if [[ -f "${DEST}/changelogs/${CURRENT_VERSION}.txt" ]]; then
    print_changelog_file "${CURRENT_VERSION}" "Co zawiera ${CURRENT_VERSION}"
  fi
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
  if [[ -n "${base}" && -e "${base}/bin/hmtools" && -d "${base}/lib" && -d "${base}/commands" ]]; then
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

is_gzip_file() {
  local f="$1"
  # Nie wymagamy komendy gzip — sprawdzamy magię 1f 8b
  local b1 b2
  b1="$(od -An -tx1 -N 2 "${f}" 2>/dev/null | tr -d ' \n' || true)"
  [[ "${b1}" == "1f8b" ]]
}

extract_github_tree() {
  # $1 = url tarballa → wypisz ścieżkę katalogu źródłowego na stdout; logi na stderr
  local url="$1"
  local label="${2:-}"
  local work tarball extracted="" d
  work="$(mktemp -d /tmp/hmtools-install-XXXXXX)"
  tarball="${work}/repo.tar.gz"
  echo "Pobieranie${label:+ (${label})}: ${url}" >&2
  if ! curl -fsSL --retry 3 --retry-delay 1 "${url}" -o "${tarball}"; then
    echo "Nie udało się pobrać: ${url}" >&2
    rm -rf "${work}"
    return 1
  fi
  if ! is_gzip_file "${tarball}"; then
    echo "Pobrany plik nie jest archiwum .tar.gz (GitHub mógł zwrócić HTML/błąd)." >&2
    echo "URL: ${url}" >&2
    head -c 240 "${tarball}" >&2 || true
    echo >&2
    rm -rf "${work}"
    return 1
  fi
  if ! tar -xzf "${tarball}" -C "${work}"; then
    echo "Błąd tar przy rozpakowywaniu: ${url}" >&2
    rm -rf "${work}"
    return 1
  fi
  rm -f "${tarball}"

  # Bez find|head — przy set -o pipefail to potrafi się wywalić (SIGPIPE)
  for d in "${work}"/*; do
    if [[ -d "${d}" ]]; then
      extracted="${d}"
      break
    fi
  done

  if [[ -z "${extracted}" || ! -e "${extracted}/bin/hmtools" ]]; then
    echo "Nieprawidłowe archiwum repozytorium." >&2
    echo "URL: ${url}" >&2
    echo "TMP: ${work}" >&2
    ls -la "${work}" >&2 || true
    if [[ -n "${extracted}" ]]; then
      echo "Katalog: ${extracted}" >&2
      ls -la "${extracted}" >&2 || true
      ls -la "${extracted}/bin" >&2 || true
    fi
    rm -rf "${work}"
    return 1
  fi

  chmod +x "${extracted}/bin/hmtools" 2>/dev/null || true
  chmod +x "${extracted}/install.sh" 2>/dev/null || true
  chmod +x "${extracted}/scripts/"*.sh 2>/dev/null || true

  # trap posprząta cały work (w tym extracted)
  TMP_ROOT="${work}"
  printf '%s\n' "${extracted}"
}

fetch_remote_src() {
  local url extracted
  url="$(tarball_url_for_version "${TARGET_VERSION}")"
  if extracted="$(extract_github_tree "${url}" "${TARGET_VERSION}")"; then
    printf '%s\n' "${extracted}"
    return 0
  fi

  # Fallback: branch (bootstrap i tak pochodzi z brancha — nowsze poprawki niż stary tag)
  local branch_url="https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
  if [[ "${url}" != "${branch_url}" ]]; then
    echo "Próbuję fallback: branch ${REPO_BRANCH} ..." >&2
    if extracted="$(extract_github_tree "${branch_url}" "branch ${REPO_BRANCH}")"; then
      printf '%s\n' "${extracted}"
      return 0
    fi
  fi

  echo "Nie udało się pobrać źródeł hmtools." >&2
  exit 1
}

INSTALL_VERSION="${TARGET_VERSION}"
USE_LOCAL=0
if SRC="$(resolve_local_src)"; then
  USE_LOCAL=1
  echo "Tryb: lokalne źródło (${SRC})"
  if [[ -f "${SRC}/VERSION" ]]; then
    INSTALL_VERSION="$(tr -d '[:space:]' < "${SRC}/VERSION")"
  else
    local_v="$(local_git_version "${SRC}")"
    if [[ -n "${local_v}" ]]; then
      INSTALL_VERSION="${local_v}"
    fi
  fi
  if [[ "${IS_UPDATE}" -eq 1 && -n "${CURRENT_VERSION}" && "${CURRENT_VERSION}" == "${INSTALL_VERSION}" && "${FORCE}" != "1" ]]; then
    echo
    echo "hmtools jest już w wersji lokalnego źródła (${CURRENT_VERSION}). Nic do zrobienia."
    exit 0
  fi
else
  echo "Tryb: pobranie z GitHuba (wersja ${TARGET_VERSION})"
  SRC="$(fetch_remote_src)"
  if [[ -f "${SRC}/VERSION" ]]; then
    src_ver="$(tr -d '[:space:]' < "${SRC}/VERSION")"
    if [[ "${INSTALL_VERSION}" == *"@"* && -n "${src_ver}" ]]; then
      INSTALL_VERSION="${src_ver}"
    fi
  fi
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
      --exclude 'logs/' \
      --exclude '*.plan.md' \
      "${from}/" "${DEST}/"
  else
    local d
    for d in bin lib commands scripts changelogs; do
      [[ -d "${from}/${d}" ]] || continue
      rm -rf "${DEST}/${d}"
      cp -a "${from}/${d}" "${DEST}/"
    done
    mkdir -p "${DEST}/config"
    cp -a "${from}/config/hmtools.conf.example" "${DEST}/config/"
    [[ -f "${from}/README.md" ]] && cp -a "${from}/README.md" "${DEST}/"
    [[ -f "${from}/CHANGELOG.md" ]] && cp -a "${from}/CHANGELOG.md" "${DEST}/"
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

mkdir -p "${DEST}/logs"

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

# Krótki wpis w logu instalacji (niezależny od REPL)
{
  printf '%s [INFO] install version=%s mode=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${INSTALL_VERSION}" \
    "$([ "${IS_UPDATE}" -eq 1 ] && echo update || echo install)"
} >> "${DEST}/logs/hmtools-$(date +%Y-%m-%d).log" 2>/dev/null || true

echo
echo "Symlink: ${BIN_LINK} → ${DEST}/bin/hmtools"
echo "Wersja  : ${INSTALL_VERSION}"
echo "Logi    : ${DEST}/logs/"

if [[ "${IS_UPDATE}" -eq 0 ]]; then
  print_welcome
  print_changelog_file "${INSTALL_VERSION}" "Co nowego w ${INSTALL_VERSION}"
else
  echo "Aktualizacja zakończona: ${PREV_VERSION:-?} → ${INSTALL_VERSION}"
  print_changelog_file "${INSTALL_VERSION}" "Co nowego w ${INSTALL_VERSION}"
  echo "Ponowny update: curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/install.sh | bash"
  echo "                lub: hmtools → update-hmtools"
fi