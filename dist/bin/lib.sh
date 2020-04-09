#!/bin/bash

# stop on various errors
set -e

debug=${debug:-""}
if [[ ! -z "$debug" ]]; then
  set -x
fi

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


get_project_name() {
  perl -ne 's/.*VIRTUAL_HOST=([^.]*).*/\1/ and print' "$(get_lib_dir)/../docker-compose.yml"
}

get_host() {
  perl -ne 's/.*VIRTUAL_HOST=\s*(.*)\s*/\1/ and print' "$(get_lib_dir)/../docker-compose.yml"
}

get_lib_dir() {
  echo "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))"
}
