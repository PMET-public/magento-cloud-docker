#!/usr/bin/env bash
set -e

# the Platypus status menu app will initially run this script without arguments
# and display each line of STDOUT as an option
# so it's critical to complete ASAP when run w/o args to reduce perceived latency
#
# when a menu item is selected, this script is run again in the background w/ the menu item text passed as an arg
# the platyplus app does not wait for the background run to complete before the menu can be rendered again
#
# also note that the script is invoked by `/usr/bin/env -P "/usr/local/bin:/bin" bash "/path/to/script"`
# by using `brew [un]link bash`, you can toggle between OSX's native 3.2 bash & a more modern one for debugging
# by invoking with debug=1 open this-app.app, lots of debugging info will be sent to the log files

#start="$(gdate +%s.%N)"
declare -r menu_log_file="${BASH_SOURCE[0]}.menu.log"
declare -r action_log_file="${BASH_SOURCE[0]}.action.log"
if [[ -z "${BASH_ARGV[0]}" ]]; then
  declare -r cur_log_file="$menu_log_file"
else
  declare -r cur_log_file="$action_log_file"
fi

# this will send bash xtrace output to a dynamically allocated file descriptor and append it to the designated log
# keeping xtrace output separate from STDOUT if possible (bash > 3 (osx default))
[[ ${BASH_VERSINFO[0]} -gt 3 ]] && {
  exec {myfd}>> "$cur_log_file"
  export BASH_XTRACEFD="$myfd"
}

exec > >(tee -ia "$cur_log_file")
exec 2> >(tee -ia "$cur_log_file" >&2)

