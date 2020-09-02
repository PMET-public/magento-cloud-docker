#!/usr/bin/env bash

set -e

[[ $VSCODE_PID ]] || {
  set -E # If set, the ERR trap is inherited by shell functions.
  trap 'error "Command $BASH_COMMAND failed with exit code $? on line $LINENO of $BASH_SOURCE."' ERR
}

org="pmetpublic"
org_image_prefix="magento-cloud-docker"
git_short_ver="$(git rev-parse --short HEAD)"
composer_major_minor_ver="$(perl -0777 -ne '/version"\s*:\s*"([^"]+)\./ and print $1' composer.json)"

declare -A tag_prefixes
# path -> image-name:tag-prefix
tag_prefixes["images/elasticsearch/6.5"]="$org_image_prefix-elasticsearch:6.5"
tag_prefixes["images/elasticsearch/6.8"]="$org_image_prefix-elasticsearch:6.8"
tag_prefixes["images/elasticsearch/7.5"]="$org_image_prefix-elasticsearch:7.5"
tag_prefixes["images/elasticsearch/7.6"]="$org_image_prefix-elasticsearch:7.6"
tag_prefixes["images/elasticsearch/7.7"]="$org_image_prefix-elasticsearch:7.7"
tag_prefixes["images/php/7.3-cli"]="$org_image_prefix-php:7.3-cli"
tag_prefixes["images/php/7.3-fpm"]="$org_image_prefix-php:7.3-fpm"
tag_prefixes["images/php/7.4-cli"]="$org_image_prefix-php:7.4-cli"
tag_prefixes["images/php/7.4-fpm"]="$org_image_prefix-php:7.4-fpm"
tag_prefixes["images/varnish/6.2"]="$org_image_prefix-varnish:latest"
tag_prefixes["images/web"]="$org_image_prefix-nginx:latest"

red='\033[0;31m'
no_color='\033[0m'
error() {
  printf "\n%b%s%b\n\n" "$red" "Error: $*" "$no_color" 1>&2 && exit 1
}

docker_build_and_tag_with_commit_and_latest_for_Dockerfile() {
  local dockerfile="$1" path_key tag latest_tag
  path_key="${dockerfile%/Dockerfile}"
  pushd "$path_key" > /dev/null
  tag="$org/${tag_prefixes[$path_key]}-$composer_major_minor_ver-$git_short_ver"
  latest_tag="${tag/%-$git_short_ver/-latest}"
  docker build . --tag "$tag" --tag "$latest_tag" > "/tmp/docker-build-${path_key//\//-}-$composer_major_minor_ver-$git_short_ver.log" &
  popd > /dev/null
}

docker_pull_and_tag_latest_with_commit_for_Dockerfile() {
  local dockerfile="$1" tag_prefix new_tag
  tag_prefix="$(get_tag_prefix_for_Dockerfile "$dockerfile")"
  latest_tagged_image_for_prefix="$org/$tag_prefix-$composer_major_minor_ver-latest"
  new_tag="${latest_tagged_image_for_prefix/%-latest/-$git_short_ver}"
  {
    docker pull "$latest_tagged_image_for_prefix"
    docker tag "$latest_tagged_image_for_prefix" "$new_tag"
  } &
}

docker_publish_all_mcd_tagged_images() {
  docker images "$org/$org_image_prefix*" --format="{{.Repository}}:{{.Tag}}" | xargs -n 1 -P "$(nproc)" docker push
}

get_equivalent_tags_of_docker_image() {
  local image="$1" url # ex. pmetpublic/magento-cloud-docker-php
  url="https://registry.hub.docker.com/v2/repositories/$org/$1/tags?page_size=9999"
  curl -L -s "$url" |
    # output digest and name 1 per line
    jq -jr '."results"[] | .["images"][]["digest"], " ", .["name"], "\n"' |
    sort |
    perl -pe 'chomp && s/^([^\s]+)/($prev_match eq $1 ? "" : (($prev_match="$1") && "\n$&"))/e' |
    # combine lines with same digest
    perl -pe '/^$/ and chomp; s/^.*? //' # remove extra line at head from prev op and the digest
}

has_file_changed_since_commit() {
  [[ "$2" =~ [0-9a-f]{7} ]] || error "Invalid commit"
  local path="$1" commit="$2" change
  change="$(yes "no" | git checkout -p "$commit" "$path" 2> /dev/null)"
  [[ -n "$change" ]] # empty? no change
}

get_tag_prefix_for_Dockerfile() {
  local dockerfile="$1" path_key
  path_key="${dockerfile%/Dockerfile}"
  printf "%s" "${tag_prefixes[$path_key]}"
}

has_Dockerfile_changed_since_latest_docker_image() {
  local dockerfile="$1" image tag_prefix
  tag_prefix="$(get_tag_prefix_for_Dockerfile "$dockerfile")"
  image="${tag_prefix%%:*}"
  prev_tagged_commit="$(get_equivalent_tags_of_docker_image "${tag_prefix%%:*}" | \
    grep "${tag_prefix##*:}-$composer_major_minor_ver-latest" | \
    perl -pe 's/.*-([0-9a-f]{7})(?=\s).*/$1/g' # reduce to one 7 char commit
  )"
  has_file_changed_since_commit "$dockerfile" "$prev_tagged_commit"
}

build_changed_pull_and_tag_unchanged_Dockerfiles() {
  local path_key
  for path_key in "${!tag_prefixes[@]}"; do
    if has_Dockerfile_changed_since_latest_docker_image "$path_key/Dockerfile"; then
      docker_build_and_tag_with_commit_and_latest_for_Dockerfile "$path_key/Dockerfile"
    else
      docker_pull_and_tag_latest_with_commit_for_Dockerfile "$path_key/Dockerfile"
    fi
  done
  wait
}
