#!/bin/bash
set -e

debug=${debug:-""}
if [[ -n "$debug" ]]; then
  set -x
fi

lib_dir="$(dirname "${BASH_SOURCE[0]}")"

###
#
# messaging functions
#
###

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
no_color='\033[0m'

error() {
  printf "\n%b%s%b\n\n" "$red" "$*" "$no_color" 1>&2 && exit 1
}

warning() {
  printf "%b%s%b" "$yellow" "$*" "$no_color"
}

msg() {
  printf "%b%s%b" "$green" "$*" "$no_color"
}

timestamp_msg() {
  echo "[$(date -u +%FT%TZ)] $(msg "$*")"
}

convert_secs_to_hms() {
  ((h=$1/3600))
  ((m=($1%3600)/60))
  ((s=$1%60))
  printf "%02d:%02d:%02d" $h $m $s
}

seconds_since() {
  echo "$(( $(date +%s) - $1 ))"
}

###
#
# utility functions
#
###

is_dark_mode() {
  [[ "$(defaults read -g AppleInterfaceStyle 2> /dev/null)" == "Dark" ]]
}

started_without_args() {
  [[ ${#BASH_ARGV[@]} -eq 0 ]]
}

get_host() {
  [[ -f "$lib_dir/../docker-compose.yml" ]] &&
    perl -ne 's/.*VIRTUAL_HOST=\s*(.*)\s*/\1/ and print' "$lib_dir/../docker-compose.yml"
}

export_compose_project_name() {
  [[ -f "$lib_dir/../docker-compose.yml" ]] &&
    export COMPOSE_PROJECT_NAME
    COMPOSE_PROJECT_NAME=$(perl -ne 's/.*VIRTUAL_HOST=([^.]*).*/\1/ and print' "$lib_dir/../docker-compose.yml")
}

###
#
# update  functions
#
###

app_branch_to_check="develop" # when debugging
app_branch_to_check="master" # real branch
app_repo="https://raw.githubusercontent.com/PMET-public/magento-cloud-docker/$app_branch_to_check/dist/bin"
app_files=(lib.sh manage-dockerized-cloud-env.sh dockerize-cloud-env.sh)
update_dir="$lib_dir/.update"

download_latest_update() {
  mkdir -p "$update_dir"
  cd "$update_dir"
  touch .downloading # simple flag to prevent race condition when downloads may be ongoing
  curl_list="$(IFS=,; echo "${app_files[*]}")"
  curl -v -O "$app_repo/{$curl_list}" 2>&1 |
    grep '< HTTP/1.1 ' |
    grep -q -v 200 && { 
      rm "${app_files[@]}" || : # delete downloaded files unless all return HTTP 200 response
    }
  rm .downloading
}

is_update_available() {
  [[ -f "$update_dir/.downloading" ]] && return # still downloading? update not available
  [[ $(find "$update_dir" -type f 2> /dev/null | wc -l) -eq 0 ]] && {
    # must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
    download_latest_update > /dev/null 2>&1 &
    false; return
  }
  for i in "${app_files[@]}"; do
    diff "$update_dir/$i" "$lib_dir/$i" > /dev/null || return 0 # found a diff? update available
  done
  # must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
  download_latest_update > /dev/null 2>&1 &
  false
}

update_from_local_dir() {
  cd "$update_dir" && mv ./* "$lib_dir)/"
}
