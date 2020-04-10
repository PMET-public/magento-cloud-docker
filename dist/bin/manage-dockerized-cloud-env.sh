#!/bin/bash

source "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))/lib.sh"

# the Platypus status menu app will initially run this script with no arguments
# and display each line of STDOUT as an option
# when an option is selected, the option text is passed as an argument to a second run on this script

# cd to app dir containing relevant docker-compose files
cd "$lib_dir/.."
[[ -f docker-compose.yml ]] && export_compose_project_name

do_in_terminal() {
  osascript -e "tell app \"Terminal\"
    if not (exists window 1) then reopen
    activate
    do script \"$1\" in window 1
  end tell" 2>&1 >> /tmp/out
}

write_to_bash_script() {
  local tmp_script_dir="$lib_dir/../../tmp"
  mkdir -p "$tmp_script_dir"
  local script="$tmp_script_dir/$(date -u "+%Y%m%d_%H%M%SZ").sh"
  echo "#!/bin/bash
source \"$lib_dir/lib.sh\"
${@}
" > "$script"
  chmod +x "$script"
  echo "$script"
}

is_app_installed() {
  [[ -z "$COMPOSE_PROJECT_NAME" ]] && return 1
  [[ ! -z "$app_is_installed" ]] ||
    {
      docker ps -a | grep -q " ${COMPOSE_PROJECT_NAME}_build_1"
      app_is_installed=$?
    }
  return "$app_is_installed"
}

is_app_running() {
  [[ -z "$COMPOSE_PROJECT_NAME" ]] && return 1
  [[ ! -z "$app_is_running" ]] ||
    {
      running_db_id=$(docker ps -q -f "name=^${COMPOSE_PROJECT_NAME}_db_1")
      [[ ! -z "$running_db_id" ]]
      app_is_running=$?
      #docker ps | grep -q " ${COMPOSE_PROJECT_NAME}_db_1"
      #app_is_running=$?
    }
  return "$app_is_running"
}

are_other_apps_running() {
  local lines=$(docker ps -f "label=com.magento.dockerized" | \
    grep -v "^${COMPOSE_PROJECT_NAME}_" | \
    wc -l)
  [[ $lines -gt 1 ]] && return
}

display_if_no_args_or_continue_if_match() {
  local mi_text=${1}__text
  local mi_icon=${1}__icon
  started_without_args && echo "${!mi_icon}${!mi_text}" && return
  [[ "${!mi_text}" != "$BASH_ARGV" ]] && return
}

###
#
# menu item functions
#
###

update_this_management_app() {
  # menu logic
  ! is_update_available && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  update_from_master
  exit
}

install_app() {
  # menu logic
  is_app_installed && return
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  {
    timestamp_msg "${!mi_text}"
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
  } >> "$log_file" 2>&1
  exit
}

open_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  open "http://$(get_host)"
  exit
}

stop_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  ! is_app_running && return # menu item n/a if not running
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  {
    timestamp_msg "${!mi_text}"
    docker-compose stop
  } >> "$log_file" 2>&1
  exit
}

restart_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  is_app_running && return # menu item n/a if running
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  {
    timestamp_msg "${!mi_text}"
    docker-compose start
  } >> "$log_file" 2>&1
  exit
}

sync_app_to_remote() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

clone_app() {
  # menu logic
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_shell_in_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_management_shell() {
  # menu logic
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  do_in_terminal "cd $lib_dir/..; docker-compose run deploy bash"
  exit
}

show_app_logs() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

show_management_app_log() {
  # menu logic
  [[ ! -f "$log_file" ]] && return # menu item n/a if no log
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  local script="$(write_to_bash_script "
  msg Last 20 + follow
  tail -n 20 -f $log_file
  ")"
  do_in_terminal "$script"
  exit
}

uninstall_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  {
    timestamp_msg "${!mi_text}"
    docker-compose down -v
  } >> "$log_file" 2>&1
  exit
}

stop_other_apps() {
  # menu logic
  ! are_other_apps_running && return
  display_if_no_args_or_continue_if_match $FUNCNAME && return

  # function logic
  {
    # relies on db service having label=label=com.magento.dockerized
    timestamp_msg "${!mi_text}"
    compose_project_names="$(
      docker ps -f "label=com.magento.dockerized" --format="{{ .Names  }}" | \
      perl -pe 's/_db_1$//' | \
      grep -v '^${COMPOSE_PROJECT_NAME}$'
    )"
    for name in $compose_project_names; do
      docker stop $(docker ps -q -f "name=^${name}_")
    done
  } >> "$log_file" 2>&1
  exit
}


