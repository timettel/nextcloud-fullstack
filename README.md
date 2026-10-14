# Nextcloud Stack

Opinionated Helm chart for a highly integrated Nextcloud deployment on
Kubernetes. The chart combines Nextcloud with clustered data services,
collaboration backends, centralized identity, mail and operational bootstrap
jobs.

## Included Components

- Nextcloud with two web replicas, Redis-backed sessions and background jobs
- MariaDB Galera with three members, managed by mariadb-operator
- Redis Sentinel with three members and HAProxy
- Elasticsearch with three members, managed by ECK
- EuroOffice, Full Text Search, notify_push, ClamAV and Whiteboard
- Talk HPB, Coturn and Talk Recording
- AppAPI HaRP and the Windmill workflow engine
- LLDAP, Keycloak, Postfix/Dovecot, Roundcube and phpMyAdmin
- optional Checkmk Kubernetes Cluster and Node Collectors
- Gateway API routes and cert-manager certificates for all HTTP endpoints

Every optional module has an `enabled` switch in its component section. The
bootstrap jobs reconcile Nextcloud applications and integration settings after
installations and upgrades.

## Prerequisites

- Kubernetes with Gateway API CRDs
- a GatewayClass matching `gateway.className` (default: `traefik`)
- cert-manager
- mariadb-operator and its CRDs
- Elastic Cloud on Kubernetes (ECK)
- Helm and either the Go or Python/jq implementation of `yq`
- Docker for building the managed Nextcloud skeleton image
- a default StorageClass; production additionally needs RWX storage for the
  shared Nextcloud application volume

The Windmill dependency is pinned in `Chart.lock`. Run `helm dependency build`
when `charts/` is absent.

## Operator Configuration

The first block in `values.yaml`, `operator`, is the supported operator-facing
configuration surface. It contains:

- `domain`: DNS zone and mail domain
- `publicIp`: address advertised by Coturn
- `subdomains`: endpoint labels below the DNS zone
- `admins`: the three deliberately managed recovery credentials
- `ldap.baseDn`: optional override; empty derives the DN from `domain`
- `optionalSecrets`: internal secret overrides, normally left empty

Only these passwords must be supplied explicitly:

- `operator.admins.nextcloud.password`
- `operator.admins.ldap.password`
- `operator.admins.keycloak.password`

The repository ships with `CHANGE_ME` placeholders. After inserting real
credentials, put deployment-specific overrides in the ignored
`values-local.yaml`. `deploy.sh` loads it after the selected deployment profile,
so it can override both shared defaults and profile values without modifying
tracked files. Treat this file as sensitive and include it in the host's secure
configuration backup.

MariaDB, Redis, Talk, Office, OIDC and other internal credentials are generated
with cryptographically random values when their override is empty. Existing
values are retained across upgrades through Helm `lookup()`. Setting an
optional override intentionally rotates that credential.

Component sections below `operator` contain feature switches, image versions,
storage sizes, resources and advanced integration settings. They are valid
operator controls, but do not normally need editing for a standard deployment.

## DNS and Network

Create records for the configured subdomains or provide a wildcard record for
`*.operator.domain`. With the default labels the public endpoints are:

- `nc.<domain>`: Nextcloud
- `office.<domain>`: EuroOffice
- `auth.<domain>`: Keycloak
- `ldap.<domain>`: LLDAP UI
- `webmail.<domain>`: Roundcube
- `db.<domain>`: phpMyAdmin
- `grafana.<domain>`: Grafana monitoring
- `windmill.<domain>`: Windmill
- `talk.<domain>` and `recording.<domain>`: Talk backends
- `turn.<domain>`: TURN UDP/TLS on port 443
- `mail.<domain>`: SMTP, IMAPS and ManageSieve

The mail service also requires the appropriate MX, SPF, DKIM and DMARC records.
Expose the configured Talk relay range and the mail service ports according to
the cluster's LoadBalancer implementation and firewall policy.

## Monitoring

`monitoring.enabled` installs Prometheus Operator, Prometheus, Alertmanager,
Grafana, kube-state-metrics and node-exporter. Grafana authenticates directly
against Keycloak; only members of `monitoring.integration.allowedGroup`
(`nc-admin` by default) are admitted and receive the Grafana administrator
role.

`deploy.sh` applies the bundled Prometheus Operator CRDs before Helm. This
handles both adding monitoring to an existing release and future CRD schema
updates without a separate manual `kubectl apply` step.

The bundled overview dashboard covers pod readiness, restarts and OOM kills,
CPU, memory, throttling, PVC requests, public endpoint latency and TLS
certificate lifetime. The upstream Kubernetes dashboards and alert rules remain
available alongside it. Prometheus retains 15 days in a 30 GiB PVC by default;
Grafana and Alertmanager use separate 5 GiB and 2 GiB PVCs.

