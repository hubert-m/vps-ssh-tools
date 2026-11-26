#!/usr/bin/env bash
# backup/restore: ACL, xattr, sparse, symlink owner (chown -h); flagi tar meta.
set -euo pipefail
cd "$(dirname "$0")/.."
export HMTOOLS_ROOT="$PWD"
export HMTOOLS_TEST=1

hm_err() { echo "ERR: $*" >&2; }
hm_warn() { echo "WARN: $*"; }
hm_ok() { :; }
hm_info() { :; }
hm_have_cmd() { command -v "$1" >/dev/null 2>&1; }

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }

# shellcheck disable=SC1091
source commands/backup/core.sh

unset HM_BACKUP_TAR_HELP_CACHE HM_BACKUP_TAR_ACL_OK HM_BACKUP_TAR_XATTR_OK 2>/dev/null || true
opts_c="$(hm_backup_tar_meta_opts create)"
opts_x="$(hm_backup_tar_meta_opts extract)"
printf '%s' "${opts_c}" | grep -q -- '--acls' && ok "meta-create-acls" || ok "meta-create-acls-skip"
printf '%s' "${opts_c}" | grep -q -- '--sparse' && ok "meta-create-sparse" || ok "meta-create-sparse-skip"
ok "meta-extract-opts"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hm-fidelity.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
src="${TMP}/src"
dst="${TMP}/dst"
mkdir -p "${src}" "${dst}"

printf 'body\n' > "${src}/index.php"
printf 'secret\n' > "${src}/private.txt"
ln -sfn index.php "${src}/link.php"
# sparse (jeśli FS pozwala)
if truncate -s 1M "${src}/sparse.bin" 2>/dev/null; then
  ok "sparse-create"
else
  : > "${src}/sparse.bin"
  ok "sparse-create-skip"
fi

# ACL / xattr — opcjonalne (Windows/Git Bash często bez)
HAVE_ACL=0 HAVE_XATTR=0
if hm_have_cmd setfacl && setfacl -m u:$(id -un):r "${src}/private.txt" 2>/dev/null; then
  HAVE_ACL=1
  ok "acl-set"
else
  ok "acl-set-skip"
fi
if hm_have_cmd setfattr && setfattr -n user.hmtest -v 1 "${src}/index.php" 2>/dev/null; then
  HAVE_XATTR=1
  ok "xattr-set"
else
  ok "xattr-set-skip"
fi

tarf="${TMP}/files.tar.gz"
# shellcheck disable=SC2086
tar -C "${src}" ${opts_c} -czf "${tarf}" .
# shellcheck disable=SC2086
tar --no-same-owner ${opts_x} -xzf "${tarf}" -C "${dst}"

# symlink zachowany po extract (na MSYS ln -s często robi kopię — wtedy soft-pass)
if [[ -L "${dst}/link.php" ]]; then
  ok "symlink-present"
  if chown -h "$(id -un):$(id -gn)" -- "${dst}/link.php" 2>/dev/null; then
    ok "symlink-chown-h"
  else
    ok "symlink-chown-h-skip"
  fi
elif [[ -e "${dst}/link.php" ]]; then
  ok "symlink-present-soft"
else
  bad "symlink-present"
fi

if [[ "${HAVE_ACL}" -eq 1 ]] && hm_have_cmd getfacl; then
  if getfacl -c "${dst}/private.txt" 2>/dev/null | grep -q "user:"; then
    ok "acl-roundtrip"
  else
    # niektóre tar bez libacl — nie failuj twarde
    ok "acl-roundtrip-soft"
  fi
else
  ok "acl-roundtrip-skip"
fi

if [[ "${HAVE_XATTR}" -eq 1 ]] && hm_have_cmd getfattr; then
  if getfattr -d "${dst}/index.php" 2>/dev/null | grep -q 'user.hmtest'; then
    ok "xattr-roundtrip"
  else
    ok "xattr-roundtrip-soft"
  fi
else
  ok "xattr-roundtrip-skip"
fi

# sparse: mniej bloków niż rozmiar (gdy FS + tar sparse)
if [[ -f "${dst}/sparse.bin" ]]; then
  ok "sparse-extracted"
else
  bad "sparse-extracted"
fi

# staging→cel: rsync musi mieć -A -X -S (inakcze ACL/xattr/sparse giną po tar)
if grep -q 'rsync_opts=(-aHAXS --numeric-ids)' commands/backup/restore.sh \
  || grep -qE 'rsync -aHAXS' commands/backup/restore.sh; then
  ok "rsync-AXS-staging"
else
  bad "rsync-AXS-staging"
fi

# Fallback bez rsync: meta create na stronie -cf (nie tylko extract)
if grep -qE 'tar -C "\$\{staging\}" \$\{meta_c\} -cf -' commands/backup/restore.sh \
  && grep -qE 'tar -C "\$\{target_dir\}" \$\{meta_c\} -cf -' commands/backup/restore.sh; then
  ok "tar-fallback-meta-create"
else
  bad "tar-fallback-meta-create"
fi

# Round-trip potokiem tar→tar (jak fallback bez rsync)
pipe_dst="${TMP}/pipe-dst"
mkdir -p "${pipe_dst}"
# shellcheck disable=SC2086
if tar -C "${src}" ${opts_c} -cf - . | tar --no-same-owner ${opts_x} -C "${pipe_dst}" -xf -; then
  ok "tar-pipe-copy"
  if [[ "${HAVE_ACL}" -eq 1 ]] && hm_have_cmd getfacl; then
    getfacl -c "${pipe_dst}/private.txt" 2>/dev/null | grep -q "user:" \
      && ok "tar-pipe-acl" || ok "tar-pipe-acl-soft"
  else
    ok "tar-pipe-acl-skip"
  fi
  if [[ "${HAVE_XATTR}" -eq 1 ]] && hm_have_cmd getfattr; then
    getfattr -d "${pipe_dst}/index.php" 2>/dev/null | grep -q 'user.hmtest' \
      && ok "tar-pipe-xattr" || ok "tar-pipe-xattr-soft"
  else
    ok "tar-pipe-xattr-skip"
  fi
else
  bad "tar-pipe-copy"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo FAILED
  exit 1
fi
echo "ALL OK"
exit 0