# bash 3.2 (the default on osx) does not support associative arrays
# to compensate, this menu items data structure relies on each having 3 entries in a specific order
# 1. function name 2. text 3. icon
# then use printf -v variable assignment and indirect expansion: ${!0}
# to create desired vars func_name__text & func_name__icon at run time
# icons from https://material.io/resources/icons/
icon_prefix="https://raw.githubusercontent.com/google/material-design-icons/3.0.1"
icon_color=$(is_dark_mode && echo "white" || echo "black")
menu_items=(
  "update_this_management_app"
    "Update this managing app"
    "$icon_prefix/action/1x_web/ic_system_update_alt_${icon_color}_48dp.png"

  "install_app"
    "Install & open Magento app in browser"
    "$icon_prefix/editor/1x_web/ic_publish_${icon_color}_48dp.png"
    #"$icon_prefix/communication/1x_web/ic_present_to_all_${icon_color}_48dp.png"

  "open_app"
    "Open Magento app in browser"
    "$icon_prefix/action/1x_web/ic_launch_${icon_color}_48dp.png"

  "stop_app"
    "Stop Magento app"
    "$icon_prefix/av/1x_web/ic_stop_${icon_color}_48dp.png"

  "restart_app"
    "Restart Magento app"
    "$icon_prefix/av/1x_web/ic_play_arrow_${icon_color}_48dp.png"

  #TODO
  "sync_app_to_remote"
    "Sync Magento app to remote env"
    "$icon_prefix/notification/1x_web/ic_sync_${icon_color}_48dp.png"

  #TODO
  "clone_app"
    "Clone to new Magento app"
    "$icon_prefix/content/1x_web/ic_content_copy_${icon_color}_48dp.png"

  "start_shell_in_app"
    "Start shell in Magento app"
    "$icon_prefix/action/1x_web/ic_code_${icon_color}_48dp.png"
    #"$icon_prefix/hardware/1x_web/ic_keyboard_${icon_color}_48dp.png"

  "start_management_shell"
    "Start management app shell"
    "$icon_prefix/action/1x_web/ic_code_${icon_color}_48dp.png"

  "show_app_logs"
    "Show Magento app logs"
    "$icon_prefix/action/1x_web/ic_subject_${icon_color}_48dp.png"

  "show_management_app_log"
    "Show this managing app log"
    "$icon_prefix/action/1x_web/ic_subject_${icon_color}_48dp.png"

  "uninstall_app"
    "Uninstall this Magento app"
    "$icon_prefix/action/1x_web/ic_delete_${icon_color}_48dp.png"

  "stop_other_apps"
    "Stop all other Magento apps"
    "$icon_prefix/av/1x_web/ic_stop_${icon_color}_48dp.png"
)
mi_length=${#menu_items[@]}

icons_downloaded() {
  # assume if 1st icon downloaded, all downloaded
  local icon_filename="$(echo "${menu_items[2]}" | perl -pe 's/.*\///')"
  [[ -f "$icon_dir/$icon_filename" ]]
  return $?
}

use_local_icons() {
  local index
  for (( index=2; index < mi_length; index=((index+3)) )); do
    menu_items[$index]="$icon_dir/$(echo "${menu_items[$index]}" | perl -pe 's/.*\///')"
  done
}

download_icons() {
  local index
  local urls=()
  cd "$icon_dir"
  for (( index=2; index < mi_length; index=((index+3)) )); do
    urls+=(${menu_items[$index]})
  done
  echo "${urls[@]}" | xargs -n 1 curl -s -O
}

icons_downloaded &&
  use_local_icons ||
  {
    # must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
    download_icons > /dev/null 2>&1 & 
  }

#echo "$PPID"
for (( index=0; index < mi_length; index=((index+3)) )); do
  start=`gdate +%s.%N`
  printf -v "${menu_items[$index]}__text" %s "${menu_items[((index+1))]}"
  printf -v "${menu_items[$index]}__icon" %s "MENUITEMICON|${menu_items[((index+2))]}|"
  #n="${menu_items[$index]}__icon"; echo "${!n}"
  ${menu_items[$index]}
  end=`gdate +%s.%N`
  echo "${menu_items[$index]}"
  echo "$end - $start" | bc -l
done