# shellcheck source=lib.sh
source "$(dirname "$(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")/lib.sh"
timestamp_msg "-------${BASH_SOURCE[0]} called-------" >> "$cur_log_file"

# cd to app dir containing relevant docker-compose files
cd "$lib_dir/.." || exit
[[ -f docker-compose.yml ]] && export_compose_project_name

declare -r recommended_vm_cpu=4 
declare -r recommended_vm_mem_mb=4096 
declare -r recommended_vm_swap_mb=2048 
declare -r bytes_in_mb=1048576
declare -r docker_settings_file="$HOME/Library/Group Containers/group.com.docker/settings.json"
declare -r quit_detection_file="${BASH_SOURCE[0]}.$PPID.still_running"
declare -r status_msg_file="${BASH_SOURCE[0]}.status"

# echos pid of script as result
run_as_bash_script_in_terminal() {
  local script counter pid
  script=$(mktemp -t "$COMPOSE_PROJECT_NAME-${FUNCNAME[1]}") || exit
  echo "#!/usr/bin/env bash -l
set +x
unset BASH_XTRACEFD
unset debug
# set title of terminal
echo -n -e '\033]0;${FUNCNAME[1]} $COMPOSE_PROJECT_NAME\007'
clear
source \"$lib_dir/lib.sh\"
${*}
" > "$script"
  chmod u+x "$script"
  open -a Terminal "$script"
  # wait up to a brief time to return pid of script or false
  # exit status of pid will be unavailable b/c not a child job
  # but script could leave exit status artifact
  for (( counter=0; counter < 10; ((counter++)) )); do
    pid="$(pgrep -f "$script")"
    [[ -n "$pid" ]] && echo "$pid" && return
    sleep 0.5
  done
  return false
}

is_docker_installed() {
  [[ -d /Applications/Docker.app ]]
}

is_docker_running() {
  pgrep -q com.docker.hyperkit
}

is_docker_ready() {
  docker ps > /dev/null 2>&1
}

restart_docker_and_wait() {
  osascript -e 'quit app "Docker"'
  open --background -a Docker
  while ! is_docker_ready; do
    sleep 5
  done
}

can_optimize_vm_cpus() {
  cpus_for_vm=$(grep '"cpus"' "$docker_settings_file" | perl -pe 's/.*: (\d+),/\1/')
  cpus_available=$(sysctl -n hw.logicalcpu)
  [[ cpus_for_vm -lt recommended_vm_cpu && cpus_available -gt recommended_vm_cpu ]]
}

can_optimize_vm_mem() {
  memory_for_vm=$(grep '"memoryMiB"' "$docker_settings_file" | perl -pe 's/.*: (\d+),/\1/')
  memory_available=$(( $(sysctl -n hw.memsize) / bytes_in_mb ))
  [[ memory_for_vm -lt recommended_vm_mem_mb && memory_available -ge 8192 ]]
}

can_optimize_vm_swap() {
  swap_for_vm=$(grep '"swapMiB"' "$docker_settings_file" | perl -pe 's/.*: (\d+),/\1/')
  [[ swap_for_vm -lt recommended_vm_swap_mb ]]
}

is_app_installed() {
  # grep once and store result in var
  [[ -n "$app_is_installed" ]] ||
    {
      echo "$formatted_cached_docker_ps_output" | grep -q "^${COMPOSE_PROJECT_NAME}_db_1 "
      app_is_installed=$?
    }
  return "$app_is_installed"
}

is_app_running() {
  # grep once and store result in var
  [[ -n "$app_is_running" ]] || {
    echo "$formatted_cached_docker_ps_output" | grep -q "^${COMPOSE_PROJECT_NAME}_db_1 Up"
    app_is_running=$?
  }
  return "$app_is_running"
}

are_other_apps_running() {
  echo "$formatted_cached_docker_ps_output" | \
    grep -v "^${COMPOSE_PROJECT_NAME}_db_1 " | \
    grep -q -v ' Exited$'
  return $?
}

display_only_and_skip_func() {
  # returning true will cause function body to be skipped
  # returning false will cause the remainder of the function to run
  [[ "$bypass_menu_check_once" == "true" ]] && {
    bypass_menu_check_once="false" # set global bypass var to false for each skip
    false; return
  }
  local mi_text mi_icon
  mi_text=${1}__text
  mi_icon=${1}__icon
  started_without_args && echo "${!mi_icon}${!mi_text}" && return
  [[ "${!mi_text}" != "${BASH_ARGV[0]}" ]] && return
}

detect_quit_and_stop_app() {
  touch "$quit_detection_file"
  # run the loop in a subshell so it doesn't fill the log with loop output
  ( 
    set +x
    # while the Platyplus app exists ($PPID), do nothing
    while ps -p $PPID > /dev/null 2>&1; do
      sleep 10
    done
  )
  # parent pid gone, so remove file and stop dockerized magento
  rm "$quit_detection_file"
  bypass_menu_check_once="true" && stop_app
}

set_status_and_wait_for_exit() {
  local pid_to_wait_for status start exit_status_msg
  pid_to_wait_for="$1"
  status="$2"
  start="$(date +%s)"
  exit_status_msg="MENUITEMICON|$lib_dir/icons/"
  echo "DISABLED|MENUITEMICON|$lib_dir/icons/ic_av_timer_${icon_color}_48dp.png|Please wait. $status" > "$status_msg_file"
  if wait "$pid_to_wait_for"; then
    exit_status_msg+="ic_check_${icon_color}_48dp.png|Success. $status "
  else
    exit_status_msg+="ic_warning_${icon_color}_48dp.png|Error! $status "
  fi
  exit_status_msg+="$(convert_secs_to_hms "$(seconds_since "$start")")"
  printf "%s" "$exit_status_msg" > "$status_msg_file"
}

clear_status() {
  rm "$status_msg_file"
}

extract_tar_to_docker() {
  # extract tar to tmp dir then stream to docker build container
  # N.B. `tar -xf some.tar -O` is stream of file _contents_; `tar -cf -` is tar formatted stream (handles metadata)
  local src_tar container_dest tmp_dir
  src_tar="$1"
  container_dest="$2"
  tmp_dir="$(mktemp -d)"
  tar -zxf "$src_tar" -C "$tmp_dir"
  tar -cf - -C "$tmp_dir" . | docker cp - "$container_dest"
  rm -rf "$tmp_dir"
}

###
#
# menu item functions
#
# if a menu item:
#   1. completes immediately, just run
#   2. requires user interaction (including long term monitoring of output), run in terminal
#   3. should be completed in the background, run as child process and set non-blocking status
#
###

show_status() {
  [[ -f "$status_msg_file" ]] && {
    local status
    status=$(<"$status_msg_file")
    # if status already has time, process completed
    if [[ "$status" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
      echo "$status"
    else
      echo "$status $(convert_secs_to_hms "$(( $(date +%s) - $(stat -f%c "$status_msg_file") ))")"
    fi
    echo "---------"
  }
  :
}

install_docker() {
  # menu logic
  is_docker_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && exit

  # function logic
  open "https://hub.docker.com/editions/community/docker-ce-desktop-mac/"
  exit

}

start_docker() {
  # menu logic
  is_docker_running && return
  display_only_and_skip_func "${FUNCNAME[0]}" && exit

  # function logic
  {
    timestamp_msg "${FUNCNAME[0]}"
    restart_docker_and_wait
  } >> "$action_log_file" 2>&1 &
  set_status_and_wait_for_exit $! "Starting Docker VM ..."
  exit
}

optimize_docker() {
  # menu logic
  ! can_optimize_vm_cpus && ! can_optimize_vm_mem && ! can_optimize_vm_swap && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  {
    timestamp_msg "${FUNCNAME[0]}"
    cp "$docker_settings_file" "$docker_settings_file.bak"
    can_optimize_vm_cpus && perl -i -pe 's/("cpus"\s*:\s*)\d+/${1}4/' "$docker_settings_file"
    can_optimize_vm_mem && perl -i -pe 's/("swapMiB"\s*:\s*)\d+/${1}2048/' "$docker_settings_file"
    can_optimize_vm_swap && perl -i -pe 's/("memoryMiB"\s*:\s*)\d+/${1}4096/' "$docker_settings_file"
    restart_docker_and_wait
  } >> "$action_log_file" 2>&1 &
  set_status_and_wait_for_exit $! "Optimizing Docker VM ..."
  exit
}

update_this_management_app() {
  # menu logic
  ! is_update_available && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  update_from_local_dir
  exit
}

install_app() {
  # menu logic
  is_app_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  (
    timestamp_msg "${FUNCNAME[0]}"
    # create containers but do not start
    docker-compose up --no-start
    # copy db files to db container & start it up
    docker cp .docker/mysql/docker-entrypoint-initdb.d "${COMPOSE_PROJECT_NAME}_db_1":/
    docker-compose up -d db
    # copy over most files in local app dir to build container
    tar -cf - --exclude .docker --exclude .composer.tar.gz --exclude media.tar.gz . | \
      docker cp - "${COMPOSE_PROJECT_NAME}_build_1":/app
    # extract tars created for distribution via sync service e.g. dropbox, onedrive
    extract_tar_to_docker .composer.tar.gz "${COMPOSE_PROJECT_NAME}_build_1:/app"
    [[ -f media.tar.gz ]] && extract_tar_to_docker media.tar.gz "${COMPOSE_PROJECT_NAME}_build_1:/app"
    docker cp app/etc "${COMPOSE_PROJECT_NAME}_deploy_1":/app/app/
    docker-compose up build
    docker-compose up -d
    docker-compose run deploy cloud-deploy
    docker-compose run deploy magento-command config:set system/full_page_cache/caching_application 2 --lock-env
    docker-compose run deploy cloud-post-deploy
    open "http://$(get_host)"
  ) >> "$action_log_file" 2>&1 &
  local background_install_pid=$!
  bypass_menu_check_once=true
  show_management_app_log >> "$action_log_file" 2>&1 &
  # last b/c of blocking wait 
  # can't run in background b/c child process can't "wait" for sibling proces only descendant processes
  set_status_and_wait_for_exit $background_install_pid "Installing Magento ..."
  exit
}

open_app() {
  # menu logic
  ! is_app_running && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  open "http://$(get_host)"
  exit
}

stop_app() {
  # menu logic
  ! is_app_installed && return
  ! is_app_running && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  {
    timestamp_msg "${FUNCNAME[0]}"
    docker-compose stop
  } >> "$action_log_file" 2>&1
  set_status_and_wait_for_exit $! "Stopping Magento application ..."
  exit
}

restart_app() {
  # menu logic
  ! is_app_installed && return
  is_app_running && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  {
    timestamp_msg "${FUNCNAME[0]}"
    docker-compose start
    # TODO could check for HTTP 200
  } >> "$action_log_file" 2>&1 &
  set_status_and_wait_for_exit $! "Starting Magento application ..."
  exit
}

sync_app_to_remote() {
  # menu logic
  ! is_app_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  :
  exit
}

clone_app() {
  # menu logic
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  :
  exit
}

start_shell_in_app() {
  # menu logic
  ! is_app_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  run_as_bash_script_in_terminal "
    cd \"$lib_dir/..\" || exit
    docker-compose run deploy bash
  "
  exit
}

start_management_shell() {
  # menu logic
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  local services_status
  if is_app_installed; then
    services_status="$(docker-compose ps)"
  else
    services_status="$(warning Magento app not installed yet.)"
  fi
  run_as_bash_script_in_terminal "
    cd \"$lib_dir/..\" || exit
    msg Running $COMPOSE_PROJECT_NAME from $(pwd)
    echo -e \"\\n$services_status\\n\"
    bash -l
  "
  exit
}

show_app_logs() {
  # menu logic
  ! is_app_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  :
  exit
}

show_management_app_log() {
  # menu logic
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  run_as_bash_script_in_terminal "
    cd \"$lib_dir/../../\" || exit
    screen -c '$lib_dir/.screenrc'
    exit
  "
  exit
}

uninstall_app() {
  # menu logic
  ! is_app_installed && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  timestamp_msg "${FUNCNAME[0]}"
  local pid
  run_as_bash_script_in_terminal "
    exec > >(tee -ia \"$action_log_file\")
    exec 2> >(tee -ia \"$action_log_file\" >&2)
    warning THIS WILL DELETE ANY CHANGES TO $COMPOSE_PROJECT_NAME!
    read -p ' ARE YOU SURE?? (y/n) '
    if [[ \$REPLY =~ ^[Yy]\$ ]]; then
      cd \"$lib_dir/..\" || exit
      docker-compose down -v
    else
      echo -e '\nNothing changed.'
    fi
  "
  exit
}

stop_other_apps() {
  # menu logic
  ! are_other_apps_running && return
  display_only_and_skip_func "${FUNCNAME[0]}" && return

  # function logic
  {
    timestamp_msg "${FUNCNAME[0]}"
    # relies on db service having label=label=com.magento.dockerized
    compose_project_names="$(
      docker ps -f "label=com.magento.dockerized" --format="{{ .Names  }}" | \
      perl -pe 's/_db_1$//' | \
      grep -v "^${COMPOSE_PROJECT_NAME}\$"
    )"
    for name in $compose_project_names; do
      # shellcheck disable=SC2046
      docker stop $(docker ps -q -f "name=^${name}_")
    done
  } >> "$action_log_file" 2>&1 &
  set_status_and_wait_for_exit $! "Stopping other apps ..."
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

  "show_status"
    "n/a"
    "n/a"

  "install_docker"
    "Install Docker to continue"
    "ic_present_to_all_${icon_color}_48dp.png"

  "start_docker"
    "Start Docker to continue"
    "ic_play_arrow_${icon_color}_48dp.png"

  # blocks: 
  "optimize_docker"
    "Optimize Docker for better performance"
    "baseline_speed_${icon_color}_48dp.png"

  "update_this_management_app"
    "Update this managing app"
    "ic_system_update_alt_${icon_color}_48dp.png"

  # blocks: operations dependent on app being 
  "install_app"
    "Install & open Magento app in browser"
    #"ic_publish_${icon_color}_48dp.png"
    "ic_present_to_all_${icon_color}_48dp.png"

  "open_app"
    "Open Magento app in browser"
    "ic_launch_${icon_color}_48dp.png"

  "stop_app"
    "Stop Magento app"
    "ic_stop_${icon_color}_48dp.png"

  "restart_app"
    "Restart Magento app"
    "ic_play_arrow_${icon_color}_48dp.png"

  #TODO
  "sync_app_to_remote"
    "TODO Sync Magento app to remote env"
    "ic_sync_${icon_color}_48dp.png"

  #TODO
  "clone_app"
    "TODO Clone to new Magento app"
    "ic_content_copy_${icon_color}_48dp.png"

  "start_shell_in_app"
    "Start shell in Magento app"
    "ic_code_${icon_color}_48dp.png"
    #"ic_keyboard_${icon_color}_48dp.png"

  "start_management_shell"
    "Start management app shell"
    "ic_code_${icon_color}_48dp.png"

  "show_app_logs"
    "Show Magento app logs"
    "ic_subject_${icon_color}_48dp.png"

  "show_management_app_log"
    "Show this managing app logs"
    "ic_subject_${icon_color}_48dp.png"

  "uninstall_app"
    "Uninstall this Magento app"
    "ic_delete_${icon_color}_48dp.png"

  "stop_other_apps"
    "Stop all other Magento apps"
    "ic_stop_${icon_color}_48dp.png"
)
mi_length=${#menu_items[@]}
bypass_menu_check_once=false

###
#
# main logic
#
###

is_docker_ready && formatted_cached_docker_ps_output="$(
  docker ps -a -f "label=com.magento.dockerized" --format "{{.Names}} {{.Status}}" | \
    perl -pe 's/ (Up|Exited) .*/ \1/'
)"

#end="$(gdate +%s.%N)"
#echo "$end - $start" | bc -l

for (( index=0; index < mi_length; index=((index+3)) )); do
  # if selected menu item matches an exit timer, clear exit timer status and exit
  [[ "${BASH_ARGV[0]}" =~ [0-9]{2}:[0-9]{2}:[0-9]{2} ]] && clear_status && exit

  # if any menu item is selected, skip to that function
  [[ -n "${BASH_ARGV[0]}" && "${BASH_ARGV[0]}" != "${menu_items[((index+1))]}" ]] && continue

  # otherwise display menu
  #start="$(gdate +%s.%N)"
  printf -v "${menu_items[$index]}__text" %s "${menu_items[((index+1))]}"
  printf -v "${menu_items[$index]}__icon" %s "MENUITEMICON|$lib_dir/icons/${menu_items[((index+2))]}|"
  ${menu_items[$index]}
  #end="$(gdate +%s.%N)"
  #echo "$end - $start" | bc -l
done

# if quit_detection_file does not exist, start monitoring for quit
if [[ ! -f "$quit_detection_file" ]]; then
  detect_quit_and_stop_app >> "$action_log_file" 2>&1 & # must background & disconnect STDIN & STDOUT for Platypus to exit
fi
