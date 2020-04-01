#!/bin/bash

set -e # stop on errors
set -x # turn on debugging

# this script assembles the parts needed for a magento cloud docker deployment and
# if supported tools/icons are detected, bundles into a OSX style app
# - the app
# - any added media files (such as pub/media including styles.css from m2 sample data install)
# - the script to manage the stack
# - the composer cache
# - the docker-compose conf
# - the database
# - the encryption key

# set up some paths
bsource_dir="$(dirname "$(python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" $BASH_SOURCE)")"
management_script="manage-dockerized-cloud-env.sh"
app_icon="magento.icns"
http_port=$(( ( RANDOM % 10000 )  + 10000 ))
rand_subdomain_suffix=$(cat /dev/random | LC_ALL=C tr -dc 'a-z' | fold -w 4 | head -n 1)
tld="the1umastory.com"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
no_color='\033[0m'

warning() {
  printf "\n${yellow}${@}${no_color}\n\n"
}

# platypus is the OSX app bundler https://github.com/sveinbjornt/Platypus
has_platypus() {
  [[ "$(which platypus)" =~ "platypus" ]]
  return $?
}

is_arg_git_repo() {
  [[ "$1" =~ "http*\.git" ]] || [[ "$1" =~ "git*\.git" ]]
  return $?
}

is_arg_git_repo $1 ||
read -r pid env < <(echo $1 | perl -pe 's/():()/\1 \2/')

# clone and then remove unwanted files from the git repo
tmp_env_dir=/tmp/$pid-$env
rm -rf $tmp_env_dir || :
magento-cloud get -e $env --depth=0 $pid $tmp_env_dir
rm -rf $tmp_env_dir/.git

# create a clean copy (before composer install) of the repo to hold all assets with the EE version appended to the dir name
# env_dir contents will be distributable unit
ee_version=$(perl -ne 'undef $/; s/[\S\s]*(cloud-metapackage|magento\/product-enterprise-edition)"[\S\s]*?"version": "([^"]*)[\S\s]*/\2/m and print' "$tmp_env_dir/composer.lock")
env_dir=$tmp_env_dir-$ee_version
rm -rf $env_dir  || :
cp -a $tmp_env_dir $env_dir

# include the managing script in app's bin dir and interpolate the url to open
mkdir -p "$env_dir/bin"
subdomain=$(echo "$pid-$env-$ee_version-$rand_subdomain_suffix" | perl "s/\./-/g")
host="$subdomain.$tld"
perl -pe "s/{{URL}}/http://$host:$http_port/g" "$bsource_dir/$management_script" > "$env_dir/bin/$management_script"

# download the media dir minus the cache
# this will invariably 
magento-cloud mount:download -q -y -p $pid -e $env -m pub/media --target $env_dir/pub/media --exclude=cache

# use the default cloud integration env database configuration, so ece-tools deploy will work the same for docker and cloud
grep -q DATABASE_CONFIGURATION $env_dir/.magento.env.yaml || perl -i -pe "s/^  deploy:\s*$/  deploy:
    DATABASE_CONFIGURATION:
      connection:
        default:
          username: user
          host: database.internal
          dbname: main
          password: ''
/" $env_dir/.magento.env.yaml

# create a compressed tar file of the composer cache needed to install the app
cd $tmp_env_dir
env COMPOSER_HOME=.composer composer -n global require hirak/prestissimo # parallelize downloads (much faster)
env COMPOSER_HOME=.composer composer install --no-suggest --no-ansi --no-interaction --no-progress --prefer-dist
tar -zcf $env_dir/.composer.tar.gz .composer

# require (or replace if already required) the official magento cloud docker module with ours
# also note that a few envs may have a composer repo entry that needs to be updated
perl -i -pe 's/magento\/magento-cloud-docker.git/pmet-public\/magento-cloud-docker.git/' composer.json
composer config repositories.mcd vcs https://github.com/pmet-public/magento-cloud-docker
env COMPOSER_HOME=.composer composer require magento/magento-cloud-docker:dev-develop

# create the docker configuration
./vendor/bin/ece-docker build:compose --host=$host --port=$http_port
mv docker-compose*.yml .docker $env_dir

# extract the DB into the expected dir
magento-cloud db:dump -p $pid -e $env -d $env_dir/.docker/mysql/docker-entrypoint-initdb.d/

# grab only the encryption key from the env's app/etc/env.php
magento-cloud ssh -p $pid -e $env "php -r '\$a = require_once(\"app/etc/env.php\"); echo \"<?php return array ( \\\"crypt\\\"  => \"; var_export(\$a[\"crypt\"]); echo \");\";'" > $env_dir/app/etc/env.php

# clean-up
rm -rf $tmp_env_dir

# remove auth.json from distributable dir
rm $env_dir/auth.json

# bundle with platypus
has_platypus &&
  [[ -f "$bsource_dir/$app_icon" ]] &&
  {
    # create app with symlinks
    platypus --interface-type 'Text Window' \
      --symlink \
      --app-icon "$bsource_dir/$app_icon" \
      --interpreter '/bin/bash' \
      --interpreter-args '-l' \
      --overwrite \
      --text-background-color '#000000' \
      --text-foreground-color '#FFFFFF' \
      --name 'Dockerized Magento' \
      -u 'Keith Bentrup' \
      --bundle-identifier 'com.magento.dockerized-magento' \
      --bundled-file "/dev/null" \
      "$env_dir/bin/$management_script" \
      "$env_dir.app"
    # mv app into app bundle
    mv "$env_dir" "$env_dir.app/Contents/Resources/app"
    # update symlinks with relative paths
    cd "$env_dir.app/Contents/Resources/"
    ln -sf "./app/bin/$management_script" "script"
    rm null # remove empty temp symlink used for bundled-file
  } || {
    echo "OSX app wrapper not generated. Missing platypus or icon files."
    echo "Install platypus with:"
    warning "brew cask install platypus"
    echo "Then install the CLI with these instructions:"
    warning "https://github.com/sveinbjornt/Platypus/blob/master/Documentation/Documentation.md#show-shell-command"
  }
