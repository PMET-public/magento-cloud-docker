#!/bin/bash

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
  printf "\n${red}${@}${no_color}\n\n" 1>&2 && exit 1
}

warning() {
  printf "\n${yellow}${@}${no_color}\n\n"
}

msg() {
  printf "\n${green}${@}${no_color}\n\n"
}

###
#
# utility functions
#
###

export_compose_project_name() {
  export COMPOSE_PROJECT_NAME=$(perl -ne 's/.*VIRTUAL_HOST=([^.]*).*/\1/ and print' "$(get_lib_dir)/../docker-compose.yml")
}

get_host() {
  perl -ne 's/.*VIRTUAL_HOST=\s*(.*)\s*/\1/ and print' "$(get_lib_dir)/../docker-compose.yml"
}

get_lib_dir() {
  echo "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))"
}

get_log_file() {
  echo "$(get_lib_dir)/../../$COMPOSE_PROJECT_NAME.log"
}

timestamp_msg() {
  echo "[$(date -u +%FT%TZ)] $(msg ${@})"
}

###
#
# update  functions
#
###

app_repo="https://raw.githubusercontent.com/PMET-public/magento-cloud-docker/master/dist/bin"
app_files=(lib.sh manage-dockerized-cloud-env.sh dockerize-cloud-env.sh)
master_dir="$(get_lib_dir)/master"

download_latest_master() {
  mkdir -p "$master_dir"
  cd "$master_dir"
  curl_list="$(IFS=,; echo "${app_files[*]}")"
  curl -v -O "$app_repo/{$curl_list}" 2>&1 | grep '< HTTP/1.1 ' | grep -q -v 200 || \
    rm ${app_files[*]} || : # only keep if all downloads return 200
}
download_latest_master
exit

check_for_updates() {
  for i in "${app_files[@]}"; do
    diff "$master_dir/$i" "$(get_lib_dir)/$i" || return $?
  done
}

update_from_master() {
  mv "$master_dir/*" "$(get_lib_dir)/"
}
