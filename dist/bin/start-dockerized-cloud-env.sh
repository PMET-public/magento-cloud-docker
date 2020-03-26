#!/bin/bash

set -e
set -x

# create containers but do not start
docker-compose up --no-start
prefix=$(docker-compose ps | sed -n 's/_build_1 .*$//p')
# copy db files to db container
docker cp .docker/mysql/docker-entrypoint-initdb.d ${prefix}_db_1:/
# copy over app files to build container
tar -cf - --exclude .docker --exclude .composer.tar.gz . | docker cp - ${prefix}_build_1:/app
tar -zxf .composer.tar.gz | docker cp - ${prefix}_build_1:/app
docker cp app/etc ${prefix}_deploy_1:/app/app/
docker-compose up -d db build
docker-compose run build cloud-build
docker-compose up -d
docker-compose run deploy cloud-deploy
docker-compose run deploy cloud-post-deploy
