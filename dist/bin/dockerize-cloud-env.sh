#!/bin/bash

source "$(dirname $(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$BASH_SOURCE"))/lib.sh"

# this script assembles the parts needed for a magento cloud docker deployment and
# if supported tools/icons are detected, bundles into a OSX style app
# order of stpes matter because some operations depend on the results of others
#
# 1. the app from an existing env or git repo + branch
# 2. any added media files (such as pub/media including styles.css from m2 sample data install)
#   - req before compose cache bundling for catalog media dedup if from existing
# 3. the script to manage the stack
# 4. the composer cache
# 5. the docker-compose conf
#   - req after unique subdomain determined based on install source + version + random nonce
# 6. the database
# 7. the encryption key
#

management_script="manage-dockerized-cloud-env.sh"
app_icon_path="$(lib_d)/magento.icns"
http_port=$(( ( RANDOM % 10000 )  + 10000 ))
rand_subdomain_suffix=$(cat /dev/random | LC_ALL=C tr -dc 'a-z' | fold -w 4 | head -n 1)
tld="the1umastory.com"

# platypus is the OSX app bundler https://github.com/sveinbjornt/Platypus
has_platypus() {
  [[ "$(which platypus)" =~ "platypus" ]]
  return $?
}

is_valid_git_url() {
  [[ "$1" =~ http.*\.git ]] || [[ "$1" =~ git.*\.git ]]
  return $?
}

is_existing_cloud_env() {
  [[ "$env_is_existing_cloud" == "true" ]]
  return $?
}

print_usage() {
  echo "
Usage:
  $(basename $BASH_SOURCE) can either clone an existing cloud environment OR install a new Magento application from a Magento Cloud compatible git repository.

Options:
  -h                        Display this help
  -p project id             Project to clone
  -e environment id         Environment to clone
  -g git url                Git repository to install from
  -b branch                 Git branch for install (HEAD commit of branch will be used)
  -t tag                    Git tag for install (not compatible with '-b')
  -a /path/to/auth.json     Optional path to auth.json file if required by composer
  -i /path/to/file.icns     Optional path to icon for Platyplus OSX app bundle (Apple .icns file preferred)
"
}

# parse options
while getopts "b:e:g:hp:t:a:i:" opt || [[ $# -eq 0 ]]; do
  case "$opt" in
    h ) print_usage; exit 0 ;;
    p ) pid="$OPTARG" ;;
    e ) env="$OPTARG" ;;
    g ) git_url="$OPTARG" ;;
    b ) branch="$OPTARG" ;;
    t ) tag="$OPTARG" ;;
    a ) auth_json_path="$OPTARG" ;;
    i ) app_icon="$OPTARG" ;;
    \? )
      print_usage
      [[ -z "$OPTARG" ]] && error "Missing required option(s)."
      error "Invalid option: -$OPTARG" ;;
    : ) print_usage; error "Invalid option: -$OPTARG requires an argument" 1>&2 ;;
  esac
done

# additional error checking
{
  { # pid and env are not empty but other related opts are
    [[ ! -z "$pid" ]] && [[ ! -z "$env" ]] && [[ -z "$git_url" ]] && [[ -z "$branch" ]] && [[ -z "$tag" ]] && \
      env_is_existing_cloud="true"
  } ||
  { # git url and branch are not empty but other related opts are
    [[ ! -z "$git_url" ]] && [[ ! -z "$branch" ]] && [[ -z "$tag" ]] && [[ -z "$pid" ]] && [[ -z "$env" ]]
  } ||
  { # git url and tag are not empty but other related opts are
    [[ ! -z "$git_url" ]] && [[ ! -z "$tag" ]] && [[ -z "$branch" ]] && [[ -z "$pid" ]] && [[ -z "$env" ]]
  }
} ||
  error "
You must provide either:
  1) a project & environment id
- OR -
  2) a git url plus a specific branch or tag
