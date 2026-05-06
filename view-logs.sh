#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-d dir] [-n lines]

View KOReader Royal Road plugin logs in real-time (macOS and Linux).

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-d, --dir       KOReader directory
                  macOS default: ~/Library/Application Support/koreader
                  Linux default: ~/.config/koreader
-n, --lines     Number of historical lines to show (default: 50)
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' GREEN='\033[0;32m' RED='\033[0;31m'
  else
    NOFORMAT='' GREEN='' RED=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg="${1}"
  local code="${2-1}"
  msg "${RED}Error: ${msg}${NOFORMAT}"
  exit "${code}"
}

parse_params() {
  if [[ "${OSTYPE}" == "darwin"* ]]; then
    koreader_dir="${HOME}/Library/Application Support/koreader"
  else
    koreader_dir="${HOME}/.config/koreader"
  fi
  lines=50

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -d | --dir)
      koreader_dir="${2-}"
      shift
      ;;
    -n | --lines)
      lines="${2-}"
      shift
      ;;
    -?*) die "Unknown option: ${1}" ;;
    *) break ;;
    esac
    shift
  done

  return 0
}

parse_params "$@"
setup_colors

log_file="${koreader_dir}/crash.log"

[[ -f "${log_file}" ]] || die "Log file not found: ${log_file}\nKOReader may not have been run yet."

msg "${GREEN}Showing KOReader logs (Ctrl+C to exit):${NOFORMAT}"
msg "=========================================="
msg ""

tail -n "${lines}" -f "${log_file}" | grep --line-buffered -E "(Royal Road)"
