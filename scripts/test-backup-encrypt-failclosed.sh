#!/usr/bin/env bash
# Regresja: BACKUP_ENCRYPT_PASSPHRASE → fail-closed (bez plaintext) + export dla openssl
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
# shellcheck disable=SC1091
source lib/common/ui.sh
hm_file_log_ui() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

fail=0

# shellcheck disable=SC1091
source commands/backup/core.sh

base="$(mktemp -d "${TMPDIR:-/tmp}/hmtools-enc-test.XXXXXX")"
trap 'rm -rf "${base}"' EXIT
src="${base}/secret.txt"
echo "payload" > "${src}"

# bez passphrase → plaintext OK
unset BACKUP_ENCRYPT_PASSPHRASE || true
out="$(hm_backup_maybe_encrypt_file "${src}")"
if [[ "${out}" == "${src}" ]]; then
  echo "OK   no-passphrase-plaintext"
else
  echo "FAIL no-passphrase: got=${out}"
  fail=1
fi

# passphrase + openssl fail → rc≠0, bez zwracania src jako „sukces”
BACKUP_ENCRYPT_PASSPHRASE="test-secret-$$"
export BACKUP_ENCRYPT_PASSPHRASE
openssl() { return 1; }
hm_have_cmd() { [[ "$1" == openssl ]] && return 0; return 1; }
if out="$(hm_backup_maybe_encrypt_file "${src}" 2>/dev/null)"; then
  echo "FAIL openssl-fail-should-abort: out=${out}"
  fail=1
else
  if [[ -n "${out}" && "${out}" == "${src}" ]]; then
    echo "FAIL openssl-fail-returned-plaintext-path"
    fail=1
  else
    echo "OK   openssl-fail-closed"
  fi
fi
[[ -f "${src}.enc" ]] && { echo "FAIL leftover-enc"; fail=1; } || echo "OK   no-leftover-enc"

# brak openssl przy ustawionym passphrase → abort
hm_have_cmd() { return 1; }
if hm_backup_maybe_encrypt_file "${src}" >/dev/null 2>&1; then
  echo "FAIL missing-openssl-should-abort"
  fail=1
else
  echo "OK   missing-openssl-fail-closed"
fi

# prawdziwy openssl (jeśli dostępny) + export → .enc
unset -f openssl 2>/dev/null || true
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }
if command -v openssl >/dev/null 2>&1; then
  # zmienna tylko w shellu, bez prior export w subshell — helper robi export
  BACKUP_ENCRYPT_PASSPHRASE="roundtrip-$$"
  # nie exportuj ręcznie — sprawdź że helper eksportuje
  out="$(hm_backup_maybe_encrypt_file "${src}")" || {
    echo "FAIL real-openssl-encrypt"
    fail=1
    out=""
  }
  if [[ "${out}" == *.enc && -f "${out}" ]]; then
    echo "OK   real-openssl-enc"
    dec="${base}/dec.txt"
    export BACKUP_ENCRYPT_PASSPHRASE
    if openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENCRYPT_PASSPHRASE -in "${out}" -out "${dec}" 2>/dev/null \
      && [[ "$(cat "${dec}")" == "payload" ]]; then
      echo "OK   real-openssl-roundtrip"
    else
      echo "FAIL real-openssl-roundtrip"
      fail=1
    fi
  elif [[ -n "${out}" ]]; then
    echo "FAIL real-openssl-enc: out=${out}"
    fail=1
  fi
else
  echo "OK   real-openssl-skip"
fi

# tar excludes: privkey1.pem + ssh_host_rsa_key
tree="${base}/etc"
mkdir -p "${tree}/letsencrypt/archive/d" "${tree}/ssh"
mkdir -p "${tree}/letsencrypt/live/d"
echo CERT > "${tree}/letsencrypt/archive/d/cert1.pem"
echo PRIV > "${tree}/letsencrypt/archive/d/privkey1.pem"
echo LIVE > "${tree}/letsencrypt/live/d/privkey.pem"
echo HOST > "${tree}/ssh/ssh_host_rsa_key"
echo PUB > "${tree}/ssh/ssh_host_rsa_key.pub"
echo CFG > "${tree}/ssh/sshd_config"
tgz="${base}/sys.tgz"
tar --warning=no-file-changed --ignore-failed-read -czf "${tgz}" \
  --exclude='privkey.pem' --exclude='privkey.*.pem' --exclude='privkey*.pem' \
  --exclude='*/privkey*.pem' --exclude='*.key' \
  --exclude='ssh_host_*_key' --exclude='*/ssh_host_*_key' \
  -C "${base}" etc
list="$(tar -tzf "${tgz}")"
ok_ex=1
printf '%s\n' "${list}" | grep -q 'privkey1.pem' && { echo "FAIL exclude-privkey1"; ok_ex=0; fail=1; }
printf '%s\n' "${list}" | grep -q 'privkey.pem' && { echo "FAIL exclude-privkey"; ok_ex=0; fail=1; }
printf '%s\n' "${list}" | grep -Eq 'ssh_host_rsa_key$' && { echo "FAIL exclude-ssh-host"; ok_ex=0; fail=1; }
printf '%s\n' "${list}" | grep -q 'cert1.pem' || { echo "FAIL keep-cert"; ok_ex=0; fail=1; }
printf '%s\n' "${list}" | grep -q 'sshd_config' || { echo "FAIL keep-sshd"; ok_ex=0; fail=1; }
printf '%s\n' "${list}" | grep -q 'ssh_host_rsa_key.pub' || { echo "FAIL keep-host-pub"; ok_ex=0; fail=1; }
[[ "${ok_ex}" -eq 1 ]] && echo "OK   tar-excludes-privkey-sshhost"

# restore: .enc bez passphrase → twardy stop (rc≠0), zanim cokolwiek się zmieni
# shellcheck disable=SC1091
source commands/backup/restore.sh
unset BACKUP_ENCRYPT_PASSPHRASE || true
rclone() {
  case "$*" in
    *"unix-account.meta.enc"*) return 0 ;;
    *lsf*) printf 'unix-account.meta.enc\n'; return 0 ;;
    *) return 1 ;;
  esac
}
hm_err() { printf 'ERR:%s\n' "$*" >&2; }
if hm_backup_abort_if_enc_without_passphrase "remote/sites/x/stamp" 2>/dev/null; then
  echo "FAIL enc-without-passphrase-should-abort"
  fail=1
else
  echo "OK   enc-without-passphrase-abort"
fi
BACKUP_ENCRYPT_PASSPHRASE="x"
export BACKUP_ENCRYPT_PASSPHRASE
if hm_backup_abort_if_enc_without_passphrase "remote/sites/x/stamp" 2>/dev/null; then
  echo "OK   enc-with-passphrase-ok"
else
  echo "FAIL enc-with-passphrase-should-pass"
  fail=1
fi
unset BACKUP_ENCRYPT_PASSPHRASE || true

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "ALL OK"
exit 0
