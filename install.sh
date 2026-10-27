#!/usr/bin/env bash
# Instalacja / aktualizacja hmtools → /hm-tools
#
# Z GitHuba (zalecane — działa jako instalacja i update):
#   curl -fsSL https://raw.githubusercontent.com/hubert-m/vps-ssh-tools/develop/install.sh | bash
#
# Równoważne (curl podąża za przekierowaniem):
#   curl -fsSL https://github.com/hubert-m/vps-ssh-tools/raw/develop/install.sh | bash
#
# Z lokalnego klona repo:
#   bash install.sh
#
set -euo pipefail

DEST="${HMTOOLS_DEST:-/hm-tools}"
BIN_LINK="${HMTOOLS_BIN_LINK:-/usr/local/bin/hmtools}"
REPO_SLUG="${HMTOOLS_REPO:-hubert-m/vps-ssh-tools}"
REPO_BRANCH="${HMTOOLS_BRANCH:-develop}"
REPO_TARBALL_URL="${HMTOOLS_TARBALL_URL:-https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz}"

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
if [[ "${IS_UPDATE}" -eq 1 ]]; then
  echo "Aktualizacja hmtools w ${DEST}"
else
  echo "Instalacja hmtools → ${DEST}"
fi
echo "Źródło: ${REPO_SLUG}@${REPO_BRANCH}"

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
  # Gdy skrypt jest plikiem (nie pipe), sprawdź czy to pełne repo
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

fetch_remote_src() {
  TMP_ROOT="$(mktemp -d /tmp/hmtools-install-XXXXXX)"
  local tarball="${TMP_ROOT}/repo.tar.gz"
  echo "Pobieranie ${REPO_TARBALL_URL} ..."
  if ! curl -fsSL --retry 3 --retry-delay 1 "${REPO_TARBALL_URL}" -o "${tarball}"; then
    echo "Nie udało się pobrać archiwum z GitHuba." >&2
    echo "Sprawdź branch (${REPO_BRANCH}) i sieć." >&2
    exit 1
  fi
  tar -xzf "${tarball}" -C "${TMP_ROOT}"
  # github archive → vps-ssh-tools-develop/
  local extracted
  extracted="$(find "${TMP_ROOT}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -z "${extracted}" || ! -x "${extracted}/bin/hmtools" ]]; then
    echo "Nieprawidłowe archiwum repozytorium." >&2
    exit 1
  fi
  echo "${extracted}"
}

if SRC="$(resolve_local_src)"; then
  echo "Tryb: lokalne źródło (${SRC})"
else
  echo "Tryb: pobranie z GitHuba (curl | bash lub brak lokalnego drzewa)"
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
    # --delete usuwa stare pliki narzędzi, ale chronimy config/hmtools.conf osobno
    rsync -a --delete \
      --exclude '.git/' \
      --exclude 'config/hmtools.conf' \
      --exclude '*.plan.md' \
      "${from}/" "${DEST}/"
  else
    # Fallback: nadpisz katalogi narzędzi, nie ruszaj conf
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

# Przywróć / utwórz conf
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

# Zapis metadanych instalacji
cat > "${DEST}/.installed" <<EOF
repo=${REPO_SLUG}
branch=${REPO_BRANCH}
installed_at=$(date -Iseconds 2>/dev/null || date)
mode=$([ "${IS_UPDATE}" -eq 1 ] && echo update || echo install)
EOF

echo
echo "Symlink: ${BIN_LINK} → ${DEST}/bin/hmtools"
if [[ "${IS_UPDATE}" -eq 1 ]]; then
  echo "Aktualizacja zakończona."
else
  echo "Instalacja zakończona."
fi
echo "Uruchom: hmtools"
echo "Update w przyszłości (to samo polecenie):"
echo "  curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/install.sh | bash"
echo "Konfiguracja Google Drive: hmtools → backup setup"
