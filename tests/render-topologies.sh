#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

query() {
  local expression="$1"
  local file="$2"
  if yq --version 2>&1 | grep -q mikefarah; then
    yq ea -N "$expression" "$file"
  else
    yq -r -s "${expression/\[select(/\[.[] | select(}" "$file"
  fi
}

helm template nc-lab . -f values-test.yaml -f values-poc.yaml >"$tmpdir/poc.yaml"
helm template nc-lab . -f values-prod.yaml \
  --set nextcloud.autoscaling.enabled=true >"$tmpdir/prod.yaml"
helm template nc-lab . -f values-test.yaml \
  --set mariadb.replicas=3 \
  --set redis.replicas=1 \
  --set fulltextsearch.elasticsearch.replicas=1 >"$tmpdir/mixed.yaml"
helm template nc-lab . -f values-prod.yaml \
  --set fulltextsearch.elasticsearch.scheduling.zoneSpread.whenUnsatisfiable=DoNotSchedule >"$tmpdir/zoned.yaml"

[[ "$(query '[select(.kind == "MariaDB") | .spec.galera.enabled] | .[0]' "$tmpdir/poc.yaml")" == false ]]
[[ "$(query '[select(.kind == "Elasticsearch") | .spec.nodeSets[0].count] | .[0]' "$tmpdir/poc.yaml")" == 1 ]]
[[ "$(query '[select(.kind == "StatefulSet" and .metadata.name == "nc-lab-nextcloud-stack-redis") | .spec.template.spec.containers | length] | .[0]' "$tmpdir/poc.yaml")" == 1 ]]
[[ "$(query '[select(.kind == "Deployment" and .metadata.name == "nc-lab-nextcloud-stack-redis-proxy")] | length' "$tmpdir/poc.yaml")" == 0 ]]
[[ "$(query '[select(.kind == "HorizontalPodAutoscaler")] | length' "$tmpdir/poc.yaml")" == 0 ]]
grep -q '"number_of_replicas":0' "$tmpdir/poc.yaml"

[[ "$(query '[select(.kind == "HorizontalPodAutoscaler") | .spec.minReplicas] | .[0]' "$tmpdir/prod.yaml")" == 2 ]]
[[ "$(query '[select(.kind == "PodDisruptionBudget" and .metadata.name == "nc-lab-nextcloud-stack-nextcloud")] | length' "$tmpdir/prod.yaml")" == 1 ]]
[[ "$(query '[select(.kind == "MariaDB") | .spec.topologySpreadConstraints | length] | .[0]' "$tmpdir/prod.yaml")" == 1 ]]
grep -q '"number_of_replicas":1' "$tmpdir/prod.yaml"

[[ "$(query '[select(.kind == "MariaDB") | .spec.galera.enabled] | .[0]' "$tmpdir/mixed.yaml")" == true ]]
[[ "$(query '[select(.kind == "Elasticsearch") | .spec.nodeSets[0].count] | .[0]' "$tmpdir/mixed.yaml")" == 1 ]]
[[ "$(query '[select(.kind == "Elasticsearch") | .spec.nodeSets[0].zoneAwareness.topologyKey] | .[0]' "$tmpdir/zoned.yaml")" == topology.kubernetes.io/zone ]]

if helm template nc-lab . -f values-test.yaml \
  --set nextcloud.autoscaling.enabled=true >"$tmpdir/invalid.yaml" 2>/dev/null; then
  echo "Expected HPA on RWO storage to fail" >&2
  exit 1
fi

echo "Topology render checks passed"
