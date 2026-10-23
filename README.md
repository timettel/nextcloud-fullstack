# Nextcloud Stack

Opinionated Helm chart for a highly integrated Nextcloud deployment on
Kubernetes. The chart combines Nextcloud with clustered data services,
collaboration backends, centralized identity, mail and operational bootstrap
jobs.

## Included Components

- Nextcloud with configurable web replicas, optional HPA, Redis-backed sessions and background jobs
- MariaDB standalone or Galera, managed by mariadb-operator
- Redis standalone or Sentinel with HAProxy
- Elasticsearch standalone or clustered, managed by ECK
- EuroOffice, Full Text Search, notify_push, ClamAV and Whiteboard
- Talk HPB, Coturn and Talk Recording
- AppAPI HaRP and the Windmill workflow engine
- embedded LLDAP or an external LDAP/AD, Keycloak, Postfix/Dovecot, Roundcube
  and phpMyAdmin
- optional Checkmk Kubernetes Cluster and Node Collectors
- Gateway API routes and cert-manager certificates for all HTTP endpoints

Every optional module has an `enabled` switch in its component section. The
bootstrap jobs reconcile Nextcloud applications and integration settings after
installations and upgrades.

## Prerequisites

- Kubernetes with Gateway API CRDs
- a GatewayClass matching `gateway.className` (default: `traefik`)
- a LoadBalancer implementation supporting the TCP and UDP Services described
  below
- cert-manager
- mariadb-operator and its CRDs
- Elastic Cloud on Kubernetes (ECK)
- Helm and either the Go or Python/jq implementation of `yq`
- Docker for building the managed Nextcloud skeleton image
- a default StorageClass; production additionally needs RWX storage for the
  shared Nextcloud application volume

The Windmill dependency is pinned in `Chart.lock`. Run `helm dependency build`
when `charts/` is absent.

### k3s

The bundled Traefik controller in k3s does not enable its Gateway API provider
by default. Create `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`
on the server node before deploying the chart:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
```

Wait until `kubectl get gatewayclass traefik` reports `Accepted=True`. No k3s
port mapping is otherwise required. The default k3s ServiceLB implements
`LoadBalancer` Services by reserving the corresponding host ports on cluster
nodes. Consequently, every published port must be free on at least one node.
When ServiceLB is disabled, provide another implementation such as MetalLB or
an external load balancer.

## Operator Configuration

The first block in `values.yaml`, `operator`, is the supported operator-facing
configuration surface. It contains:

- `domain`: DNS zone and mail domain
- `publicIp`: node-local or directly routed address advertised by Coturn
- `subdomains`: endpoint labels below the DNS zone
- `admins`: the three deliberately managed recovery credentials
- `session`: shared idle, maximum and OIDC token lifetimes for the web clients
- `ldap.baseDn`: optional embedded-LLDAP base DN override
- `optionalSecrets`: internal secret overrides, normally left empty

With the default embedded directory, only these passwords must be supplied
explicitly:

- `operator.admins.nextcloud.password`
- `operator.admins.ldap.password`
- `operator.admins.keycloak.password`

External directory mode does not use `operator.admins.ldap`. It additionally
requires either an inline bind password in the ignored `values-local.yaml` or a
reference to an existing Kubernetes Secret.

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

## Identity Directory

An LDAP directory is mandatory because Nextcloud, Keycloak and the optional
mail service share the same identities. `identityDirectory.mode` selects its
source:

- `embedded` deploys and bootstraps LLDAP inside the release. This is the
  default and preserves the reference deployment's current behavior.
- `external` omits LLDAP and connects all consumers to an existing directory.

External mode supports `activeDirectory`, `openLdap` and `custom` schema
profiles. The first two supply conventional object classes and attribute
mappings. Every generated mapping and filter remains independently
overridable under `external.attributes` and `external.filters`. Ready-to-edit
overlays are included in `examples/values-external-ad.yaml` and
`examples/values-external-openldap.yaml`.

### Active Directory

Put deployment-specific and sensitive values in `values-local.yaml`:

```yaml
identityDirectory:
  mode: external
  groups:
    users: nc-users
    admins: nc-admin
  external:
    schema: activeDirectory
    host: dc01.example.com
    port: 636
    security: ldaps
    baseDn: DC=example,DC=com
    usersDn: OU=Users,DC=example,DC=com
    groupsDn: OU=Groups,DC=example,DC=com
    bind:
      dn: CN=svc-nextcloud,OU=Service Accounts,DC=example,DC=com
      existingSecret:
        name: nextcloud-external-ldap
        key: bind-password
    trustedCa:
      secretName: example-directory-ca
      key: ca.crt
```

Create referenced Secrets in the release namespace before running Helm:

```bash
kubectl -n nextcloud create secret generic nextcloud-external-ldap \
  --from-literal=bind-password='REPLACE_ME'
kubectl -n nextcloud create secret generic example-directory-ca \
  --from-file=ca.crt=company-directory-ca.pem
