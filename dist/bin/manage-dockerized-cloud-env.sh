#!/bin/bash

source "$(dirname "$(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE")")/lib.sh"

# the Platypus status menu app will initially run this script with no arguments
# and display each line of STDOUT as an option
# so it's critical to complete ASAP to reduce perceived latency
# when an option is selected, the option text is passed as an argument to a second run on this script

do_in_terminal() {
  script_path="$(echo "$1" | perl -pe 's/ /\\\\ /g')"
  echo "$script_path" >> /tmp/out
  osascript -e "tell application \"Terminal\"
    if not (exists window 1) then reopen
    activate
    do script \"$script_path\" in window 1
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
      echo "$formatted_cached_docker_ps_output" | grep -q "^${COMPOSE_PROJECT_NAME}_db_1 "
      app_is_installed=$?
    }
  return "$app_is_installed"
}

is_app_running() {
  [[ -z "$COMPOSE_PROJECT_NAME" ]] && return 1
  [[ ! -z "$app_is_running" ]] ||
    {
      echo "$formatted_cached_docker_ps_output" | grep -q "^${COMPOSE_PROJECT_NAME}_db_1 Up"
      app_is_running=$?
    }
  return "$app_is_running"
}

are_other_apps_running() {
  echo "$formatted_cached_docker_ps_output" | grep -q -v "^${COMPOSE_PROJECT_NAME}_db_1 "
  return $?
}

display_only_and_skip_func() {
  # returning true will cause function body to be skipped
  # returning false will cause the remainder of the function to run
  [[ "$bypass_menu_check" == "true" ]] && {
    bypass_menu_check="false"
    return 1
  }
  local mi_text=${1}__text
  local mi_icon=${1}__icon
  started_without_args && echo "${!mi_icon}${!mi_text}" && return
  [[ "${!mi_text}" != "$BASH_ARGV" ]] && return
}

detect_quit_and_stop_app() {
  # if quit_detection_file exists, already monitoring for quit and can return
  [[ -f "$quit_detection_file" ]] && return
  touch "$quit_detection_file"
  while ps -p $PPID > /dev/null 2>&1; do
    sleep 10
  done
  rm "$quit_detection_file"
  bypass_menu_check="true" && stop_app
}

###
#
# menu item functions
#
###

update_this_management_app() {
  # menu logic
  ! is_update_available && return # menu item n/a if not installed
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  update_from_master
  exit
}

install_app() {
  # menu logic
  is_app_installed && return
  display_only_and_skip_func $FUNCNAME && return

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
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  open "http://$(get_host)"
  exit
}

stop_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  ! is_app_running && return # menu item n/a if not running
  display_only_and_skip_func $FUNCNAME && return

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
  display_only_and_skip_func $FUNCNAME && return

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
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

clone_app() {
  # menu logic
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_shell_in_app() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

start_management_shell() {
  # menu logic
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  do_in_terminal "cd $lib_dir/..; docker-compose run deploy bash"
  exit
}

show_app_logs() {
  # menu logic
  ! is_app_installed && return # menu item n/a if not installed
  display_only_and_skip_func $FUNCNAME && return

  # function logic
  do_in_terminal "echo $BASH_ARGV"
  exit
}

show_management_app_log() {
  # menu logic
  [[ ! -f "$log_file" ]] && return # menu item n/a if no log
  display_only_and_skip_func $FUNCNAME && return

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
  display_only_and_skip_func $FUNCNAME && return

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
  display_only_and_skip_func $FUNCNAME && return

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
icon_color=$(is_dark_mode && echo "white" || echo "black")
menu_items=(
  "update_this_management_app"
    "Update this managing app"
    "icons/ic_system_update_alt_${icon_color}_48dp.png"

  "install_app"
    "Install & open Magento app in browser"
    #"icons/ic_publish_${icon_color}_48dp.png"
    "icons/ic_present_to_all_${icon_color}_48dp.png"

  "open_app"
    "Open Magento app in browser"
    "icons/ic_launch_${icon_color}_48dp.png"

  "stop_app"
    "Stop Magento app"
    "icons/ic_stop_${icon_color}_48dp.png"

  "restart_app"
    "Restart Magento app"
    "icons/ic_play_arrow_${icon_color}_48dp.png"

  #TODO
  "sync_app_to_remote"
    "Sync Magento app to remote env"
    "icons/ic_sync_${icon_color}_48dp.png"

  #TODO
  "clone_app"
    "Clone to new Magento app"
    "icons/ic_content_copy_${icon_color}_48dp.png"

  "start_shell_in_app"
    "Start shell in Magento app"
    "icons/ic_code_${icon_color}_48dp.png"
    #"icons/ic_keyboard_${icon_color}_48dp.png"

  "start_management_shell"
    "Start management app shell"
    "icons/ic_code_${icon_color}_48dp.png"

  "show_app_logs"
    "Show Magento app logs"
    "icons/ic_subject_${icon_color}_48dp.png"

  "show_management_app_log"
    "Show this managing app log"
    "icons/ic_subject_${icon_color}_48dp.png"

  "uninstall_app"
    "Uninstall this Magento app"
    "icons/ic_delete_${icon_color}_48dp.png"

  "stop_other_apps"
    "Stop all other Magento apps"
    "icons/ic_stop_${icon_color}_48dp.png"
)
mi_length=${#menu_items[@]}
bypass_menu_check=false

###
#
# main logic
#
###

# cd to app dir containing relevant docker-compose files
cd "$lib_dir/.."
[[ -f docker-compose.yml ]] && export_compose_project_name

formatted_cached_docker_ps_output="$(
  docker ps -a -f "label=com.magento.dockerized" --format "{{.Names}} {{.Status}}" | \
    perl -pe 's/ (Up|Exited) .*/ \1/'
)"

for (( index=0; index < mi_length; index=((index+3)) )); do
  #start=`gdate +%s.%N`
  printf -v "${menu_items[$index]}__text" %s "${menu_items[((index+1))]}"
  printf -v "${menu_items[$index]}__icon" %s "MENUITEMICON|$lib_dir/../../${menu_items[((index+2))]}|"
  #n="${menu_items[$index]}__icon"; echo "${!n}"
  ${menu_items[$index]}
  #end=`gdate +%s.%N`
  #echo "${menu_items[$index]}"
  #echo "$end - $start" | bc -l
done

# must background and disconnect STDIN & STDOUT for Platypus menu to return asynchronously
detect_quit_and_stop_app > /dev/null 2>&1 &
