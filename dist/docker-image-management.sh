#!/bin/bash

set -xe

git_short_ver="$(git rev-parse --short HEAD)"
composer_major_minor_ver="$(perl -0777 -ne '/version"\s*:\s*"([^"]+)\./ and print $1' composer.json)"
mcd_images=(
  "elasticsearch/6.5"
  "elasticsearch/6.8"
  "elasticsearch/7.5"
  "elasticsearch/7.6"
  "elasticsearch/7.7"
  "php/7.3-cli"
  "php/7.3-fpm"
  "php/7.4-cli"
  "php/7.4-fpm"
  "varnish/6.2"
  "web"
)

mcd_docker_build() {
  local image
  for image in "${mcd_images[@]}"; do
    pushd "images/$image"
    tag="pmetpublic/magento-cloud-docker-${image/\//:}-$composer_major_minor_ver-$git_short_ver"
    docker build . --tag "$tag" > "docker-build-${image/\//-}-$composer_major_minor_ver-$git_short_ver.log"
    popd
  done
}

mcd_docker_publish() {
  local image
  for image in "${mcd_images[@]}"; do
    tag="pmetpublic/magento-cloud-docker-${image/\//:}-$composer_major_minor_ver-$git_short_ver"
    docker push "$tag"
  done
}
