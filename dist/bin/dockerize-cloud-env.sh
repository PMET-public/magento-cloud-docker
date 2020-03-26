#!/bin/bash

# assemble the parts needed for a magento cloud docker deployment
# - the app
# - the composer cache
# - the docker-compose conf
# - the database
# - the encryption key

set -e
set -x

rc_dir="$HOME/Adobe Systems Incorporated/SITeam - docker/env-library-rc"

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
env COMPOSER_HOME=.composer composer -n global require hirak/prestissimo
env COMPOSER_HOME=.composer composer install --no-suggest --no-ansi --no-interaction --no-progress --prefer-dist
tar -zcf $env_dir/.composer.tar.gz .composer

# require (or replace if already required) the official magento cloud docker module with ours
# also note that a few envs may have a composer repo entry that needs to be updated
perl -i -pe 's/magento\/magento-cloud-docker.git/pmet-public\/magento-cloud-docker.git/' composer.json
composer config repositories.mcd vcs https://github.com/pmet-public/magento-cloud-docker
env COMPOSER_HOME=.composer composer require magento/magento-cloud-docker:dev-develop

# create the docker configuration
./vendor/bin/ece-docker build:compose --host=$pid-$env.the1umastory.com --port=80
mv docker-compose*.yml .docker $env_dir

# extract the DB into the expected dir
magento-cloud db:dump -p $pid -e $env -d $env_dir/.docker/mysql/docker-entrypoint-initdb.d/

# grab only the encryption key from the env's app/etc/env.php
magento-cloud ssh -p $pid -e $env "php -r '\$a = require_once(\"app/etc/env.php\"); echo \"<?php return array ( \\\"crypt\\\"  => \"; var_export(\$a[\"crypt\"]); echo \");\";'" > $env_dir/app/etc/env.php

# clean-up
rm -rf $tmp_env_dir 

# remove auth.json from distributable dir
rm $env_dir/auth.json
