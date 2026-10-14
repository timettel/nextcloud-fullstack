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
- Helm and `yq`
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
credentials, treat the resulting values file as sensitive and keep it outside
version control or protect it through an equivalent deployment workflow.

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
- `windmill.<domain>`: Windmill
- `talk.<domain>` and `recording.<domain>`: Talk backends
- `turn.<domain>`: TURN UDP/TLS on port 443
- `mail.<domain>`: SMTP, IMAPS and ManageSieve

The mail service also requires the appropriate MX, SPF, DKIM and DMARC records.
Expose the configured Talk relay range and the mail service ports according to
the cluster's LoadBalancer implementation and firewall policy.

## Deployment Profiles

Exactly one profile must be selected:

- `values-test.yaml`: permits co-location on a single node and uses RWO for the
  Nextcloud application volume
- `values-prod.yaml`: requires anti-affinity across nodes and uses RWX for the
  Nextcloud application volume

Production therefore requires at least three schedulable nodes for MariaDB,
Redis and Elasticsearch, plus a StorageClass capable of RWX volumes.

## Install and Upgrade

The supported entry point is `deploy.sh`. It builds the content of
`nc-skeleton/` as an OCI image, imports or publishes it, derives the Windmill
hostname from the operator block and runs the Helm upgrade.

```bash
DEPLOYMENT_PROFILE=test ./deploy.sh
```

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