"
[[ ! -z "$auth_json_path" && ! -f "$auth_json_path" ]] && error "Composer auth file not file: $auth_json_path"
[[ ! -f "$app_icon_path" ]] && error "App icon not file: $app_icon_path"


is_existing_cloud_env &&
  {
    magento-cloud -q || error "The magento-cloud CLI was not found. To install, run
    curl -sS https://accounts.magento.cloud/cli/installer | php"
    app_name="$pid-$env"
  } || {
    is_valid_git_url "$git_url" ||
      error "Please check your git url."
    git_repo=$(echo "$git_url" | perl -pe 's/.*\/(.*)\.git/\1/')
    app_name="$git_repo-$branch$tag"
  }

# clone and then remove unwanted files from the git repo
tmp_app_dir="$HOME/Downloads/$app_name"
rm -rf "$tmp_app_dir" || :
is_existing_cloud_env &&
  magento-cloud get -e "$env" --depth=0 "$pid" "$tmp_app_dir" ||
  git clone "$git_url" --branch "$branch$tag" --depth 1 "$tmp_app_dir"
rm -rf "$tmp_app_dir/.git"

# create a clean copy (before composer install) of repo to hold assets with the EE version appended to the dir name
# app_dir contents will be distributable unit
ee_version=$(
  perl -ne '
    undef $/;
    s/[\S\s]*(cloud-metapackage|magento\/product-enterprise-edition)"[\S\s]*?"version": "([^"]*)[\S\s]*/\2/m and print
  ' "$tmp_app_dir/composer.lock"
)
app_dir=$tmp_app_dir-$ee_version
rm -rf "$app_dir"  || :
cp -a "$tmp_app_dir" "$app_dir"
subdomain=$(echo "$app_name-$ee_version-$rand_subdomain_suffix" | perl -pe 's/\./-/g')
host="$subdomain.$tld"

# include the managing script in app's bin dir
mkdir -p "$app_dir/bin"
cp "$lib_dir/$management_script" "$app_dir/bin/$management_script"

# if cloning existing env, download the media dir minus the cache
# this will cause significant redundancy of images until can be deduped
is_existing_cloud_env &&
  {
    mkdir -p "$tmp_app_dir/pub/media"
    magento-cloud mount:download -y -p "$pid" -e "$env" -m pub/media --target "$tmp_app_dir/pub/media" --exclude=cache
    tar -C "$tmp_app_dir" -zcf "$app_dir/media.tar.gz" "pub/media"
  }

# use default cloud integration env database configuration, so ece-tools deploy will work the same for docker and cloud
grep -q DATABASE_CONFIGURATION "$app_dir/.magento.env.yaml" || perl -i -pe "s/^  deploy:\s*$/  deploy:
    DATABASE_CONFIGURATION:
      connection:
        default:
          username: user
          host: database.internal
          dbname: main
          password: ''
/" "$app_dir/.magento.env.yaml"

# goals of following composer operations:
# 1. create a compressed tar file of the composer cache needed to install the app so
#   a. smaller, more manageable distributable
#   b. fast install during build
#   c. no credentials needed in build container
# 2. use prestissimo to speed up the creation of the cache
# 3. do not run the composer.json install scripts (also to speed up the composer cache creation)
# 4. use modified version of magento-cloud-docker to create modified docker-compose files
# 5. restore original composer.json and composer.lock to ensure originals are used for deployment in containers
cd "$tmp_app_dir"
[[ ! -z "$auth_json_path" ]] && # if auth.json provided, use it
  cp "$auth_json_path" "$tmp_app_dir"
[[ ! -f "auth.json" ]] && 
  warning "No auth.json file detected! Composer may be rate-limited and/or unable to download required packages." && sleep 5
# backup for later restore
cp composer.json composer.json.bak
cp composer.lock composer.lock.bak
env COMPOSER_HOME=.composer composer global require hirak/prestissimo --no-interaction # parallelize downloads (much faster)
# install with original composer.lock (but with composer.json scripts skipped) so exact versions needed for build in cache
cat composer.json.bak | \
  python -c "import sys, json; data = json.load(sys.stdin); del data['scripts']; print(json.dumps(data))" > composer.json
env COMPOSER_HOME=.composer composer install --no-suggest --no-ansi --no-interaction --no-progress --prefer-dist
# require (or replace if already required) the official magento cloud docker module with ours
# also note that a few envs may have a composer repo entry that needs to be updated
perl -i -pe 's/magento\/magento-cloud-docker.git/pmet-public\/magento-cloud-docker.git/' composer.json
grep -q 'pmet-public/magento-cloud-docker' composer.json ||
  env COMPOSER_HOME=.composer composer config repositories.mcd git git@github.com:pmet-public/magento-cloud-docker.git
env COMPOSER_HOME=.composer composer require magento/magento-cloud-docker:dev-develop --no-suggest --no-ansi --no-interaction --no-progress
# create the docker configuration with the modified magento cloud docker
./vendor/bin/ece-docker build:compose --host="$host" --port="$http_port"
mv docker-compose*.yml .docker "$app_dir"
# restore the original composer files for use in the build container later
mv composer.json.bak composer.json
mv composer.lock.bak composer.lock
# remove auth.json from distributable dir if it exists
rm "$app_dir/auth.json" || :
# special case: assuming some existing installed packages already have catalog imagery from modules in pub/media, we can delete that media
# this can significantly reduce composer archive size
is_existing_cloud_env && find .composer -path "*/catalog/product/*.jpg" -delete || :
tar -zcf "$app_dir/.composer.tar.gz" .composer
# del tmp dir
cd "$app_dir" && rm -rf "$tmp_app_dir"

# if cloning existing env, extract the DB into the expected dir
is_existing_cloud_env &&
  magento-cloud db:dump -p "$pid" -e "$env" -d "$app_dir/.docker/mysql/docker-entrypoint-initdb.d/"

# if cloning existing env, grab only the encryption key from the env's app/etc/env.php
is_existing_cloud_env &&
  magento-cloud ssh -p "$pid" -e "$env" "
    php -r '\$a = require_once(\"app/etc/env.php\");
    echo \"<?php return array ( \\\"crypt\\\"  => \";
    var_export(\$a[\"crypt\"]); echo \");\";'
  " > "$app_dir/app/etc/env.php"

# bundle with platypus
has_platypus &&
  {
    # create app with symlinks
    platypus \
      --app-icon "$app_icon_path" \
      --status-item-kind 'Icon' \
      --status-item-icon "$app_icon_path" \
      --interface-type 'Status Menu' \
      --symlink \
      --interpreter '/bin/bash' \
      --interpreter-args '-l' \
      --overwrite \
      --text-background-color '#000000' \
      --text-foreground-color '#FFFFFF' \
      --name "$subdomain" \
      -u 'Keith Bentrup' \
      --bundle-identifier 'com.magento.dockerized-magento' \
      --bundled-file "/dev/null" \
      "$app_dir/bin/$management_script" \
      "$app_dir.app"
    # mv app into app bundle
    mv "$app_dir" "$app_dir.app/Contents/Resources/app"
    cp "$lib_dir/icons" "$app_dir.app/Contents/Resources/icons"
    # update symlinks with relative paths
    cd "$app_dir.app/Contents/Resources/"
    ln -sf "./app/bin/$management_script" "script"
    rm null # remove empty temp symlink used for bundled-file
    msg "Successfully created $app_dir.app"
  } || {
    warning "Platypus not found. OSX app bundle not generated."
    echo "Install platypus with:"
    warning "brew cask install platypus"
    echo "Then install the CLI with these instructions:"
    warning "https://github.com/sveinbjornt/Platypus/blob/master/Documentation/Documentation.md#show-shell-command"
  }
