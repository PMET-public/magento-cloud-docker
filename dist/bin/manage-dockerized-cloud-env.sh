#!/bin/bash

source "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))/lib.sh"

# the Platypus status menu app will initially run this script with no arguments
# and display each line of STDOUT as an option
# when an option is selected, the option text is passed as an argument to a second run on this script

# cd to app dir containing relevant docker-compose files
cd $(get_lib_dir)/..
export_compose_project_name

has_no_args() {
  [[ ${#BASH_ARGV[@]} -eq 0 ]]
  return $?
}

do_in_terminal() {
  osascript -e "tell app \"Terminal\"
    if not (exists window 1) then reopen
    activate
    do script \"$1\" in window 1
  end tell" 2>&1 >> /tmp/out
}

write_to_bash_script() {
  local tmp_script_dir="$(get_lib_dir)/../../tmp"
  mkdir -p "$tmp_script_dir"
  local script="$tmp_script_dir/$(date -u "+%Y%m%d_%H%M%SZ").sh"
  echo "#!/bin/bash
source \"$(get_lib_dir)/lib.sh\"
${@}
" > "$script"
  chmod +x "$script"
  echo "$script"
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
  [[ ! -z "$app_is_running" ]] ||
    {
      docker ps | grep -q " ${COMPOSE_PROJECT_NAME}_db_1"
      app_is_running=$?
    }
  return "$app_is_running"
}


###
#
# menu item functions
#
###

update_this_management_app() {
  # menu logic
  #! is_update_available && return # menu item n/a if not installed
  local menu_item_text="Update this managing app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

install_app() {
  # menu logic
  is_app_installed && return
  local menu_item_text="Install & open Magento app in browser"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  {
    timestamp_msg "$menu_item_text"
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
  } >> "$(get_log_file)" 2>&1
  exit
}

open_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Open Magento app in browser"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  open "http://$(get_host)"
  exit
}

stop_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  ! is_app_running && return # menu item n/a if not running
  local menu_item_text="Stop Magento app"
  has_no_args && echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  {
    timestamp_msg "$menu_item_text"
    docker-compose stop
  } >> "$(get_log_file)" 2>&1
  exit
}

restart_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  is_app_running && return # menu item n/a if running
  local menu_item_text="Restart Magento app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  {
    timestamp_msg "$menu_item_text"
    docker-compose start
  } >> "$(get_log_file)" 2>&1
  exit
}

sync_app_to_remote() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="TODO - Sync Magento app to remote env"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

clone_app() {
  # menu logic
  local menu_item_text="TODO - Clone to new Magento app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_shell_in_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Start shell in Magento app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_management_shell() {
  # menu logic
  local menu_item_text="Start management app shell"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "cd $(get_lib_dir)/..; docker-compose run deploy bash"
  exit
}

show_app_logs() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Show Magento app logs"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

show_management_app_log() {
  # menu logic
  [[ ! -f "$(get_log_file)" ]] && return # menu item n/a if no log
  local menu_item_text="Show this managing app's log"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  local script="$(write_to_bash_script "
  msg Last 20 + follow
  tail -n 20 -f $(get_log_file)
  ")"
  do_in_terminal "$script"
  exit
}

uninstall_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  local menu_item_text="Uninstall this Magento app"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  {
    timestamp_msg "$menu_item_text"
    docker-compose down -v
  } >> "$(get_log_file)" 2>&1
  exit
}

stop_other_apps() {
  # menu logic
  local menu_item_text="Stop all other Magento apps"
  has_no_args &&
    echo "$menu_item_text" && return
  [[ "$menu_item_text" != "$BASH_ARGV" ]] && return

  # function logic
  {
    timestamp_msg "$menu_item_text"
    docker-compose stop
  } >> "$(get_log_file)" 2>&1
  exit
}

menu_items=(
  update_this_management_app
  install_app
  open_app
  stop_app
  restart_app
  sync_app_to_remote
  clone_app
  start_shell_in_app
  start_management_shell
  show_app_logs
  show_management_app_log
  uninstall_app
  stop_other_apps
)

for menu_item in "${menu_items[@]}"; do
  $menu_item
done
