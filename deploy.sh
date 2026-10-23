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

value_files=(values.yaml "values-${profile}.yaml")
if [[ -n "${VALUES_OVERLAY:-}" ]]; then
  if [[ ! -f "$VALUES_OVERLAY" ]]; then
    echo "VALUES_OVERLAY does not exist: $VALUES_OVERLAY" >&2
    exit 1
  fi
  value_files+=("$VALUES_OVERLAY")
fi
if [[ -f values-local.yaml ]]; then
  value_files+=(values-local.yaml)
fi

merged_value() {
  local query="$1"
  if yq --version 2>&1 | grep -q mikefarah; then
    yq eval-all -r ". as \$item ireduce ({}; . * \$item) | $query" "${value_files[@]}"
  else
    yq -r -s "reduce .[] as \$item ({}; . * \$item) | $query" "${value_files[@]}"
  fi
}

domain="$(merged_value '.operator.domain')"
monitoring_enabled="$(merged_value '.monitoring.enabled')"
workflow_label="$(merged_value '.operator.subdomains.workflow')"
if [[ -n "$workflow_label" ]]; then
  workflow_host="${workflow_label}.${domain}"
else
  workflow_host="$domain"
fi

if [[ "$monitoring_enabled" == "true" ]]; then
  monitoring_chart="$(find charts -maxdepth 1 -name 'kube-prometheus-stack-*.tgz' -print -quit)"
  if [[ -z "$monitoring_chart" ]]; then
    echo "Missing bundled kube-prometheus-stack chart; run helm dependency update" >&2
    exit 1
  fi

  crd_dir="$(mktemp -d)"
  tar -xzf "$monitoring_chart" -C "$crd_dir"
  echo "Applying Prometheus Operator CRDs..."
  kubectl apply --server-side --force-conflicts \
    -f "$crd_dir/kube-prometheus-stack/charts/crds/crds"
  rm -rf "$crd_dir"
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

helm_value_args=()
for value_file in "${value_files[@]}"; do
  helm_value_args+=(-f "$value_file")
done

helm upgrade --install "$release" . \
  --namespace "$namespace" \
  "${helm_value_args[@]}" \
  --set-string nextcloud.skeleton.image.repository="$repository" \
  --set-string nextcloud.skeleton.image.tag="$tag" \
  --set-string workflowengine.windmill.baseDomain="$workflow_host" \
  --wait \
  --wait-for-jobs \
  --timeout 20m