HTTP/TLS probes are provided by the bundled blackbox exporter. Alertmanager
sends firing and resolved notifications to `monitoring.integration.alertEmail`
through the stack's mail service. Set `monitoring.enabled: false` to omit the
complete monitoring subsystem, or disable only
`monitoring.blackboxExporter.enabled` or `monitoring.alertmanager.enabled`.

### Checkmk

`checkmk.enabled` installs the official Checkmk Kubernetes Cluster Collector
and Node Collectors. It does not install a Checkmk site: an existing external
Checkmk server queries the Kubernetes API and collector with the generated
service-account token. This keeps the deployment independent of Checkmk site,
edition, network topology and DNS conventions.

The collector service defaults to `ClusterIP`. Set
`checkmk.clusterCollector.service.type` to `NodePort` and configure
`nodePort`, or enable the upstream Ingress support, when the Checkmk server is
outside the cluster. Restrict access with
`checkmk.networkPolicy.allowIngressFromCIDRs` where the cluster network plugin
enforces NetworkPolicy. Set `checkmk.containerdOverride` for distributions
with a nonstandard socket; `values-test.yaml` supplies the k3s path.

After deployment, `helm get notes` prints commands for retrieving the token and
cluster CA. Configure a host without an IP address in Checkmk and assign the
Kubernetes special agent using:

- `checkmk.clusterName` as the cluster name
- the externally reachable Kubernetes API endpoint
- the generated service-account token and CA
- the externally reachable Cluster Collector endpoint

Checkmk Community includes the Kubernetes special agent and check plug-ins but
not Dynamic Host Management or the commercial Kubernetes dashboards. Cluster
services work normally. Object-level piggyback hosts must be created manually
or reconciled separately, for example by processing
`cmk-piggyback list orphans` on the Checkmk site.

For Checkmk Community sites, `scripts/checkmk-raw-piggyback-sync` provides this
reconciliation. Install it in the site's `local/bin` directory and run it as
the site user after configuring the Kubernetes special agent:

```bash
checkmk-raw-piggyback-sync <cluster-host> <cluster-name>
```

The script creates no-IP hosts for current Kubernetes piggyback objects,
discovers services for new objects and removes objects after Checkmk has aged
out their piggyback data. It activates Checkmk only when the generated host set
changes. A five-minute cron or systemd timer is suitable for ongoing use.

On cgroup v2 nodes, cAdvisor may also need direct access to the containerd
socket. Configure `checkmk.nodeCollector.cadvisor.containerdSocket` with the
runtime-specific socket path. The test profile includes the k3s path
`/run/k3s/containerd/containerd.sock`; standard Kubernetes installations
commonly use `/run/containerd/containerd.sock`.

## Deployment Profiles

Exactly one profile must be selected:

- `values-test.yaml`: permits co-location on a single node and uses RWO for the
  Nextcloud application volume
- `values-prod.yaml`: requires anti-affinity across nodes and uses RWX for the
  Nextcloud application volume

Production therefore requires at least three schedulable nodes for MariaDB,
Redis and Elasticsearch, plus a StorageClass capable of RWX volumes.

## Cluster Sizing

MariaDB, Redis and the default Elasticsearch node set accept any replica count
of at least three. Odd counts are recommended because an even count does not
normally add failure tolerance over the preceding odd count. In the production
profile, required pod anti-affinity places replicas of the same component on
distinct Kubernetes nodes. Dynamic volume provisioning creates one PVC per
stateful replica.

Redis Sentinel derives its quorum automatically from `redis.replicas` using a
strict majority (`floor(replicas / 2) + 1`). Keep
`redis.sentinel.quorum: 0` for this behavior. An explicit value remains
available for unusual topologies and is validated against the replica count.

The following settings are intentionally not inferred from replica counts:

- CPU and memory requests or limits
- Galera buffer sizes and replication threads
- Elasticsearch shard and index-replica counts
- Redis proxy replicas
- storage capacity per replica

Those values depend on workload, failure domains and the storage backend. For
larger Elasticsearch deployments, replace the combined master/data/ingest node
set with dedicated node sets rather than increasing it indefinitely.

ClamAV scan concurrency is controlled independently through
`clamav.maxThreads` and defaults to four. Size it together with the ClamAV CPU
and memory limits and the number of consumers. More worker threads improve
parallelism for simultaneous uploads and mail delivery, but do not create more
CPU capacity.

## Resource Tuning

Every workload exposes Kubernetes CPU and memory requests and limits in
`values.yaml`. Main containers use the component-level `resources` key, for
example:

```yaml
nextcloud:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "4"
      memory: 6Gi
```

Sidecars and helper jobs have named resource blocks below their owning
component, including `redis.sentinel.resources`,
`phpmyadmin.oauth2Proxy.resources`, `nextcloud.bootstrap.resources` and
`workflowengine.webhookWorkerResources`. Short-lived wait and configuration
containers share `helperResources`. Requests influence scheduling and reserved
capacity. CPU limits throttle excess use; exceeding a memory limit can
terminate the container with an OOM condition.

