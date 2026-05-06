#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-d dir]

Install or update the Royal Road KOReader plugin (macOS and Linux).

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-d, --dir       KOReader directory
                  macOS default: ~/Library/Application Support/koreader
                  Linux default: ~/.config/koreader
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

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -d | --dir)
      koreader_dir="${2-}"
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

plugin_dir="${koreader_dir}/plugins"

msg "Installing Royal Road plugin to KOReader..."

mkdir -p "${plugin_dir}"
cp -rv "${script_dir}/royalroad.koplugin" "${plugin_dir}/"

msg ""
msg "${GREEN}Plugin installed successfully!${NOFORMAT}"
msg ""
msg "Location: ${plugin_dir}/"
msg ""
msg "To view logs in real-time:"
msg "  tail -f \"${koreader_dir}/crash.log\""
msg ""
msg "Restart KOReader to load the updated plugin."