```

Omit `trustedCa` when the LDAP server certificate chains to a CA already trusted
by the application images. `plain`, `starttls` and `ldaps` are accepted security
modes; production directories should use StartTLS or LDAPS.

### OpenLDAP

The OpenLDAP preset expects `inetOrgPerson` users, `groupOfNames` groups,
`entryUUID`, `uid`, `mail` and a working `memberOf` overlay:

```yaml
identityDirectory:
  mode: external
  external:
    schema: openLdap
    host: ldap.example.com
    port: 636
    security: ldaps
    baseDn: dc=example,dc=com
    usersDn: ou=people,dc=example,dc=com
    groupsDn: ou=groups,dc=example,dc=com
    bind:
      dn: uid=svc-nextcloud,ou=people,dc=example,dc=com
      existingSecret:
        name: nextcloud-external-ldap
        key: bind-password
```

Use `external.filters` when the directory has no `memberOf` overlay, uses nested
groups, or should restrict users differently. Set `schema: custom` and provide
all entries below `external.attributes` for another LDAP schema. Set
`external.groupDns.users` or `external.groupDns.admins` when either group is not
a direct child of `groupsDn`.

The users and administrators groups must already exist in an external
directory. The bind identity needs read access to users, groups and membership
attributes. Users require a unique login attribute and, when mail is enabled, a
unique `mail` attribute in `operator.domain`. Dovecot verifies passwords using
LDAP bind, so password hashes do not need to be readable.

On install and upgrade, an external-directory preflight hook verifies DNS/TLS,
bind credentials and both search bases before Keycloak and Nextcloud are
reconciled. Keycloak federation remains read-only. Switching an established
deployment between embedded and external directories changes identity IDs and
must be treated as an identity migration, not as an in-place account rename.

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
- `turn.<domain>`: TURN over UDP on `talk.turnPort` (443 by default)
- `mail.<domain>`: SMTP, IMAPS and ManageSieve

The mail service also requires the appropriate MX, SPF, DKIM and DMARC records.

HTTP endpoints use Gateway API and do not expose a separate Service for every
hostname. Mail and TURN are Layer-4 services outside that Gateway:

| Component | Service | Required external ports |
| --- | --- | --- |
| Traefik Gateway | `LoadBalancer` | TCP 80 and 443 |
| Coturn listener | `LoadBalancer` | UDP `talk.turnPort` (default 443) |
| Coturn media relay | `hostNetwork` | UDP `talk.relayPortMin` through `talk.relayPortMax` |
| Postfix/Dovecot | `mail.service.type` | TCP 25, 465, 587 and 993; optionally 4190 |

The cluster must provide a `LoadBalancer` implementation for both TCP and UDP.
An `EXTERNAL-IP` remaining `pending`, or an implementation that supports TCP
only, requires a cloud load balancer, MetalLB or equivalent cluster-specific
configuration. Firewalls and cloud security groups must allow the same ports.
Using UDP 443 for TURN does not conflict with the HTTPS listener on TCP 443.

The bundled Coturn deployment currently targets bare-metal and self-managed
clusters: it uses `hostNetwork`, binds `operator.publicIp` directly and exposes
the relay range from its scheduled node. That address must therefore exist on,
or be routed directly to, the node running Coturn. This works on the single-node
k3s reference deployment without additional k3s configuration. A multi-node or
managed-cloud deployment should dedicate and select a TURN node with the public
address, or use an external TURN service. The chart currently publishes TURN
over UDP only; TCP/TLS TURN on port 443 would require a separate public address
or a compatible Layer-4 multiplexer because Traefik already owns TCP 443.

Before exposing the installation, verify the assignments and listeners:

```bash
kubectl get gatewayclass,gateway -A
kubectl get service -A | grep LoadBalancer
kubectl get pods -A -l svccontroller.k3s.cattle.io/svcname
```

The final command is specific to the built-in k3s ServiceLB and may return no
objects on other Kubernetes distributions.

## Monitoring

`monitoring.enabled` installs Prometheus Operator, Prometheus, Alertmanager,
Grafana, kube-state-metrics and node-exporter. Grafana authenticates directly
against Keycloak; by default, only members of
`identityDirectory.groups.admins` are admitted and receive the Grafana
administrator role. `monitoring.integration.allowedGroup` can override it.

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

For a smaller integration installation, add `values-poc.yaml` after the test
profile. It sets Nextcloud, MariaDB, Redis and Elasticsearch to one replica and
disables monitoring, workflow, Talk, mail, Roundcube, phpMyAdmin, Whiteboard
and ClamAV. Identity, Office and full-text search remain available. These are
independent overrides: any component can be restored to its clustered count
without changing the others.

```bash
helm lint . -f values-test.yaml -f values-poc.yaml
VALUES_OVERLAY=values-poc.yaml DEPLOYMENT_PROFILE=test ./deploy.sh
```

For existing installations, inspect the proposed diff before changing a
stateful service between standalone and clustered modes. A fresh POC release
with new PVCs is the simplest route; do not use this overlay to convert an
existing Galera database in place.

Production therefore requires at least three schedulable nodes for MariaDB,
Redis and Elasticsearch, plus a StorageClass capable of RWX volumes.

## Cluster Sizing

Set `mariadb.replicas`, `redis.replicas` and
`fulltextsearch.elasticsearch.replicas` independently to `1` for standalone
operation. MariaDB then omits Galera; Redis omits Sentinel and HAProxy while
keeping its Service name; Elasticsearch runs as a single node, and the
Nextcloud search index uses zero replicas. The defaults remain three nodes per
component. Values of two are rejected; three or more enable clustered mode.

MariaDB, Redis and the default Elasticsearch node set accept any clustered
replica count of at least three. Odd counts are recommended because an even count does not
normally add failure tolerance over the preceding odd count. In the production
profile, required pod anti-affinity places replicas of the same component on
distinct Kubernetes nodes. Dynamic volume provisioning creates one PVC per
stateful replica.

The test profile permits co-location but does not implicitly change replica
counts. For a small deployment, set the desired component counts explicitly. Switching
an existing Galera deployment to standalone, or vice versa, changes database
topology and must not be treated as an ordinary in-place Helm upgrade. Redeploy
with fresh volumes or perform a planned data migration. The same caution applies
to changing an existing Redis HA deployment to standalone. Changing an existing
Elasticsearch cluster's node count requires planning data placement separately.
The Nextcloud full-text index replica count is reconciled on each bootstrap:
`fulltextsearch.elasticsearch.indexReplicas: -1` derives zero for a single
node and one for multiple nodes. Set an explicit count from zero through
`elasticsearch.replicas - 1` to override it.

### Web scaling and storage

`nextcloud.replicas` controls a fixed web Pod count. Set
`nextcloud.autoscaling.enabled: true` for CPU-based HPA instead; then
`minReplicas`, `maxReplicas` and `targetCPUUtilizationPercentage` control
scaling. CPU requests are required for this metric. With HPA above one Pod,
Redis-backed PHP sessions and `ReadWriteMany` storage are required. A
PodDisruptionBudget is created only when the fixed count or HPA minimum exceeds
one. The bootstrap and cron jobs remain single-instance.

The Nextcloud PVC holds application code, configuration and local app data. A
single web Pod can use `ReadWriteOnce`; the single-node test profile can also
co-locate fixed replicas on one RWO volume. Distributed web Pods need an RWX
StorageClass, even when `nextcloud.objectStore.enabled` puts user file content
in S3. Primary S3 is an installation-time decision, not an in-place migration
from filesystem-backed primary storage. PVC access mode is likewise not
changed safely by editing an existing claim.

### Failure domains

The production profile requires distinct nodes for clustered components and
enables optional zone spread for Nextcloud, MariaDB, Redis and Elasticsearch.
Zone spreading uses `topology.kubernetes.io/zone` and `ScheduleAnyway` by
default, so clusters without zone labels still schedule. On a suitably labeled
multi-zone cluster, use each component's `scheduling.zoneSpread` block with
`whenUnsatisfiable: DoNotSchedule` for strict balance across the zones Kubernetes
can see. For Elasticsearch this also enables ECK's native shard-allocation zone
awareness; it requires an ECK version whose CRD supports `zoneAwareness`.
MariaDB's operator and ECK manage their own disruption budgets; this chart
adds budgets for multi-replica Nextcloud and Redis. If you need to require a
specific number of zones, enforce that at the cluster/node-pool level too:
spread constraints alone do not create missing zones.

In clustered mode, Redis Sentinel derives its quorum automatically from `redis.replicas` using a
strict majority (`floor(replicas / 2) + 1`). Keep
`redis.sentinel.quorum: 0` for this behavior. An explicit value remains
available for unusual topologies and is validated against the replica count.

The following settings are intentionally not inferred from replica counts:

- CPU and memory requests or limits
- Galera buffer sizes and replication threads
- Elasticsearch shard counts
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

The effective values order is `values.yaml`, `values-<profile>.yaml`, optional
`VALUES_OVERLAY`, then the ignored `values-local.yaml` if present.

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
tests/render-topologies.sh
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

The selected embedded or external LDAP directory is authoritative. Nextcloud
authenticates directly against it; Keycloak federates the same users and groups
for OIDC clients.

- `identityDirectory.groups.users` permits Nextcloud login
- `identityDirectory.groups.admins` maps to Nextcloud administrators
- phpMyAdmin and Grafana admit the configured administrators group by default
- Roundcube uses Keycloak OIDC and XOAUTH2 for IMAP/SMTP

Local Nextcloud recovery login remains available at:

```text
https://nc.<domain>/login?direct=1
```

Embedded mode manages the LDAP bind account and mail service account
automatically. External mode expects its bind identity and both configured
groups to exist. The Dovecot master account remains stack-managed in both
modes.

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
