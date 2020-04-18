#!/bin/bash

# TODO 
# - this managing app should probably be moved to it's own project despite being tightly coupled to magento-cloud-docker
# - updating: would be better to look for specific released tags rather than just latest in a branch
# - updating: currently brittle b/c naming files instead of replacing with package (zipped release)

# stop on various errors
set -e

debug=${debug:-""}
if [[ ! -z "$debug" ]]; then
  set -x
fi

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
  printf "\n${red}${*}${no_color}\n\n" 1>&2 && exit 1
}

warning() {
  printf "\n${yellow}${*}${no_color}\n\n"
}

msg() {
  printf "\n${green}${*}${no_color}\n\n"
}

###
#
# utility functions
#
###

is_dark_mode() {
  [[ "$(defaults read -g AppleInterfaceStyle 2> /dev/null)" == "Dark" ]] && return
}

started_without_args() {
  [[ ${#BASH_ARGV[@]} -eq 0 ]]
  return $?
}

export_compose_project_name() {
  [[ -f "$lib_dir/../docker-compose.yml" ]] &&
    export COMPOSE_PROJECT_NAME
    COMPOSE_PROJECT_NAME=$(perl -ne 's/.*VIRTUAL_HOST=([^.]*).*/\1/ and print' "$lib_dir/../docker-compose.yml")
}

get_host() {
  [[ -f "$lib_dir/../docker-compose.yml" ]] &&
    perl -ne 's/.*VIRTUAL_HOST=\s*(.*)\s*/\1/ and print' "$lib_dir/../docker-compose.yml"
}

timestamp_msg() {
  echo "[$(date -u +%FT%TZ)] $(msg ${*})"
}

lib_dir="$(echo "$(dirname "$(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")")"
log_file="$(echo "$lib_dir/../../$COMPOSE_PROJECT_NAME.log")"
quit_detection_file="$(echo "$lib_dir/../../.quit_detection_file")"

###
#
# update  functions
#
###

app_repo="https://raw.githubusercontent.com/PMET-public/magento-cloud-docker/develop/dist/bin"
app_files=(lib.sh manage-dockerized-cloud-env.sh dockerize-cloud-env.sh)
update_dir="$lib_dir/.update"

download_latest_update() {
  mkdir -p "$update_dir"
  cd "$update_dir"
  touch .downloading # simple flag to prevent race condition when downloads may be ongoing
  curl_list="$(IFS=,; echo "${app_files[*]}")"
  curl -v -O "$app_repo/{$curl_list}" 2>&1 | grep '< HTTP/1.1 ' | grep -q -v 200 && \
    rm ${app_files[*]} || : # delete downloaded files unless all return HTTP 200 response
  rm .downloading
}

is_update_available() {
  [[ -f "$update_dir/.downloading" ]] && return # still downloading? update not available
  [[ $(ls "$update_dir" 2> /dev/null | wc -l) -eq 0 ]] && {
    # must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
    download_latest_update > /dev/null 2>&1 &
    return 1
  }
  for i in "${app_files[@]}"; do
    diff "$update_dir/$i" "$lib_dir/$i" > /dev/null || return 0 # found a diff? update available
  done
  # must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
  download_latest_update > /dev/null 2>&1 &
  return 1
}

update_from_local_dir() {
  cd "$update_dir" && mv * "$lib_dir)/"
}
