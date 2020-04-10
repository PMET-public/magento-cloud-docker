#!/bin/bash

source "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))/lib.sh"

# the Platypus status menu app will initially run this script with no arguments
# and display each line of STDOUT as an option
# when an option is selected, the option text is passed as an argument to a second run on this script

# cd to app dir containing relevant docker-compose files
cd $(get_lib_dir)/..
export COMPOSE_PROJECT_NAME=$(get_project_name)

has_no_args() {
  [[ ${#BASH_ARGV[@]} -eq 0 ]]
  return $?
}

echo_in_terminal() {
  osascript -e "tell app \"Terminal\"
    if not (exists window 1) then reopen
    activate
    do script \"echo $1\" in window 1
  end tell" 2>&1 >> /tmp/out
}

is_app_installed() {
  [[ ! -z "$app_is_installed" ]] ||
    {
      docker ps -a | grep -q " ${COMPOSE_PROJECT_NAME}_build_1"
      app_is_installed=$?
    }
  return "$app_is_installed"
}

is_app_running() {
  [[ ! -z "$app_is_installed" ]] ||
    {
      docker ps -a | grep -q " ${COMPOSE_PROJECT_NAME}_build_1"
      app_is_installed=$?
    }
  return "$app_is_installed"
}

# menu item functions

install_app() {
  is_app_installed && return
  local menu_item_text="Install & open app in browser"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # create containers but do not start
  docker-compose up --no-start
  # copy db files to db container
  docker cp .docker/mysql/docker-entrypoint-initdb.d ${COMPOSE_PROJECT_NAME}_db_1:/
  # copy over app files to build container
  tar -cf - --exclude .docker --exclude .composer.tar.gz . | docker cp - ${COMPOSE_PROJECT_NAME}_build_1:/app
  tar -zxf .composer.tar.gz | docker cp - ${COMPOSE_PROJECT_NAME}_build_1:/app
  docker cp app/etc ${COMPOSE_PROJECT_NAME}_deploy_1:/app/app/
  tar -zxf media.tar.gz | docker cp - ${COMPOSE_PROJECT_NAME}_build_1:/app || :
  docker-compose up -d db build
  docker-compose run build cloud-build
  docker-compose up -d
  docker-compose run deploy cloud-deploy
  docker-compose run deploy magento-command config:set system/full_page_cache/caching_application 2 --lock-env
  docker-compose run deploy cloud-post-deploy
  open "http://$(get_host)"
  exit
}

open_app() {
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Open app in browser"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  open "http://$(get_host)"
  exit
}

stop_app() {
  ! is_app_installed && return # menu item n/a if not installed
  ! is_app_running && return # menu item n/a if not running
  local menu_item_text="Stop app"
  has_no_args && echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

resume_app() {
  ! is_app_installed && return # menu item n/a if not installed
  is_app_running && return # menu item n/a if running
  local menu_item_text="Resume app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

reset_app() {
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Reset app to original state"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

sync_app_to_remote() {
  local menu_item_text="Sync app to remote env"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

clone_app() {
  local menu_item_text="Clone to new app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

start_shell() {
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Start shell in app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

show_app_logs() {
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Show app logs"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

uninstall_app() {
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Uninstall this app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

uninstall_other_apps() {
  local menu_item_text="Uninstall all other Magento apps"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

stop_other_apps() {
  local menu_item_text="Stop all other Magento apps"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return
  echo_in_terminal "$BASH_ARGV"
  exit
}

menu_items=(
  install_app
  open_app
  stop_app
  resume_app
  reset_app
  sync_app_to_remote
  clone_app
  start_shell
  show_app_logs
  uninstall_app
  uninstall_other_apps
  stop_other_apps
)

for menu_item in "${menu_items[@]}"; do
  $menu_item
done
