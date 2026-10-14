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
{{- if .Values.operator.ldap.baseDn -}}
{{- .Values.operator.ldap.baseDn -}}
{{- else -}}
{{- $rdns := list -}}
{{- range (splitList "." (include "nextcloud-stack.domain" .)) -}}
{{- $rdns = append $rdns (printf "dc=%s" .) -}}
{{- end -}}
{{- join "," $rdns -}}
{{- end -}}
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
