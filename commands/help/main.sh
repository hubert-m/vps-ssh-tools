#!/usr/bin/env bash
# Moduł: help (implementacja hm_cmd_help w lib/help.sh)

cmd_help() {
  hm_cmd_help "$@"
}

_hm_cmd_register help cmd_help 1 h '?'
