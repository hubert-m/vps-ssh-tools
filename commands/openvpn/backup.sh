#!/usr/bin/env bash
# Archiwum OpenVPN: tar.gz, manifest SHA-256, szyfrowanie jak w backup.

hm_ovpn_backup_entry() {
  case "${1:-}" in
    ""|list|--*) hm_ovpn_backup_cmd "$@" ;;
    *) hm_ovpn_backup "$@" ;;
  esac
}

hm_ovpn_restore_entry() {
  local a path=""
  for a in "$@"; do
    case "${a}" in
      --yes|-y|--plain) ;;
      --endpoint|--target) ;;
      --endpoint=*|--target=*) ;;
      *) path="${a}" ;;
    esac
  done
  if [[ -n "${path}" && -d "${path}" ]]; then
    hm_ovpn_restore "$@"
  else
    hm_ovpn_restore_archive "$@"
  fi
}

hm_ovpn_backup_local_dir() {
  printf '%s/openvpn' "${BACKUP_LOCAL_ROOT:-/backup/hmtools}"
}

hm_ovpn_sha256() {
  local file="$1" sum=""
  [[ -f "${file}" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum -- "${file}" 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    sum="$(openssl dgst -sha256 "${file}" 2>/dev/null | awk '{print $NF}')"
  else
    return 1
  fi
  sum="${sum#\\}"
  [[ -n "${sum}" ]] || return 1
  printf '%s' "${sum}"
}

hm_ovpn_copy_tree() {
  local src="$1" dest="$2"
  [[ -d "${src}" ]] || return 0
  mkdir -p "${dest}"
  cp -a "${src}/." "${dest}/" 2>/dev/null || cp -R "${src}/." "${dest}/"
}

hm_ovpn_backup_stage() {
  local stage="$1" etc pki clients rel file sum
  etc="$(hm_ovpn_etc)"
  pki="$(hm_ovpn_pki)"
  clients="$(hm_ovpn_export_dir)"
  mkdir -p "${stage}/server" "${stage}/clients"
  hm_ovpn_copy_tree "${etc}" "${stage}/server"
  if [[ -d "${pki}" && "${pki}" != "${etc}" && "${pki}" != "${etc}/"* ]]; then
    hm_ovpn_copy_tree "${pki}" "${stage}/server/pki"
  fi
  hm_ovpn_copy_tree "${clients}" "${stage}/clients"
  {
    printf 'version=1\n'
    printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -f "${HMTOOLS_ROOT:-}/VERSION" ]]; then
      printf 'hmtools=%s\n' "$(tr -d '[:space:]' < "${HMTOOLS_ROOT}/VERSION")"
    fi
    while IFS= read -r file; do
      [[ -n "${file}" ]] || continue
      rel="${file#"${stage}/"}"
      case "${rel}" in
        *..*) hm_err "Zła ścieżka w kopii."; return 1 ;;
      esac
      sum="$(hm_ovpn_sha256 "${file}")" || { hm_err "Brak SHA-256 dla ${rel}."; return 1; }
      printf 'sha256 %s %s\n' "${sum}" "${rel}"
    done < <(find "${stage}" -type f ! -name manifest.txt | sort)
  } > "${stage}/manifest.txt"
}

hm_ovpn_encrypt_for_remote() {
  local src="$1" root
  if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
    printf '%s\n' "${src}"
    return 0
  fi
  if ! declare -F hm_backup_maybe_encrypt_file >/dev/null 2>&1; then
    root="${HMTOOLS_ROOT:-}"
    [[ -n "${root}" && -f "${root}/commands/backup/core.sh" ]] || return 1
    # shellcheck disable=SC1091
    source "${root}/commands/backup/core.sh"
  fi
  hm_backup_maybe_encrypt_file "${src}"
}

hm_ovpn_backup_prune() {
  local dir="$1" keep="$2" i=0 f
  [[ "${keep}" =~ ^[0-9]+$ && "${keep}" -gt 0 ]] || return 0
  shopt -s nullglob
  local -a files=( "${dir}"/openvpn-*.tar.gz "${dir}"/openvpn-*.tar.gz.enc )
  shopt -u nullglob
  [[ "${#files[@]}" -gt 0 ]] || return 0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    i=$((i + 1))
    if [[ "${i}" -gt "${keep}" ]]; then
      rm -f "${f}"
    fi
  done < <(ls -1t "${files[@]}")
}