Put environment-specific overrides in the selected profile or in an additional
private `values-local.yaml` file. Applying them with `helm upgrade` updates the workload pod
templates and Kubernetes replaces the affected pods using their controller's
rollout strategy. Persistent volumes and application data are not recreated by
a resource-only change.

## Install and Upgrade

The supported entry point is `deploy.sh`. It builds the content of
`nc-skeleton/` as an OCI image, imports or publishes it, derives the Windmill
hostname from the operator block and runs the Helm upgrade.

```bash
DEPLOYMENT_PROFILE=test ./deploy.sh
```

The effective values order is `values.yaml`, `values-<profile>.yaml`, then the
optional ignored `values-local.yaml`.

Useful environment overrides:

```bash
HELM_RELEASE=nc-lab
HELM_NAMESPACE=nextcloud-lab
SKELETON_IMAGE_REPOSITORY=registry.example.net/nextcloud-skeleton
SKELETON_PUBLISH_MODE=local-k3s  # local-k3s, push or none
```

For production, publish the skeleton image to a registry available to every
node:

```bash
DEPLOYMENT_PROFILE=prod \
SKELETON_IMAGE_REPOSITORY=registry.example.net/nextcloud-skeleton \
SKELETON_PUBLISH_MODE=push \
./deploy.sh
```

Validate changes before an upgrade:

```bash
helm lint . -f values-test.yaml
helm template nc-lab . \
  --namespace nextcloud-lab \
  -f values-test.yaml \
  --set-string workflowengine.windmill.baseDomain=windmill.example.com \
  >/tmp/nextcloud-stack.yaml
kubectl apply --dry-run=server -f /tmp/nextcloud-stack.yaml
```

## Secret Lifecycle

Generated credentials are stored in the release Secret named
`<release>-nextcloud-stack`. Keep the release Secret and application data
together in backup and recovery procedures. Offline `helm template` rendering
cannot access existing Secrets and will show newly generated values; this does
not rotate credentials in a real `helm upgrade`.

Retrieve a generated value only when operationally required:

```bash
kubectl -n nextcloud-lab get secret nc-lab-nextcloud-stack \
  -o jsonpath='{.data.redis-password}' | base64 -d; echo
```

Windmill uses the separate `windmill-database` Secret. Its password is also
generated once and retained across upgrades.

## Identity and Access

LLDAP is the authoritative directory. Nextcloud authenticates directly against
LDAP; Keycloak federates the same users and groups for OIDC clients.

- `nc-users` permits Nextcloud login
- `nc-admin` maps to Nextcloud administrators
- phpMyAdmin's OAuth2 proxy admits only `nc-admin`
- Roundcube uses Keycloak OIDC and XOAUTH2 for IMAP/SMTP

Local Nextcloud recovery login remains available at:

```text
https://nc.<domain>/login?direct=1
```

The LDAP bind account, mail service account and Dovecot master account are
managed automatically and use generated credentials.

## Storage

Nextcloud's application/configuration volume is shared by its web replicas.
User files may use filesystem storage or S3 primary object storage.

`nextcloud.objectStore.enabled` is an installation-time decision. The startup
guard rejects enabling S3 on an existing filesystem-backed installation or
disabling it on an installed S3-backed instance. Configure the S3 endpoint and
bucket under `nextcloud.objectStore.s3`; put credentials in
`operator.optionalSecrets.s3AccessKey` and `s3SecretKey`.

The object prefix defaults to `<operator.domain>/urn:oid:` when left empty.

## Reconciliation and Upgrades

Post-install/post-upgrade jobs perform the following idempotent operations:

- database defaults, migrations, missing indices and selected repairs
- Nextcloud app installation, enablement and disablement
- LDAP, OIDC, mail, Office, Talk, Whiteboard, antivirus and search wiring
- Keycloak LDAP federation, clients and group mappers
- generated mail accounts and standard IMAP folders
- Windmill workspace and administrator bootstrap

Inspect hooks and workload status with:

```bash
kubectl -n nextcloud-lab get pods,jobs
kubectl -n nextcloud-lab get gateway,httproute,certificate
kubectl -n nextcloud-lab get events --sort-by=.lastTimestamp
```

## Module Dependencies

Relevant dependency constraints are validated during template rendering:

- Roundcube requires Mail and Keycloak
- phpMyAdmin in `keycloak` mode requires Keycloak
- Keycloak federation expects the identity directory
- Talk Recording requires Talk
- Full Text Search requires the ECK-managed Elasticsearch cluster
- Windmill uses its own PostgreSQL database, not the Nextcloud Galera cluster

Disabling a module removes its Kubernetes workloads and routes. Nextcloud apps
owned by that module are disabled where the bootstrap supports reconciliation;
persistent data is not automatically deleted.

## Uninstall

```bash
helm uninstall nc-lab --namespace nextcloud-lab
```

Operators must remove retained PVCs, object-storage data, DNS records and
cluster-scoped operators separately according to their retention policy.
