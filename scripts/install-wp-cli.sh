#!/usr/bin/env bash
# Oficjalny WP-CLI (phar) → ${DEST}/lib/wp-cli/wp-cli.phar
# Wołane z install.sh (update-hmtools) oraz z: wp cli-update
#
# Źródło: https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
# Suma:   …/wp-cli.phar.sha512 (sam hash SHA-512)
set -euo pipefail

WPCLI_URL="${HMTOOLS_WPCLI_URL:-https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar}"
WPCLI_SHA_URL="${HMTOOLS_WPCLI_SHA_URL:-https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512}"

hm_wpcli_sha512() {
  local file="$1"
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "${file}" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "${file}" | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha512 "${file}" | awk '{print $NF}'
    return 0
  fi
  return 1
}

# 0 = zgodne, 1 = niezgodne / zły plik sumy
hm_wpcli_verify_sha512() {
  local file="$1" sumfile="$2" expect got
  [[ -s "${file}" && -s "${sumfile}" ]] || return 1
  expect="$(awk 'NF { print $1; exit }' "${sumfile}" | tr -d '[:space:]')"
  [[ "${expect}" =~ ^[0-9a-fA-F]{128}$ ]] || return 1
  got="$(hm_wpcli_sha512 "${file}")" || return 1
  [[ "${got}" == "${expect}" ]]
}

hm_wpcli_install() {
  local dest="${1:-${HMTOOLS_DEST:-${HMTOOLS_ROOT:-/hm-tools}}}"
  local dir="${dest}/lib/wp-cli"
  local target="${dir}/wp-cli.phar"
  local work phar sum

  if ! command -v curl >/dev/null 2>&1; then
    echo "WP-CLI: brak curl — nie pobieram phar." >&2
    return 1
  fi
  if ! command -v sha512sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
    echo "WP-CLI: brak sha512sum/shasum/openssl — odmowa instalacji bez weryfikacji." >&2
    return 1
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-wpcli.XXXXXX")"
  phar="${work}/wp-cli.phar"
  sum="${work}/wp-cli.phar.sha512"

  echo "WP-CLI: pobieranie ${WPCLI_URL}"
  if ! curl -fsSL --retry 2 --max-time 120 -o "${phar}" "${WPCLI_URL}"; then
    echo "WP-CLI: pobranie phar nieudane." >&2
    rm -rf "${work}"
    return 1
  fi
  if ! curl -fsSL --retry 2 --max-time 60 -o "${sum}" "${WPCLI_SHA_URL}"; then
    echo "WP-CLI: pobranie sumy SHA-512 nieudane — phar odrzucony." >&2
    rm -rf "${work}"
    return 1
  fi
  if ! hm_wpcli_verify_sha512 "${phar}" "${sum}"; then
    echo "WP-CLI: suma SHA-512 niezgodna — phar odrzucony." >&2
    rm -rf "${work}"
    return 1
  fi

  mkdir -p "${dir}"
  # podmiana z pliku tymczasowego (nie curl -O w cwd)
  local stage="${dir}/wp-cli.phar.new"
  cp -f "${phar}" "${stage}"
  chmod 755 "${stage}"
  mv -f "${stage}" "${target}"
  rm -rf "${work}"
  echo "WP-CLI: zainstalowano ${target}"
  if [[ -x "${target}" ]]; then
    "${target}" --version 2>/dev/null || true
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  hm_wpcli_install "${1:-${HMTOOLS_DEST:-${HMTOOLS_ROOT:-/hm-tools}}}"
fi
