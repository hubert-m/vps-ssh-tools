#!/usr/bin/env bash
# Fałszywe binarki OpenVPN. Zapisują wywołanie do HM_OVPN_CALL_LOG i zwracają HM_OVPN_MOCK_RC.

hm_ovpn_mock_bins() {
  local dir="$1" name log
  log="${HM_OVPN_CALL_LOG:-${dir}/calls.log}"
  mkdir -p "${dir}"
  export HM_OVPN_CALL_LOG="${log}"
  : > "${log}"
  for name in openvpn easyrsa systemctl ss ip iptables nft ufw firewall-cmd fail2ban-client journalctl; do
    cat > "${dir}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s' "${name}" >> "\${HM_OVPN_CALL_LOG}"
printf ' %s\n' "\$*" >> "\${HM_OVPN_CALL_LOG}"
exit "\${HM_OVPN_MOCK_RC:-0}"
EOF
    chmod +x "${dir}/${name}"
  done
}
