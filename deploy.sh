#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

release="${HELM_RELEASE:-nc-lab}"
namespace="${HELM_NAMESPACE:-nextcloud-lab}"
profile="${DEPLOYMENT_PROFILE:-test}"
repository="${SKELETON_IMAGE_REPOSITORY:-nextcloud-skeleton}"
publish_mode="${SKELETON_PUBLISH_MODE:-local-k3s}"

case "$profile" in
  test|prod) ;;
  *)
    echo "DEPLOYMENT_PROFILE must be test or prod" >&2
    exit 1
    ;;
esac

domain="$(yq -r '.operator.domain' values.yaml)"
workflow_label="$(yq -r '.operator.subdomains.workflow' values.yaml)"
if [[ -n "$workflow_label" ]]; then
  workflow_host="${workflow_label}.${domain}"
else
  workflow_host="$domain"
fi

tag="$({
  find nc-skeleton -type f \
    ! -name .dockerignore \
    ! -name .gitkeep \
    ! -name .image-tag \
    ! -name Dockerfile \
    -print0 \
    | sort -z \
    | xargs -0 -r sha256sum
} | sha256sum | cut -c1-16)"

printf '%s\n' "$tag" > nc-skeleton/.image-tag
image="${repository}:${tag}"

echo "Building managed Nextcloud skeleton image: $image"
docker build --pull -t "$image" nc-skeleton

case "$publish_mode" in
  local-k3s)
    image_archive="$(mktemp --suffix=.tar)"
    trap 'rm -f "$image_archive"' EXIT
    docker save -o "$image_archive" "$image"
    sudo k3s ctr images import "$image_archive"
    rm -f "$image_archive"
    trap - EXIT
    ;;
  push)
    docker push "$image"
    ;;
  none)
    ;;
  *)
    echo "Unsupported SKELETON_PUBLISH_MODE: $publish_mode" >&2
    exit 1
    ;;
esac

helm upgrade --install "$release" . \
  --namespace "$namespace" \
  -f values.yaml \
  -f "values-${profile}.yaml" \
  --set-string nextcloud.skeleton.image.repository="$repository" \
  --set-string nextcloud.skeleton.image.tag="$tag" \
  --set-string workflowengine.windmill.baseDomain="$workflow_host" \
  --wait \
  --wait-for-jobs \
  --timeout 20m
