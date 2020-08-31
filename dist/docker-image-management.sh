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
  "varnish/latest"
  "nginx/latest"
)

mcd_docker_build() {
  local image
  for image in "${mcd_images[@]}"; do
    if [[ "$image" == "nginx/latest" ]]; then
      pushd "images/web" > /dev/null
    elif [[ "$image" == "varnish/latest" ]]; then
      pushd "images/varnish/6.2" > /dev/null
    else
      pushd "images/$image" > /dev/null
    fi
    tag="pmetpublic/magento-cloud-docker-${image/\//:}-$composer_major_minor_ver-$git_short_ver"
    # echo "$tag"
    docker build . --tag "$tag" > "docker-build-${image/\//-}-$composer_major_minor_ver-$git_short_ver.log"
    popd > /dev/null
  done
}

mcd_docker_publish() {
  local image
  for image in "${mcd_images[@]}"; do
    tag="pmetpublic/magento-cloud-docker-${image/\//:}-$composer_major_minor_ver-$git_short_ver"
    docker push "$tag"
  done
}
