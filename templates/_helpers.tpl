{{- define "nextcloud-stack.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "nextcloud-stack.hstsFilter" -}}
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
      - name: Strict-Transport-Security
        value: {{ printf "max-age=%d%s" (int .Values.nextcloud.hsts.maxAge) (ternary "; includeSubDomains" "" .Values.nextcloud.hsts.includeSubDomains) | quote }}
{{- end -}}

{{- define "nextcloud-stack.domain" -}}
{{- required "operator.domain is required" .Values.operator.domain | trimSuffix "." -}}
{{- end -}}

{{- define "nextcloud-stack.host" -}}
{{- $root := index . 0 -}}
{{- $endpoint := index . 1 -}}
{{- $domain := include "nextcloud-stack.domain" $root -}}
{{- $label := required (printf "operator.subdomains.%s is required" $endpoint) (index $root.Values.operator.subdomains $endpoint) -}}
{{- if empty $label -}}
{{- $domain -}}
{{- else -}}
{{- printf "%s.%s" ($label | trimSuffix ".") $domain -}}
{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapBaseDn" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "external" -}}
{{- required "identityDirectory.external.baseDn is required in external mode" .Values.identityDirectory.external.baseDn -}}
{{- else if .Values.operator.ldap.baseDn -}}
{{- .Values.operator.ldap.baseDn -}}
{{- else -}}
{{- $rdns := list -}}
{{- range (splitList "." (include "nextcloud-stack.domain" .)) -}}
{{- $rdns = append $rdns (printf "dc=%s" .) -}}
{{- end -}}
{{- join "," $rdns -}}
{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.identityMode" -}}
{{- $mode := required "identityDirectory.mode is required (embedded or external)" .Values.identityDirectory.mode -}}
{{- if not (has $mode (list "embedded" "external")) -}}
{{- fail "identityDirectory.mode must be embedded or external" -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{- define "nextcloud-stack.externalSchema" -}}
{{- $schema := required "identityDirectory.external.schema is required in external mode" .Values.identityDirectory.external.schema -}}
{{- if not (has $schema (list "activeDirectory" "openLdap" "custom")) -}}
{{- fail "identityDirectory.external.schema must be activeDirectory, openLdap or custom" -}}
{{- end -}}
{{- $schema -}}
{{- end -}}

{{- define "nextcloud-stack.ldapUri" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "embedded" -}}
{{- printf "ldaps://%s-lldap" (include "nextcloud-stack.fullname" .) -}}
{{- else -}}
{{- $security := required "identityDirectory.external.security is required" .Values.identityDirectory.external.security -}}
{{- if not (has $security (list "plain" "starttls" "ldaps")) -}}
{{- fail "identityDirectory.external.security must be plain, starttls or ldaps" -}}
{{- end -}}
{{- printf "%s://%s" (ternary "ldaps" "ldap" (eq $security "ldaps")) (required "identityDirectory.external.host is required" .Values.identityDirectory.external.host) -}}
{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapPort" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "embedded" -}}6360{{- else -}}{{ required "identityDirectory.external.port is required" .Values.identityDirectory.external.port }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapUsersDn" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "embedded" -}}{{ printf "ou=people,%s" (include "nextcloud-stack.ldapBaseDn" .) }}{{- else -}}{{ default (include "nextcloud-stack.ldapBaseDn" .) .Values.identityDirectory.external.usersDn }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapGroupsDn" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "embedded" -}}{{ printf "ou=groups,%s" (include "nextcloud-stack.ldapBaseDn" .) }}{{- else -}}{{ default (include "nextcloud-stack.ldapBaseDn" .) .Values.identityDirectory.external.groupsDn }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapBindDn" -}}
{{- if eq (include "nextcloud-stack.identityMode" .) "embedded" -}}{{ printf "uid=%s,%s" .Values.identityDirectory.embedded.bindAccount.username (include "nextcloud-stack.ldapUsersDn" .) }}{{- else -}}{{ required "identityDirectory.external.bind.dn is required" .Values.identityDirectory.external.bind.dn }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapBindSecretName" -}}
{{- if and (eq (include "nextcloud-stack.identityMode" .) "external") .Values.identityDirectory.external.bind.existingSecret.name -}}{{ .Values.identityDirectory.external.bind.existingSecret.name }}{{- else -}}{{ include "nextcloud-stack.fullname" . }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapBindSecretKey" -}}
{{- if and (eq (include "nextcloud-stack.identityMode" .) "external") .Values.identityDirectory.external.bind.existingSecret.name -}}{{ required "identityDirectory.external.bind.existingSecret.key is required" .Values.identityDirectory.external.bind.existingSecret.key }}{{- else -}}ldap-bind-password{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapAttribute" -}}
{{- $root := index . 0 -}}{{- $name := index . 1 -}}{{- $embedded := index . 2 -}}{{- $ad := index . 3 -}}{{- $openldap := index . 4 -}}
{{- if eq (include "nextcloud-stack.identityMode" $root) "embedded" -}}{{ $embedded }}{{- else -}}
{{- $override := index $root.Values.identityDirectory.external.attributes $name -}}
{{- if $override -}}{{ $override }}{{- else -}}
{{- $schema := include "nextcloud-stack.externalSchema" $root -}}
{{- if eq $schema "activeDirectory" -}}{{ $ad }}{{- else if eq $schema "openLdap" -}}{{ $openldap }}{{- else -}}{{ required (printf "identityDirectory.external.attributes.%s is required for custom schema" $name) $override }}{{- end -}}
{{- end -}}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapUsernameAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "username" "uid" "sAMAccountName" "uid") }}{{- end -}}
{{- define "nextcloud-stack.ldapRdnAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "rdn" "uid" "cn" "uid") }}{{- end -}}
{{- define "nextcloud-stack.ldapUuidAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "uuid" "uid" "objectGUID" "entryUUID") }}{{- end -}}
{{- define "nextcloud-stack.ldapUserObjectClass" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "userObjectClass" "person" "user" "inetOrgPerson") }}{{- end -}}
{{- define "nextcloud-stack.ldapDisplayNameAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "displayName" "displayName" "displayName" "displayName") }}{{- end -}}
{{- define "nextcloud-stack.ldapFirstNameAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "firstName" "givenName" "givenName" "givenName") }}{{- end -}}
{{- define "nextcloud-stack.ldapLastNameAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "lastName" "sn" "sn" "sn") }}{{- end -}}
{{- define "nextcloud-stack.ldapEmailAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "email" "mail" "mail" "mail") }}{{- end -}}
{{- define "nextcloud-stack.ldapGroupObjectClass" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "groupObjectClass" "groupOfUniqueNames" "group" "groupOfNames") }}{{- end -}}
{{- define "nextcloud-stack.ldapGroupNameAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "groupName" "cn" "cn" "cn") }}{{- end -}}
{{- define "nextcloud-stack.ldapGroupMembershipAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "groupMembership" "uniqueMember" "member" "member") }}{{- end -}}
{{- define "nextcloud-stack.ldapGroupMembershipUserAttr" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "groupMembershipUser" "uid" "sAMAccountName" "uid") }}{{- end -}}
{{- define "nextcloud-stack.ldapGroupMembershipType" -}}{{ include "nextcloud-stack.ldapAttribute" (list . "groupMembershipType" "DN" "DN" "DN") }}{{- end -}}

{{- define "nextcloud-stack.ldapUserGroupDn" -}}{{ if and (eq (include "nextcloud-stack.identityMode" .) "external") .Values.identityDirectory.external.groupDns.users }}{{ .Values.identityDirectory.external.groupDns.users }}{{ else }}{{ printf "%s=%s,%s" (include "nextcloud-stack.ldapGroupNameAttr" .) .Values.identityDirectory.groups.users (include "nextcloud-stack.ldapGroupsDn" .) }}{{ end }}{{- end -}}
{{- define "nextcloud-stack.ldapAdminGroupDn" -}}{{ if and (eq (include "nextcloud-stack.identityMode" .) "external") .Values.identityDirectory.external.groupDns.admins }}{{ .Values.identityDirectory.external.groupDns.admins }}{{ else }}{{ printf "%s=%s,%s" (include "nextcloud-stack.ldapGroupNameAttr" .) .Values.identityDirectory.groups.admins (include "nextcloud-stack.ldapGroupsDn" .) }}{{ end }}{{- end -}}

{{- define "nextcloud-stack.groupWhitelistRegex" -}}
{{- if .Values.keycloak.groupWhitelistRegex -}}{{ .Values.keycloak.groupWhitelistRegex }}{{- else -}}{{ printf "/^(%s|%s)$/" (regexQuoteMeta .Values.identityDirectory.groups.users) (regexQuoteMeta .Values.identityDirectory.groups.admins) }}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.ldapFilter" -}}
{{- $root := index . 0 -}}{{- $name := index . 1 -}}{{- $override := "" -}}
{{- if eq (include "nextcloud-stack.identityMode" $root) "external" -}}{{- $override = index $root.Values.identityDirectory.external.filters $name -}}{{- end -}}
{{- if $override -}}{{ $override }}{{- else -}}
{{- $class := include "nextcloud-stack.ldapUserObjectClass" $root -}}{{- $userGroup := include "nextcloud-stack.ldapUserGroupDn" $root -}}{{- $username := include "nextcloud-stack.ldapUsernameAttr" $root -}}{{- $mail := include "nextcloud-stack.ldapEmailAttr" $root -}}
{{- if eq $name "users" -}}{{ printf "(&(objectClass=%s)(memberOf=%s))" $class $userGroup }}
{{- else if eq $name "login" -}}{{ printf "(&(objectClass=%s)(memberOf=%s)(|(%s=%%uid)(%s=%%uid)))" $class $userGroup $username $mail }}
{{- else if eq $name "groups" -}}{{ printf "(&(objectClass=%s)(|(%s=%s)(%s=%s)))" (include "nextcloud-stack.ldapGroupObjectClass" $root) (include "nextcloud-stack.ldapGroupNameAttr" $root) $root.Values.identityDirectory.groups.users (include "nextcloud-stack.ldapGroupNameAttr" $root) $root.Values.identityDirectory.groups.admins }}
{{- else if eq $name "mailDomain" -}}{{ printf "(&(objectClass=%s)(memberOf=%s)(%s=*@%%s))" $class $userGroup $mail }}
{{- else if or (eq $name "mailUser") (eq $name "mailSender") -}}{{ printf "(&(objectClass=%s)(memberOf=%s)(%s=%%s))" $class $userGroup $mail }}
{{- else if or (eq $name "dovecotUser") (eq $name "dovecotPass") -}}{{ printf "(&(objectClass=%s)(memberOf=%s)(|(%s=%%{user | username})(%s=%%{user})))" $class $userGroup $username $mail }}
{{- end -}}{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "nextcloud-stack.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nextcloud-stack.phpmyadminHost" -}}
{{- include "nextcloud-stack.host" (list . "phpmyadmin") -}}
{{- end -}}

{{- define "nextcloud-stack.checkmkFullname" -}}
{{- if .Values.checkmk.fullnameOverride -}}
{{- .Values.checkmk.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "checkmk" .Values.checkmk.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "nextcloud-stack.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: {{ include "nextcloud-stack.name" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{- define "nextcloud-stack.exappsNamespace" -}}
{{- default (printf "%s-exapps" (include "nextcloud-stack.fullname" .) | trunc 63 | trimSuffix "-") .Values.appApi.exappsNamespace -}}
{{- end -}}

{{- define "nextcloud-stack.waitForDataStores" -}}
- name: wait-for-datastores
  image: "{{ .Values.nextcloud.image.repository }}:{{ .Values.nextcloud.image.tag }}"
  imagePullPolicy: {{ .Values.nextcloud.image.pullPolicy }}
  command: [/bin/sh, -c]
  args:
    - |
      set -eu
      echo "Waiting for MariaDB/Galera..."
      until php -r '
        try {
          $db = new PDO(
            "mysql:host=" . getenv("MYSQL_HOST") . ";dbname=" . getenv("MYSQL_DATABASE"),
            getenv("MYSQL_USER"),
            getenv("MYSQL_PASSWORD"),
            [PDO::ATTR_TIMEOUT => 2]
          );
          $db->query("SELECT 1");
        } catch (Throwable $e) {
          exit(1);
        }
      '; do
        sleep 5
      done

      echo "Waiting for Redis..."
      until php -r '
        try {
          $redis = new Redis();
          $redis->connect(getenv("REDIS_HOST"), 6379, 2);
          $redis->auth(getenv("REDIS_PASSWORD"));
          $redis->ping();
        } catch (Throwable $e) {
          exit(1);
        }
      '; do
        sleep 5
      done
      echo "MariaDB/Galera and Redis are ready"
  env:
    - name: MYSQL_HOST
      value: {{ include "nextcloud-stack.fullname" . }}-mariadb
    - name: MYSQL_DATABASE
      value: {{ .Values.mariadb.database | quote }}
    - name: MYSQL_USER
      value: {{ .Values.mariadb.username | quote }}
    - name: MYSQL_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "nextcloud-stack.fullname" . }}
          key: mariadb-password
    - name: REDIS_HOST
      value: {{ include "nextcloud-stack.fullname" . }}-redis
    - name: REDIS_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "nextcloud-stack.fullname" . }}
          key: redis-password
  resources:
    {{- toYaml .Values.helperResources | nindent 4 }}
{{- end -}}

{{- define "nextcloud-stack.waitForNextcloud" -}}
- name: wait-for-nextcloud
  image: "{{ .Values.nextcloud.image.repository }}:{{ .Values.nextcloud.image.tag }}"
  imagePullPolicy: {{ .Values.nextcloud.image.pullPolicy }}
  command: [/bin/sh, -c]
  args:
    - |
      set -eu
      echo "Waiting for Nextcloud..."
      until curl -fsS --max-time 3 \
        -H "Host: {{ (include "nextcloud-stack.host" (list . "nextcloud")) }}" \
        "http://{{ include "nextcloud-stack.fullname" . }}-nextcloud/status.php" \
        | grep -q '"installed":true'; do
        sleep 5
      done
      echo "Nextcloud is ready"
  resources:
    {{- toYaml .Values.helperResources | nindent 4 }}
{{- end -}}

{{/* Strict majority for quorum-based components: floor(n / 2) + 1. */}}
{{- define "nextcloud-stack.majority" -}}
{{- add (div (int .) 2) 1 -}}
{{- end -}}