hm_ovpn_backup_list() {
  local target="${1:-}" dir f
  dir="$(hm_ovpn_backup_local_dir)"
  if [[ -n "${target}" && -d "${HM_OVPN_REMOTE_DIR:-}" ]]; then
    dir="${HM_OVPN_REMOTE_DIR}"
  fi
  [[ -d "${dir}" ]] || { hm_info "Brak kopii OpenVPN."; return 0; }
  shopt -s nullglob
  local -a files=( "${dir}"/openvpn-*.tar.gz "${dir}"/openvpn-*.tar.gz.enc )
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    hm_info "Brak kopii OpenVPN."
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "${f}" ]] && printf '%s\n' "$(basename "${f}")"
  done < <(ls -1t "${files[@]}")
}

hm_ovpn_backup_latest() {
  local dir="$1" f
  [[ -d "${dir}" ]] || return 1
  shopt -s nullglob
  local -a files=( "${dir}"/openvpn-*.tar.gz "${dir}"/openvpn-*.tar.gz.enc )
  shopt -u nullglob
  [[ "${#files[@]}" -gt 0 ]] || return 1
  f="$(ls -1t "${files[@]}" | head -n 1)"
  [[ -n "${f}" ]] || return 1
  printf '%s' "${f}"
}

hm_ovpn_backup_cmd() {
  local target="" keep="" plain=0 do_list=0 stage="" archive="" send="" dir
  if [[ "${1:-}" == "list" ]]; then
    do_list=1
    shift || true
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local) shift ;;
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      --keep) keep="${2:-}"; shift 2 || true ;;
      --keep=*) keep="${1#*=}"; shift ;;
      --plain) plain=1; shift ;;
      *) hm_err "Nieznana flaga: $1"; return 1 ;;
    esac
  done
  if [[ "${do_list}" -eq 1 ]]; then
    hm_ovpn_backup_list "${target}"
    return
  fi
  if [[ -n "${target}" && -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" && "${plain}" -ne 1 ]]; then
    hm_err "Brak szyfrowania. Wysyłka na ${target} zablokowana. Ustaw BACKUP_ENCRYPT_PASSPHRASE albo --plain."
    return 1
  fi
  if [[ -n "${target}" && -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" && "${plain}" -eq 1 ]]; then
    if ! declare -F hm_confirm_plan_critical >/dev/null 2>&1; then
      hm_err "Kopia bez szyfrowania wymaga potwierdzenia OPENVPN."
      return 1
    fi
    hm_confirm_plan_critical "OPENVPN" "openvpn backup --plain" "Kopia PKI pójdzie bez szyfrowania." \
      "wysyłka plaintext na ${target}" || return 1
  fi
  dir="$(hm_ovpn_backup_local_dir)"
  mkdir -p "${dir}"
  stage="$(mktemp -d)"
  archive="${dir}/openvpn-$(date -u +%Y%m%d-%H%M%S).tar.gz"
  hm_ovpn_backup_stage "${stage}" || { rm -rf "${stage}"; return 1; }
  tar -czf "${archive}" -C "${stage}" server clients manifest.txt || { rm -rf "${stage}"; rm -f "${archive}"; return 1; }
  rm -rf "${stage}"
  chmod 0600 "${archive}" 2>/dev/null || true
  if [[ -n "${target}" ]]; then
    send="$(hm_ovpn_encrypt_for_remote "${archive}")" || { rm -f "${archive}.enc"; return 1; }
    if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
      :
    elif [[ "${send}" != *.enc ]]; then
      hm_err "Szyfrowanie nie zwróciło pliku .enc. Wysyłka wstrzymana."
      return 1
    fi
    if [[ -n "${HM_OVPN_REMOTE_DIR:-}" ]]; then
      mkdir -p "${HM_OVPN_REMOTE_DIR}"
      cp -f "${send}" "${HM_OVPN_REMOTE_DIR}/$(basename "${send}")"
    elif declare -F hm_rclone_copyto >/dev/null 2>&1; then
      hm_rclone_copyto "${send}" "${target}/$(basename "${send}")" || return 1
    else
      hm_err "Brak celu zdalnego dla ${target}."
      return 1
    fi
  fi
  [[ -n "${keep}" ]] && hm_ovpn_backup_prune "${dir}" "${keep}"
  hm_ok "Kopia OpenVPN: ${archive}"
}

hm_ovpn_backup_for_full() {
  local remote="${1:-}" inc="${BACKUP_INCLUDE_OPENVPN:-auto}" before after archive
  if [[ "${inc}" == "0" ]]; then
    return 0
  fi
  if [[ "${inc}" != "1" ]] && ! hm_ovpn_installed; then
    return 0
  fi
  before="$(hm_ovpn_backup_local_dir)"
  hm_ovpn_backup_cmd --local || return 1
  archive="$(hm_ovpn_backup_latest "${before}" || true)"
  [[ -n "${archive}" && -f "${archive}" ]] || return 0
  if [[ -n "${remote}" && -d "${remote}" ]]; then
    cp -f "${archive}" "${remote}/"
  elif [[ -n "${remote}" ]] && declare -F hm_rclone_copyto >/dev/null 2>&1; then
    hm_rclone_copyto "${archive}" "${remote}/$(basename "${archive}")" || hm_warn "Upload kopii OpenVPN nieudany."
  fi
  after="${archive}"
  [[ -n "${after}" ]]
}

hm_ovpn_snapshot_save() {
  local dest="$1"
  mkdir -p "${dest}/etc" "${dest}/pki" "${dest}/clients"
  hm_ovpn_copy_tree "$(hm_ovpn_etc)" "${dest}/etc"
  hm_ovpn_copy_tree "$(hm_ovpn_pki)" "${dest}/pki"
  if [[ -d "$(hm_ovpn_export_dir)" ]]; then
    hm_ovpn_copy_tree "$(hm_ovpn_export_dir)" "${dest}/clients"
  fi
}

# Zaufane ścieżki rollbacku — NIGDY z przywróconego hmtools.state (PKI=).
# HM_OVPN_PKI / HM_OVPN_ETC z env (testy) są jawne i dozwolone.
hm_ovpn_trusted_paths() {
  local etc pki clients
  etc="$(hm_ovpn_etc)"
  if [[ -n "${HM_OVPN_PKI:-}" ]]; then
    pki="${HM_OVPN_PKI}"
  else
    pki="${etc}/hm/pki"
    case "${pki}" in
      "${etc}"/*|"${HM_OVPN_ROOT:-/etc/openvpn}"/*) ;;
      *) hm_err "Odmowa PKI poza allowlistą OpenVPN (${pki})."; return 1 ;;
    esac
  fi
  clients="$(hm_ovpn_export_dir)"
  if [[ -z "${HM_OVPN_ETC:-}" ]]; then
    case "${etc}" in
      /etc/openvpn/*|"${HM_OVPN_ROOT:-/etc/openvpn}"/*) ;;
      *) hm_err "Odmowa etc poza /etc/openvpn."; return 1 ;;
    esac
  fi
  printf '%s\t%s\t%s\n' "${etc}" "${pki}" "${clients}"
}

hm_ovpn_tree_has_symlinks() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
  if find "${dir}" \( -type l -o -type b -o -type c \) 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

hm_ovpn_safe_copy_tree() {
  local src="$1" dest="$2" f rel tmp
  [[ -d "${src}" ]] || return 0
  if hm_ovpn_tree_has_symlinks "${src}"; then
    hm_err "Odmowa: drzewo zawiera symlinki/urządzenia."
    return 1
  fi
  mkdir -p "${dest}"
  while IFS= read -r -d '' f; do
    rel="${f#"${src}/"}"
    case "${rel}" in
      *..*) hm_err "Zła ścieżka w kopii: ${rel}"; return 1 ;;
    esac
    mkdir -p "${dest}/$(dirname "${rel}")"
    tmp="$(mktemp "${dest}/${rel}.XXXXXX")"
    cp -f "${f}" "${tmp}"
    mv -f "${tmp}" "${dest}/${rel}"
  done < <(find "${src}" -type f -print0 2>/dev/null)
}

hm_ovpn_snapshot_load() {
  local src="$1" etc pki clients paths
  paths="$(hm_ovpn_trusted_paths)" || return 1
  IFS=$'\t' read -r etc pki clients <<< "${paths}"
  # kasuj tylko zaufane ścieżki (nie PKI= z archiwum)
  rm -rf "${etc}"
  mkdir -p "${etc}"
  case "${pki}" in
    "${etc}"/*)
      # pki pod etc — już skasowane z etc
      mkdir -p "${pki}"
      ;;
    *)
      rm -rf "${pki}"
      mkdir -p "${pki}"
      ;;
  esac
  hm_ovpn_safe_copy_tree "${src}/etc" "${etc}" || return 1
  hm_ovpn_safe_copy_tree "${src}/pki" "${pki}" || return 1
  if [[ -d "${src}/clients" ]]; then
    case "${clients}" in
      */hmtools-openvpn/clients|*/hmtools-openvpn/clients/|"${HM_OVPN_EXPORT:-}"*)
        rm -rf "${clients}"
        mkdir -p "${clients}"
        hm_ovpn_safe_copy_tree "${src}/clients" "${clients}" || return 1
        ;;
    esac
  fi
}

hm_ovpn_restore_verify() {
  local dir="$1" kind sum rel got
  [[ -f "${dir}/manifest.txt" ]] || { hm_err "Brak manifestu w kopii."; return 1; }
  while read -r kind sum rel; do
    [[ "${kind}" == "sha256" ]] || continue
    case "${rel}" in
      *..*|/*) hm_err "Zła ścieżka w manifeście."; return 1 ;;
    esac
    [[ -f "${dir}/${rel}" ]] || { hm_err "Brak pliku w kopii: ${rel}"; return 1; }
    got="$(hm_ovpn_sha256 "${dir}/${rel}")" || return 1
    if [[ "${got}" != "${sum}" ]]; then
      hm_err "Zła suma SHA-256: ${rel}"
      return 1
    fi
  done < "${dir}/manifest.txt"
}

hm_ovpn_restore_modes() {
  local etc pki path
  etc="$(hm_ovpn_etc)"
  pki="$(hm_ovpn_pki)"
  [[ -d "${pki}/private" ]] && chmod 0700 "${pki}/private" 2>/dev/null || true
  [[ -d "${etc}/pki/private" ]] && chmod 0700 "${etc}/pki/private" 2>/dev/null || true
  for path in "${pki}/private/"*.key "${etc}/pki/private/"*.key "${etc}/tls-crypt.key"; do
    [[ -f "${path}" ]] && chmod 0600 "${path}" 2>/dev/null || true
  done
  [[ -f "${etc}/crl.pem" ]] && chmod 0644 "${etc}/crl.pem" 2>/dev/null || true
}

hm_ovpn_restore_render() {
  # Zachowaj przywrócony hm.conf (DNS, routes, client-to-client).
  # Re-render tylko gdy conf brakuje.
  local conf
  conf="$(hm_ovpn_conf_file)"
  if [[ -f "${conf}" && -s "${conf}" ]]; then
    return 0
  fi
  local port proto cidr dns group ver
  port="$(hm_ovpn_state_value PORT 2>/dev/null || true)"
  proto="$(hm_ovpn_state_value PROTO 2>/dev/null || true)"
  cidr="$(hm_ovpn_state_value SUBNET 2>/dev/null || true)"
  [[ -n "${port}" && -n "${proto}" && -n "${cidr}" ]] || return 0
  dns="$(hm_ovpn_state_value DNS 2>/dev/null || true)"
  [[ -n "${dns}" ]] || dns="quad9"
  group="$(hm_ovpn_group_name)"
  ver="${HM_OVPN_VERSION:-2.6.0}"
  hm_ovpn_render_conf "$(hm_ovpn_etc)" "${port}" "${proto}" "${cidr}" "${group}" "${ver}" "$(hm_ovpn_dns_ips "${dns}")" > "${conf}"
}

# Scal revoke: R z żywej kopii zostaje R po restore starszego archiwum.
hm_ovpn_merge_revokes() {
  local live_index="$1" dest_index="$2" line cn serial status
  [[ -f "${live_index}" && -f "${dest_index}" ]] || return 0
  local tmp changed=0
  tmp="$(mktemp)"
  cp -f "${dest_index}" "${tmp}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == R* ]] || continue
    cn="${line#*/CN=}"
    cn="${cn%%/*}"
    [[ -n "${cn}" ]] || continue
    if grep -qE "^V[[:space:]].*/CN=${cn}(/|[[:space:]]|$)" "${tmp}"; then
      awk -v cn="${cn}" '
        $1=="V" && $0 ~ ("/CN=" cn) {
          sub(/^V/, "R")
          print
          next
        }
        { print }
      ' "${tmp}" > "${tmp}.2" && mv -f "${tmp}.2" "${tmp}"
      changed=1
      hm_warn "Restore: zachowuję revoke klienta ${cn} (R z bieżącego stanu)."
    fi
  done < "${live_index}"
  if [[ "${changed}" -eq 1 ]]; then
    mv -f "${tmp}" "${dest_index}"
    if declare -F hm_ovpn_crl_update >/dev/null 2>&1; then
      hm_ovpn_crl_update >/dev/null 2>&1 || true
    elif declare -F hm_ovpn_easyrsa >/dev/null 2>&1; then
      hm_ovpn_easyrsa gen-crl >/dev/null 2>&1 || true
    fi
  else
    rm -f "${tmp}"
  fi
}

hm_ovpn_retarget() {
  local endpoint="$1" file tmp
  [[ "${endpoint}" =~ ^[A-Za-z0-9.:_-]+$ ]] || { hm_err "Zły endpoint."; return 1; }
  if [[ -f "$(hm_ovpn_state_file)" ]]; then
    tmp="$(mktemp)"
    grep -v '^ENDPOINT=' "$(hm_ovpn_state_file)" > "${tmp}" || true
    printf 'ENDPOINT=%s\n' "${endpoint}" >> "${tmp}"
    mv -f "${tmp}" "$(hm_ovpn_state_file)"
  fi
  if [[ -s "$(hm_ovpn_tls_key_path)" && -f "$(hm_ovpn_pki)/index.txt" ]]; then
    hm_ovpn_client_export --all || hm_warn "Eksport profili pominięty. Zmieniam tylko linię remote."
  fi
  shopt -s nullglob
  for file in "$(hm_ovpn_export_dir)/"*.ovpn; do
    tmp="$(mktemp)"
    awk -v ep="${endpoint}" '
      $1 == "remote" { print "remote " ep " " $3; next }
      { print }
    ' "${file}" > "${tmp}"
    mv -f "${tmp}" "${file}"
  done
  shopt -u nullglob
}

hm_ovpn_restore_archive() {
  local yes=0 endpoint="" target="" src="" work="" snap="" pkg
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --endpoint) endpoint="${2:-}"; shift 2 || true ;;
      --endpoint=*) endpoint="${1#*=}"; shift ;;
      --target) target="${2:-}"; shift 2 || true ;;
      --target=*) target="${1#*=}"; shift ;;
      latest) src="latest"; shift ;;
      *) src="$1"; shift ;;
    esac
  done
  if [[ "${src}" == "latest" || -z "${src}" ]]; then
    if [[ -n "${target}" && -d "${HM_OVPN_REMOTE_DIR:-}" ]]; then
      src="$(hm_ovpn_backup_latest "${HM_OVPN_REMOTE_DIR}")" || { hm_err "Brak kopii na celu."; return 1; }
    else
      src="$(hm_ovpn_backup_latest "$(hm_ovpn_backup_local_dir)")" || { hm_err "Brak lokalnej kopii."; return 1; }
    fi
  fi
  [[ -f "${src}" ]] || { hm_err "Brak pliku kopii."; return 1; }
  work="$(mktemp -d)"
  if [[ "${src}" == *.enc ]]; then
    if [[ -z "${BACKUP_ENCRYPT_PASSPHRASE:-}" ]]; then
      rm -rf "${work}"
      hm_err "Kopia zaszyfrowana. Ustaw BACKUP_ENCRYPT_PASSPHRASE. Nic nie zmieniono."
      return 1
    fi
    export BACKUP_ENCRYPT_PASSPHRASE
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_ENCRYPT_PASSPHRASE \
      -in "${src}" -out "${work}/archive.tar.gz" 2>/dev/null; then
      rm -rf "${work}"
      hm_err "Deszyfracja nieudana. Nic nie zmieniono."
      return 1
    fi
    src="${work}/archive.tar.gz"
  fi
  mkdir -p "${work}/tree"
  # bez --same-owner; potem odrzuć symlinki
  if ! tar --no-same-owner -xzf "${src}" -C "${work}/tree" 2>/dev/null; then
    rm -rf "${work}"
    hm_err "Uszkodzone archiwum. Nic nie zmieniono."
    return 1
  fi
  if hm_ovpn_tree_has_symlinks "${work}/tree"; then
    rm -rf "${work}"
    hm_err "Archiwum zawiera symlinki/urządzenia. Odrzucone. Nic nie zmieniono."
    return 1
  fi
  if ! hm_ovpn_restore_verify "${work}/tree"; then
    rm -rf "${work}"
    return 1
  fi
  if [[ "${yes}" -eq 1 ]]; then
    hm_confirm_plan "openvpn restore" "Nadpisanie konfiguracji OpenVPN." --yes "weryfikacja" "kopia bieżącego stanu" "rozpakowanie" || { rm -rf "${work}"; return 1; }
  else
    hm_confirm_plan "openvpn restore" "Nadpisanie konfiguracji OpenVPN." "weryfikacja" "kopia bieżącego stanu" "rozpakowanie" || { rm -rf "${work}"; return 1; }
  fi
  if ! command -v openvpn >/dev/null 2>&1 && declare -F hm_ovpn_packages >/dev/null 2>&1; then
    while IFS= read -r pkg; do
      [[ -n "${pkg}" ]] || continue
      if declare -F hm_pkg_install >/dev/null 2>&1; then
        hm_pkg_install "${pkg}" || { rm -rf "${work}"; return 1; }
      fi
    done < <(hm_ovpn_packages)
  fi
  local paths etc_t pki_t clients_t live_index=""
  paths="$(hm_ovpn_trusted_paths)" || { rm -rf "${work}"; return 1; }
  IFS=$'\t' read -r etc_t pki_t clients_t <<< "${paths}"
  snap="$(mktemp -d)"
  hm_ovpn_snapshot_save "${snap}"
  [[ -f "${pki_t}/index.txt" ]] && live_index="${snap}/pki/index.txt"
  hm_ovpn_systemctl disable --now "openvpn-server@$(hm_ovpn_instance)" >/dev/null 2>&1 || true
  # Ignoruj PKI= z archiwum — zawsze zaufane ścieżki
  if [[ -d "${work}/tree/server" ]]; then
    mkdir -p "${etc_t}"
    hm_ovpn_safe_copy_tree "${work}/tree/server" "${etc_t}" || {
      hm_ovpn_snapshot_load "${snap}"
      rm -rf "${work}" "${snap}"
      return 1
    }
  fi
  if [[ -d "${work}/tree/server/pki" ]]; then
    mkdir -p "${pki_t}"
    hm_ovpn_safe_copy_tree "${work}/tree/server/pki" "${pki_t}" || {
      hm_ovpn_snapshot_load "${snap}"
      rm -rf "${work}" "${snap}"
      return 1
    }
  fi
  if [[ -d "${work}/tree/clients" ]]; then
    mkdir -p "${clients_t}"
    hm_ovpn_safe_copy_tree "${work}/tree/clients" "${clients_t}" || {
      hm_ovpn_snapshot_load "${snap}"
      rm -rf "${work}" "${snap}"
      return 1
    }
  fi
  # wymuś zaufane PKI= w stanie (nie z archiwum)
  if [[ -f "$(hm_ovpn_state_file)" ]]; then
    local stmp
    stmp="$(mktemp)"
    grep -v '^PKI=' "$(hm_ovpn_state_file)" > "${stmp}" || true
    printf 'PKI=%s\n' "${pki_t}" >> "${stmp}"
    mv -f "${stmp}" "$(hm_ovpn_state_file)"
  fi
  if [[ -n "${live_index}" && -f "${live_index}" ]]; then
    hm_ovpn_merge_revokes "${live_index}" "${pki_t}/index.txt"
  fi
  hm_ovpn_restore_modes
  if ! hm_ovpn_restore_render; then
    hm_ovpn_snapshot_load "${snap}"
    rm -rf "${work}" "${snap}"
    hm_err "Nie udało się złożyć konfiguracji. Przywrócono poprzedni stan."
    return 1
  fi
  if [[ -n "${endpoint}" ]]; then
    if ! hm_ovpn_retarget "${endpoint}"; then
      hm_ovpn_snapshot_load "${snap}"
      rm -rf "${work}" "${snap}"
      return 1
    fi
  fi
  if ! hm_ovpn_systemctl enable --now "openvpn-server@$(hm_ovpn_instance)"; then
    hm_ovpn_snapshot_load "${snap}"
    rm -rf "${work}" "${snap}"
    hm_err "Start nieudany. Przywrócono poprzedni stan."
    return 1
  fi
  rm -rf "${work}" "${snap}"
  hm_ok "Przywrócono OpenVPN."
}
