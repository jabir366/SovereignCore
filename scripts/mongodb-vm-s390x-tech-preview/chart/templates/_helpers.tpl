{{/*
Expand the name of the chart.
*/}}
{{- define "mongodb-vm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
mongodb-vm.val — resolve a value that may arrive either as a proper nested path
(e.g. .Values.ha.enabled) or as a flat dot-notation top-level key
(e.g. index .Values "ha.enabled") when the broker passes overrides via helm.valuesObject.

Usage: {{ include "mongodb-vm.val" (list . "ha.enabled") }}

The nested path is always preferred; the flat key is the fallback.
This handles the BYOP broker helm-registry path which serialises overrides as
{"ha.enabled": true, "diskImage.sourceContainerDisk": "..."} — flat string keys,
not nested objects — inside helm.valuesObject.
*/}}
{{- define "mongodb-vm.val" -}}
{{- $ctx    := index . 0 -}}
{{- $dotKey := index . 1 -}}
{{- /* Flat top-level key takes priority (broker passes overrides as flat keys
       e.g. "ha.enabled", "diskImage.storageClassName").
       Only fall back to nested path walk when no flat key exists. */ -}}
{{- $flatVal := index $ctx.Values $dotKey -}}
{{- if not (kindIs "invalid" $flatVal) -}}
  {{- $flatVal -}}
{{- else -}}
  {{- /* Walk the nested path */ -}}
  {{- $parts  := splitList "." $dotKey -}}
  {{- $cur    := $ctx.Values -}}
  {{- $found  := true -}}
  {{- range $parts -}}
    {{- if $found -}}
      {{- $next := index $cur . -}}
      {{- if kindIs "invalid" $next -}}
        {{- $found = false -}}
      {{- else -}}
        {{- $cur = $next -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if and $found (not (kindIs "invalid" $cur)) -}}
    {{- $cur -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Create a default fully qualified app name (base, without member index).
*/}}
{{- define "mongodb-vm.fullname" -}}
{{- /* Broker passes instanceName as a flat key; chart values use instance.name nested. */ -}}
{{- $name := index .Values "instanceName" | default .Values.instance.name -}}
{{- if $name }}
{{- $name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Per-member VM name  — called with a dict: (dict "Values" .Values "Chart" .Chart "Release" .Release "index" $i)
Standalone:  <fullname>
HA member:   <fullname>-<index>   e.g. my-instance-0
*/}}
{{- define "mongodb-vm.memberName" -}}
{{- $base := include "mongodb-vm.fullname" . -}}
{{- if include "mongodb-vm.val" (list . "ha.enabled") | eq "true" -}}
{{- printf "%s-%d" $base (int .index) | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- $base }}
{{- end }}
{{- end }}

{{/*
Per-member DataVolume name.
Standalone:  <fullname>-disk
HA member:   <fullname>-<index>-disk
*/}}
{{- define "mongodb-vm.memberDvName" -}}
{{- $base := include "mongodb-vm.fullname" . -}}
{{- if include "mongodb-vm.val" (list . "ha.enabled") | eq "true" -}}
{{- printf "%s-%d-disk" $base (int .index) | trunc 63 | trimSuffix "-" }}
{{- else -}}
{{- printf "%s-disk" $base }}
{{- end }}
{{- end }}

{{/*
DataVolume name — legacy helper kept for backward compatibility (standalone path).
*/}}
{{- define "mongodb-vm.dvName" -}}
{{ include "mongodb-vm.fullname" . }}-disk
{{- end }}

{{/*
Headless service name (HA only) — used as the DNS domain for replica-set member discovery.
Members are reachable at <memberName>.<headlessSvcName>.<namespace>.svc.cluster.local
*/}}
{{- define "mongodb-vm.headlessSvcName" -}}
{{- printf "%s-headless" (include "mongodb-vm.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
VIP service name (HA + vip.enabled only) — primary-only LoadBalancer or NodePort Service.
*/}}
{{- define "mongodb-vm.vipSvcName" -}}
{{- printf "%s-vip" (include "mongodb-vm.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mongodb-vm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mongodb-vm.name" . }}
app.kubernetes.io/instance: {{ include "mongodb-vm.fullname" . }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mongodb-vm.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "mongodb-vm.name" . }}
app.kubernetes.io/instance: {{ include "mongodb-vm.fullname" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- /* The deployment namespace IS the tenant ID, so default to it. Matches the namespace label set by the ns-label hook. */}}
{{- $tenantId := include "mongodb-vm.val" (list . "governance.namespaceLabel.tenantId") | default .Release.Namespace }}
{{- if $tenantId }}
sovereign.cloud.ibm.com/account-id: {{ $tenantId | quote }}
sovcore.byop.ibm.com/account-id: {{ $tenantId | quote }}
{{- end }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "mongodb-vm.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
DataVolume spec — source + storage block, shared by standalone and HA branches.
Accepts the root context (.) directly.
*/}}
{{- define "mongodb-vm.dvSpec" -}}
{{- /*
  Resolve disk image source. Values may arrive either as a proper nested structure
  (diskImage.sourceContainerDisk) or as flat dot-notation top-level keys
  ("diskImage.sourceContainerDisk") when the broker passes overrides via
  helm.valuesObject. The index function handles the flat-key fallback.
*/ -}}
{{- $containerDisk := index .Values "diskImage.sourceContainerDisk" | default .Values.diskImage.sourceContainerDisk }}
{{- $sourceURL     := index .Values "diskImage.sourceURL"            | default .Values.diskImage.sourceURL }}
{{- $sourcePVC     := index .Values "diskImage.sourcePVCName"        | default .Values.diskImage.sourcePVCName }}
{{- $pullSecret    := index .Values "diskImage.pullSecret"           | default .Values.diskImage.pullSecret }}
{{- $certConfigMap := index .Values "diskImage.certConfigMap"        | default .Values.diskImage.certConfigMap }}
{{- $sourcePVCNS   := index .Values "diskImage.sourcePVCNamespace"   | default .Values.diskImage.sourcePVCNamespace }}
{{- $tenantId      := include "mongodb-vm.val" (list . "governance.namespaceLabel.tenantId") | default .Release.Namespace }}
{{- $defaultSC     := printf "ceph-rbd-%s" $tenantId }}
{{- $storageClass  := include "mongodb-vm.val" (list . "diskImage.storageClassName") | default $defaultSC }}
{{- $diskSizeGi    := index .Values "diskImage.diskSizeGi"           | default .Values.diskImage.diskSizeGi }}
{{- if $containerDisk }}
source:
  registry:
    url: "docker://{{ $containerDisk }}"
    {{- if $pullSecret }}
    secretRef: {{ $pullSecret | quote }}
    {{- end }}
    {{- if $certConfigMap }}
    certConfigMap: {{ $certConfigMap | quote }}
    {{- end }}
{{- else if $sourceURL }}
source:
  http:
    url: {{ $sourceURL | quote }}
{{- else if $sourcePVC }}
source:
  pvc:
    name: {{ $sourcePVC | quote }}
    namespace: {{ $sourcePVCNS | default .Release.Namespace | quote }}
{{- else }}
{{- fail "One of diskImage.sourceContainerDisk, diskImage.sourceURL, or diskImage.sourcePVCName must be set" }}
{{- end }}
storage:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ $diskSizeGi }}Gi
  storageClassName: {{ $storageClass | quote }}
  volumeMode: Block
{{- end }}


{{/*
Resolve the three instance passwords — lookup existing Secret first (upgrade path),
otherwise generate fresh random passwords (first-deploy path).
This is called by both credentials-secret.yaml and the cloud-init userdata so that
all three templates use the exact same password values in a single Helm render.
Passwords are NEVER read from values.yaml.
Returns a JSON dict: vmPass / rootPass / dbPass.
*/}}
{{- define "mongodb-vm.resolvePasswords" -}}
{{- $ns         := .Release.Namespace -}}
{{- $secretName := printf "%s-mongodb-creds" (include "mongodb-vm.fullname" .) -}}
{{- $existing   := lookup "v1" "Secret" $ns $secretName -}}
{{- $vmPass     := "" -}}
{{- $rootPass   := "" -}}
{{- $dbPass     := "" -}}
{{- $vmPassHash := "" -}}
{{- if $existing -}}
  {{- $vmPass     = index $existing.data "vm_root_password"      | b64dec -}}
  {{- $rootPass   = index $existing.data "root_password"         | b64dec -}}
  {{- $dbPass     = index $existing.data "database_password"     | b64dec -}}
  {{- $vmPassHash = index $existing.data "vm_root_password_hash" | b64dec -}}
  {{- /* Upgrade path: Secret exists but hash key missing — generate once and it will be persisted on next apply */ -}}
  {{- if not $vmPassHash -}}
    {{- $vmPassHash = $vmPass | bcrypt -}}
  {{- end -}}
{{- else -}}
  {{- $vmPass     = randAlphaNum 24 -}}
  {{- $rootPass   = randAlphaNum 24 -}}
  {{- $dbPass     = randAlphaNum 24 -}}
  {{- $vmPassHash = $vmPass | bcrypt -}}
{{- end -}}
{{- dict "vmPass" $vmPass "rootPass" $rootPass "dbPass" $dbPass "vmPassHash" $vmPassHash | toJson -}}
{{- end }}

{{/*
Name of the per-instance Concert SSH keypair Secret. Defaults to <instance>-concert-ssh so
every deployment gets its own key, owned by (and deleted with) that deployment.
Override with concertSSHKeySecret only to share one key deliberately.
Needs .Values and .Chart in the calling context.
*/}}
{{- define "mongodb-vm.concertSecretName" -}}
{{- .Values.concertSSHKeySecret | default (printf "%s-concert-ssh" (include "mongodb-vm.fullname" .)) -}}
{{- end }}

{{/*
<name>-mongodb-creds Secret. Called from cloudinit-secret.yaml with the SAME resolved
passwords that go into the VM cloud-init, so the Secret always matches the VMs.
Call: include "mongodb-vm.credsSecret" (dict "root" $ "p" $passwords)

Retrieve after deployment:
  kubectl get secret <name>-mongodb-creds -n <ns> -o jsonpath='{.data.vm_root_password}' | base64 -d
  kubectl get secret <name>-mongodb-creds -n <ns> -o jsonpath='{.data.root_password}' | base64 -d
  kubectl get secret <name>-mongodb-creds -n <ns> -o jsonpath='{.data.database_password}' | base64 -d
*/}}
{{- define "mongodb-vm.credsSecret" -}}
{{- $r := .root -}}
{{- $p := .p }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ printf "%s-mongodb-creds" (include "mongodb-vm.fullname" $r) }}
  namespace: {{ $r.Release.Namespace }}
  labels:
    {{- include "mongodb-vm.labels" $r | nindent 4 }}
  annotations:
    {{- include "mongodb-vm.annotations" $r | nindent 4 }}
    sovcore.byop.ibm.com/secret-type: mongodb-credentials
    sovcore.byop.ibm.com/instance: {{ include "mongodb-vm.fullname" $r | quote }}
type: Opaque
data:
  vm_root_password: {{ $p.vmPass | b64enc | quote }}
  ## bcrypt hash of vm_root_password — the same hash cloud-init chpasswd uses.
  vm_root_password_hash: {{ $p.vmPassHash | b64enc | quote }}
  ## MongoDB admin username — always "root" (created by mongo-first-boot.sh step 4).
  root_username: {{ "root" | b64enc | quote }}
  root_password: {{ $p.rootPass | b64enc | quote }}
  database_password: {{ $p.dbPass | b64enc | quote }}
  database_user: {{ (include "mongodb-vm.val" (list $r "mongodb.databaseUser") | default "appuser") | b64enc | quote }}
  database_name: {{ (include "mongodb-vm.val" (list $r "mongodb.databaseName") | default "appdb") | b64enc | quote }}
{{- end }}

{{/*
mongodb-vm.vaultBootstrap — resolve and validate the Vault PKI TLS bootstrap
material ONCE per render. Returns JSON (parse with fromJson):
  { enabled, address, pkiMount, pkiRole, roleId, caCert, certTTL,
    minRemainingS, minimumVersion, altNames, wrapped: [...], renewal: [...] }

Every field resolves flat dot-notation key first (broker helm.valuesObject
override), then the nested values path. HARD-FAILS the render when
compliance.tls.enabled=true and any required value is missing, when the
source is not "vault", or when the token lists do not hold ONE entry per
VM (wrapping tokens are single-use, so every member needs its own) — the
chart NEVER renders a TLS-enabled userdata with empty bootstrap
credentials: that VM would strand at first boot with no cert and no
plaintext fallback.

No Helm lookup is performed on this path (ArgoCD disables lookup); all
material arrives as plain values. Called from cloudinit-secret.yaml, which
passes the result into both userdata contexts as "vaultBootstrap" (the
same once-per-render pattern as sharedPasswords / sharedKeyFile — the
userdata templates carry a direct-call fallback for safety).
*/}}
{{- define "mongodb-vm.vaultBootstrap" -}}
{{- $tlsEnabled := include "mongodb-vm.val" (list . "compliance.tls.enabled") | default "false" -}}
{{- if not ($tlsEnabled | eq "true") -}}
{{- dict "enabled" false | toJson -}}
{{- else -}}
{{- $source := include "mongodb-vm.val" (list . "compliance.tls.source") | default "vault" -}}
{{- if ne $source "vault" -}}
{{- fail (printf "compliance.tls.source '%s' is not supported — only 'vault' (Option B, runtime issue from the tenant Vault PKI). Option A (pre-created cert Secret) is not implemented." $source) -}}
{{- end -}}
{{- $vmCount := 1 -}}
{{- if include "mongodb-vm.val" (list . "ha.enabled") | eq "true" -}}
{{- $vmCount = include "mongodb-vm.val" (list . "ha.replicaCount") | default "3" | int -}}
{{- end -}}
{{- $address := include "mongodb-vm.val" (list . "vault.address") -}}
{{- $roleId := include "mongodb-vm.val" (list . "vault.roleId") -}}
{{- $renewalRoleId := include "mongodb-vm.val" (list . "vault.renewalRoleId") -}}
{{- $caCert := include "mongodb-vm.val" (list . "vault.caCert") -}}
{{- $pkiMount := include "mongodb-vm.val" (list . "vault.pkiMount") | default "pki_int" -}}
{{- $pkiRole := include "mongodb-vm.val" (list . "vault.pkiRole") | default "mongodb-server" -}}
{{- $certTTL := include "mongodb-vm.val" (list . "compliance.tls.certTTL") | default "720h" -}}
{{- $renewDays := include "mongodb-vm.val" (list . "compliance.tls.renewWhenRemainingDays") | default "7" | int -}}
{{- $minimumVersion := include "mongodb-vm.val" (list . "compliance.tls.minimumVersion") | default "TLS1_2" -}}
{{- $externalHostname := include "mongodb-vm.val" (list . "compliance.tls.externalHostname") -}}
{{- if or (not $address) (not $roleId) (not $renewalRoleId) (not $caCert) (not $pkiRole) -}}
{{- fail "compliance.tls.enabled=true requires vault.address, vault.roleId, vault.renewalRoleId, vault.caCert and vault.pkiRole (all plain values — ArgoCD-safe; no Helm lookup on this path). The renewal secret-id belongs to the RENEWAL AppRole, which has its own RoleID. See encryption-in-transit-vault-pki-implementation.md Part B." -}}
{{- end -}}
{{- if not (hasPrefix "https://" $address) -}}
{{- fail (printf "vault.address must use https:// (got '%s') — plain http silently disables TLS for the entire Vault credential channel (unwrap/login/issue)." $address) -}}
{{- end -}}
{{- if le $renewDays 0 -}}
{{- fail (printf "compliance.tls.renewWhenRemainingDays must be > 0 (got %d) — 0 would disable renewal entirely." $renewDays) -}}
{{- end -}}
{{- if ne $minimumVersion "TLS1_2" -}}
{{- fail (printf "compliance.tls.minimumVersion '%s' is not supported — only TLS1_2 (MongoDB has no native minimum-version option; it maps to net.tls.disabledProtocols)." $minimumVersion) -}}
{{- end -}}
{{- /* Token lists: flat broker key first, then the nested values path. */ -}}
{{- $wrapped := index .Values "vault.wrappedSecretIds" -}}
{{- if not $wrapped -}}
{{- $vaultVal := index .Values "vault" | default dict -}}
{{- $wrapped = index $vaultVal "wrappedSecretIds" | default list -}}
{{- end -}}
{{- $renewal := index .Values "vault.renewalSecretIds" -}}
{{- if not $renewal -}}
{{- $vaultVal := index .Values "vault" | default dict -}}
{{- $renewal = index $vaultVal "renewalSecretIds" | default list -}}
{{- end -}}
{{- if lt (len $wrapped) $vmCount -}}
{{- fail (printf "compliance.tls.enabled=true needs vault.wrappedSecretIds with ONE entry per VM (have %d, need %d) — response-wrapping tokens are single-use, so each member needs its own. Mint per deployment: doc encryption-in-transit-vault-pki-implementation.md Part A5." (len $wrapped) $vmCount) -}}
{{- end -}}
{{- if lt (len $renewal) $vmCount -}}
{{- fail (printf "compliance.tls.enabled=true needs vault.renewalSecretIds with ONE entry per VM (have %d, need %d) — the daily renewal timer re-logs-in after the single-use bootstrap token is consumed." (len $renewal) $vmCount) -}}
{{- end -}}
{{- /* SANs beyond the member CN: in HA the client Service
       <fullname>.<ns>.svc.cluster.local selects all members and is the
       documented in-cluster connection path, and the VIP Service FQDN is
       what VIP clients verify against — both must be in the cert SANs.
       The Vault PKI role's allowed_domains must permit these zones too
       (doc Part A3). */ -}}
{{- $ns := .Release.Namespace -}}
{{- $base := include "mongodb-vm.fullname" . -}}
{{- $altNames := "localhost" -}}
{{- if include "mongodb-vm.val" (list . "ha.enabled") | eq "true" -}}
{{- $altNames = printf "%s,%s.%s.svc.cluster.local" $altNames $base $ns -}}
{{- if include "mongodb-vm.val" (list . "vip.enabled") | eq "true" -}}
{{- $altNames = printf "%s,%s-vip.%s.svc.cluster.local" $altNames $base $ns -}}
{{- end -}}
{{- end -}}
{{- if $externalHostname -}}
{{- $altNames = printf "%s,%s" $altNames $externalHostname -}}
{{- end -}}
{{- dict "enabled" true "address" $address "pkiMount" $pkiMount "pkiRole" $pkiRole "roleId" $roleId "renewalRoleId" $renewalRoleId "caCert" $caCert "certTTL" $certTTL "minRemainingS" (mul $renewDays 86400) "minimumVersion" $minimumVersion "altNames" $altNames "wrapped" $wrapped "renewal" $renewal | toJson -}}
{{- end -}}
{{- end }}

{{/*
Cloud-init userdata — standalone (no replica set).
*/}}
{{- define "mongodb-vm.userdata" -}}
{{- /* sharedPasswords is passed by cloudinit-secret.yaml so the VM and the creds Secret agree */ -}}
{{- $p          := .sharedPasswords -}}
{{- if not $p -}}
{{- $p = include "mongodb-vm.resolvePasswords" . | fromJson -}}
{{- end -}}
{{- $vmPass     := $p.vmPass -}}
{{- $rootPass   := $p.rootPass -}}
{{- $dbPass     := $p.dbPass -}}
{{- $vmPassHash := $p.vmPassHash -}}
{{- /* Merge Concert cluster SSH key (from Secret) with any user-supplied keys */ -}}
{{- $allSSHKeys := .Values.sshAuthorizedKeys | default list -}}
{{- $concertSecretName := include "mongodb-vm.concertSecretName" . -}}
{{- $ns := .Release.Namespace -}}
{{- $concertSecret := lookup "v1" "Secret" $ns $concertSecretName -}}
{{- if $concertSecret -}}
  {{- $concertKey := index $concertSecret.data "authorized_key" | b64dec -}}
  {{- if $concertKey -}}
    {{- $allSSHKeys = append $allSSHKeys $concertKey -}}
  {{- end -}}
{{- end -}}
{{- /* Vault PKI TLS bootstrap (Phase 3, mdb-enc-01) — resolved once per render
       by cloudinit-secret.yaml and passed in as "vaultBootstrap"; direct-call
       fallback resolves from values (deterministic — no lookup). */ -}}
{{- $vb := .vaultBootstrap -}}
{{- if not $vb -}}
{{- $vb = include "mongodb-vm.vaultBootstrap" . | fromJson -}}
{{- end -}}
#cloud-config
disable_root: false
{{- /* 'default' marks cloud-user (system_info.default_user) as the default user: cloud-init
     gives the datasource public-keys (the Concert key delivered by KubeVirt accessCredentials)
     ONLY to the default user. Without it they were silently dropped. */}}
users:
  - default
  - name: root
    lock_passwd: false
{{- if $allSSHKeys }}
    ssh_authorized_keys:
      {{- range $allSSHKeys }}
      - {{ . | quote }}
      {{- end }}
{{- end }}
  - name: cloud-user
    lock_passwd: false
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    passwd: {{ $vmPassHash | quote }}
{{- if $allSSHKeys }}
    ssh_authorized_keys:
      {{- range $allSSHKeys }}
      - {{ . | quote }}
      {{- end }}
{{- end }}
chpasswd:
  list: |
    root:{{ $vmPass }}
    cloud-user:{{ $vmPass }}
  expire: false
## ssh_pwauth: false — SSH is key-only (mdb-virt-01 / iscf-ia-04). The Concert public key
## reaches authorized_keys via KubeVirt accessCredentials (see virtualmachine.yaml).
## Console login with the chpasswd password is unaffected (it is not SSH).
ssh_pwauth: false
write_files:
  - path: /etc/mongo-init-env
    permissions: '0600'
    content: |
      DB_NAME={{ .Values.mongodb.databaseName }}
      DB_USER={{ .Values.mongodb.databaseUser }}
      DB_PASS={{ $dbPass }}
      ADMIN_PASS={{ $rootPass }}

  - path: /etc/mongo-probe-pass-env
    ## Root password for Concert compliance checks (mdb-auth-02, mdb-rbac-01, mdb-rbac-02).
    ## Persists in root-only /etc so checks can verify DB posture after first-boot shreds init-env.
    permissions: '0600'
    owner: 'root:root'
    content: |
      ADMIN_PASS={{ $rootPass }}

  - path: /etc/logrotate.d/mongodb
    ## mdb-aud-03 (iscf-gov-01/ai-13): log retention 90+ days (weekly x 13 = 91 days).
    permissions: '0644'
    owner: 'root:root'
    content: |
      /var/log/mongodb/*.log {
          weekly
          rotate 13
          compress
          missingok
          notifempty
          copytruncate
      }

  - path: /etc/mongo-compliance-env
    permissions: '0600'
    content: |
      ## Phase 2 compliance flags — sourced by mongo-first-boot.sh
      ## mdb-enc-02 (iscf-cr-01/dr-06): WiredTiger encryption-at-rest
      MONGO_COMPLIANCE_ENCRYPTION={{ include "mongodb-vm.val" (list . "compliance.enableEncryption") | default "false" | lower }}
      ## mdb-aud-01 (iscf-ia-04/gov-03/dr-10) + mdb-aud-02 (iscf-ia-04/gov-02/ai-04)
      MONGO_COMPLIANCE_AUDIT={{ include "mongodb-vm.val" (list . "compliance.auditLog.enabled") | default "false" | lower }}
      MONGO_COMPLIANCE_AUDIT_PATH={{ include "mongodb-vm.val" (list . "compliance.auditLog.path") | default "/var/log/mongodb/audit.json" }}
      MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS={{ include "mongodb-vm.val" (list . "compliance.auditLog.auditAuthorizationSuccess") | default "true" | lower }}

  {{- if $vb.enabled }}
  ## Phase 3 — mdb-enc-01 (iscf-cr-03/dr-07/ai-03): TLS in transit via the
  ## tenant Vault PKI. The TLS private key NEVER transits Kubernetes — the
  ## only secret material below is the single-use wrapped token and the
  ## renewal secret-id. The certificate is fetched in-guest (python3.12 +
  ## requests) BEFORE mongod first starts; fail closed, never plaintext.
  - path: /etc/mongo-tls-env
    permissions: '0600'
    content: |
      ## TLS flags — sourced by mongo-first-boot.sh, mongo-rs-init.sh and
      ## mongo-primary-probe.py (persists in /etc; nothing shreds it).
      MONGO_TLS_ENABLED=true
      MONGO_TLS_CERT_FILE=/etc/mongodb/tls/server.pem
      MONGO_TLS_CA_FILE=/etc/mongodb/tls/ca.pem
      MONGO_TLS_MIN_VERSION={{ $vb.minimumVersion }}
  - path: /etc/mongo-vault/env
    permissions: '0644'
    content: |
      ## Vault PKI bootstrap — consumed by mongo-vault-fetch-certs.py.
      ## Names/paths/SANs only; the credentials live in the files below.
      VAULT_ADDR={{ $vb.address }}
      VAULT_CACERT=/etc/mongo-vault/vault-ca.pem
      VAULT_PKI_MOUNT={{ $vb.pkiMount }}
      VAULT_PKI_ROLE={{ $vb.pkiRole }}
      VAULT_ROLE_ID_FILE=/etc/mongo-vault/role_id
      VAULT_WRAPPED_SID_FILE=/etc/mongo-vault/wrapped-secret-id
      VAULT_RENEWAL_SID_FILE=/etc/mongo-vault/renewal-secret-id
      MONGO_TLS_CN={{ include "mongodb-vm.fullname" . }}.{{ .Release.Namespace }}.svc.cluster.local
      MONGO_TLS_ALT_NAMES={{ $vb.altNames }}
      MONGO_TLS_IP_SANS=127.0.0.1
      MONGO_TLS_TTL={{ $vb.certTTL }}
      MONGO_TLS_CERT_DIR=/etc/mongodb/tls
      MONGO_TLS_MIN_REMAINING_S={{ $vb.minRemainingS }}
  - path: /etc/mongo-vault/role_id
    ## AppRole RoleID — an identifier, NOT a secret (Vault AppRole docs).
    permissions: '0444'
    content: |
      {{ $vb.roleId }}
  - path: /etc/mongo-vault/renewal-role-id
    ## RoleID of the RENEWAL AppRole (also not a secret). The renewal
    ## secret-id belongs to that role — AppRole login requires the matching
    ## role_id/secret_id pair, so the renewal branch must use this one.
    permissions: '0444'
    content: |
      {{ $vb.renewalRoleId }}
  - path: /etc/mongo-vault/wrapped-secret-id
    ## Single-use response-wrapping token — consumed at first boot, then
    ## deleted by the fetch script. Replay is detectable (second unwrap 400s
    ## and the Vault audit log shows the first).
    permissions: '0400'
    content: |
      {{ index $vb.wrapped 0 }}
  - path: /etc/mongo-vault/renewal-secret-id
    ## Persistent secret-id for the daily renewal timer (mongo-vault-renew).
    permissions: '0400'
    content: |
      {{ index $vb.renewal 0 }}
  - path: /etc/mongo-vault/vault-ca.pem
    ## CA that signed Vault's own HTTPS listener — PUBLIC material, distinct
    ## from the PKI CA (which the issue response returns as issuing_ca).
    permissions: '0644'
    content: |
      {{ $vb.caCert | nindent 6 }}
  ## Systemd drop-ins (TLS deployments only) — applied by write_files before
  ## runcmd; the daemon-reload runcmd line below loads them.
  - path: /etc/systemd/system/mongodb-first-boot.service.d/vault-tls.conf
    permissions: '0644'
    content: |
      [Unit]
      ## Fail closed: first-boot must not run if the Vault cert fetch failed
      ## (Requires= propagates the failure; the baked unit uses Wants= so a
      ## condition-skipped fetch never blocks non-TLS VMs).
      Requires=mongo-vault-certs.service
  - path: /etc/systemd/system/mongod.service.d/tls.conf
    permissions: '0644'
    content: |
      [Unit]
      ## Reboot fail-closed: mongod never starts without its TLS material,
      ## and never with an unrenewable certificate — Requires= blocks mongod
      ## when the per-boot re-check fails (expired cert + Vault unreachable).
      ## With a valid cert the fetch fast-path returns instantly without
      ## contacting Vault, so healthy boots pay nothing for this.
      Requires=mongo-vault-certs.service
      ConditionPathExists=/etc/mongodb/tls/server.pem
  {{- end }}

  - path: /etc/mongo-rsyslog-env
    permissions: '0600'
    content: |
      ## rsyslog injection flags — sourced by mongo-first-boot.sh
      MONGO_RSYSLOG_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_FWD_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_FWD_HOST={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.host") | default "" | quote }}
      MONGO_RSYSLOG_FWD_PORT={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.port") | default "514" }}
      MONGO_RSYSLOG_FWD_PROTOCOL={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.protocol") | default "tcp" | quote }}
      MONGO_RSYSLOG_FWD_FORMAT={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.format") | default "rfc5424" | quote }}
      MONGO_RSYSLOG_MONGOD_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.enabled") | default "true" | lower }}
      MONGO_RSYSLOG_MONGOD_TAG={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.tag") | default "mongodb-mongod" | quote }}
      MONGO_RSYSLOG_MONGOD_FACILITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.facility") | default "local6" | quote }}
      MONGO_RSYSLOG_MONGOD_SEVERITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.severity") | default "info" | quote }}
      MONGO_RSYSLOG_AUDIT_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_AUDIT_PATH={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.path") | default "/var/log/mongodb/audit.json" | quote }}
      MONGO_RSYSLOG_AUDIT_TAG={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.tag") | default "mongodb-audit" | quote }}
      MONGO_RSYSLOG_AUDIT_FACILITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.facility") | default "local7" | quote }}
      MONGO_RSYSLOG_AUDIT_SEVERITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.severity") | default "notice" | quote }}
      MONGO_RSYSLOG_RATELIMIT_INTERVAL={{ include "mongodb-vm.val" (list . "logging.rsyslog.rateLimit.intervalSeconds") | default "5" }}
      MONGO_RSYSLOG_RATELIMIT_BURST={{ include "mongodb-vm.val" (list . "logging.rsyslog.rateLimit.burstCount") | default "500" }}
  {{- $rsyslogCustom := include "mongodb-vm.val" (list . "logging.rsyslog.customConf") }}
  {{- if $rsyslogCustom }}
  ## Verbatim rsyslog snippet — written as-is to the drop-in path.
  ## mongo-first-boot.sh appends this to /etc/rsyslog.d/60-mongodb.conf.
  - path: /etc/mongo-rsyslog-custom.conf
    content: |
      {{ $rsyslogCustom | nindent 6 }}
    permissions: '0640'
  {{- end }}
  ## mdb-aud-03 (iscf-gov-01 / iscf-ai-13): 91-day retention (weekly x 13).
  ## The compliance check reads this rule and requires rotate >= 13.
  - path: /etc/logrotate.d/mongodb
    permissions: '0644'
    owner: root:root
    content: |
      /var/log/mongodb/*.log {
          weekly
          rotate 13
          compress
          missingok
          notifempty
          copytruncate
      }
  {{- $ntpServer := include "mongodb-vm.val" (list . "ntp.server") }}
  {{- if $ntpServer }}
  ## mdb-vm-01 (iscf-mi-03): site-specific NTP server (chrony drop-in)
  - path: /etc/chrony.d/site-ntp.conf
    permissions: '0644'
    content: |
      server {{ $ntpServer }} iburst
  {{- end }}
runcmd:
  - mkdir -p /var/log/mongodb && chown -R mongod:mongod /var/log/mongodb || true
  {{- if $ntpServer }}
  - systemctl restart chronyd || true
  {{- end }}
  ## mdb-aud-03: the log directory must exist before mongod writes to it.
  ## /var/log/mongodb is created with mongod:mongod ownership by the image.
  {{- if $vb.enabled }}
  ## Phase 3 (mdb-enc-01): reload systemd (the TLS drop-ins above were just
  ## written by write_files), then fetch the TLS certificate BEFORE
  ## first-boot starts mongod. mongo-vault-certs.service is Type=oneshot —
  ## systemctl start blocks until the fetch completes or fails. On failure,
  ## first-boot's own step-0 TLS guard stops mongod: never a plaintext start.
  - systemctl daemon-reload
  - systemctl start mongo-vault-certs.service
  ## Daily renewal timer — fast-path no-op while the cert has margin.
  - systemctl enable --now mongo-vault-renew.timer
  {{- end }}
  - set -a && . /etc/mongo-init-env && set +a && /usr/local/bin/mongo-first-boot.sh
{{- end }}

{{/*
Cloud-init userdata — HA replica-set member.
Called with a dict: (dict "Values" .Values "Chart" .Chart "Release" .Release "index" $i)

Every member:
  - writes /etc/mongo-init-env (credentials + replica-set config)
  - calls /usr/local/bin/mongo-first-boot.sh (must handle RS mode via MONGO_RS_* env vars)

Member-0 additionally:
  - calls /usr/local/bin/mongo-rs-init.sh which runs rs.initiate() with all member hosts
*/}}
{{- define "mongodb-vm.userdata.ha" -}}
{{- $base    := include "mongodb-vm.fullname" . -}}
{{- $svc     := include "mongodb-vm.headlessSvcName" . -}}
{{- $ns      := .Release.Namespace -}}
{{- $rsName  := include "mongodb-vm.val" (list . "ha.replicaSetName") -}}
{{- $port    := include "mongodb-vm.val" (list . "ha.port") | default "27017" | int -}}
{{- $count   := include "mongodb-vm.val" (list . "ha.replicaCount") | default "3" | int -}}
{{- $idx     := int .index -}}
{{- $selfHost := printf "%s-%d.%s.%s.svc.cluster.local" $base $idx $svc $ns -}}
{{- /* Build the full member host list for rs.initiate() on member-0 */ -}}
{{- $members := list -}}
{{- range $i := until $count -}}
{{- $host := printf "%s-%d.%s.%s.svc.cluster.local:%d" $base $i $svc $ns $port -}}
{{- $members = append $members $host -}}
{{- end -}}
{{- $memberList := join "," $members -}}
{{- /*
  keyFile and passwords are generated ONCE in virtualmachine.yaml before the range loop
  and passed in via the dict as "sharedKeyFile" and "sharedPasswords" — all members
  share the same values. This fixes the ArgoCD lookup bug where resolvePasswords called
  inside the loop generates different randAlphaNum passwords per member.
*/ -}}
{{- $keyFile := .sharedKeyFile -}}
{{- /* Use sharedPasswords if passed in (HA path via virtualmachine.yaml range loop).
       Fall back to resolvePasswords for standalone path or direct template calls. */ -}}
{{- $p := .sharedPasswords -}}
{{- if not $p -}}
{{- $p = include "mongodb-vm.resolvePasswords" . | fromJson -}}
{{- end -}}
{{- $vmPass     := $p.vmPass -}}
{{- $rootPass   := $p.rootPass -}}
{{- $dbPass     := $p.dbPass -}}
{{- $vmPassHash := $p.vmPassHash -}}
{{- /* Merge Concert cluster SSH key (from Secret) with any user-supplied keys */ -}}
{{- $allSSHKeys := .Values.sshAuthorizedKeys | default list -}}
{{- $concertSecretName := include "mongodb-vm.concertSecretName" . -}}
{{- $concertNs := .Release.Namespace -}}
{{- $concertSecret := lookup "v1" "Secret" $concertNs $concertSecretName -}}
{{- if $concertSecret -}}
  {{- $concertKey := index $concertSecret.data "authorized_key" | b64dec -}}
  {{- if $concertKey -}}
    {{- $allSSHKeys = append $allSSHKeys $concertKey -}}
  {{- end -}}
{{- end -}}
{{- /* Vault PKI TLS bootstrap (Phase 3, mdb-enc-01) — resolved once per render
       by cloudinit-secret.yaml and passed in as "vaultBootstrap"; direct-call
       fallback resolves from values (deterministic — no lookup). */ -}}
{{- $vb := .vaultBootstrap -}}
{{- if not $vb -}}
{{- $vb = include "mongodb-vm.vaultBootstrap" . | fromJson -}}
{{- end -}}
#cloud-config
disable_root: false
{{- /* 'default' marks cloud-user (system_info.default_user) as the default user: cloud-init
     gives the datasource public-keys (the Concert key delivered by KubeVirt accessCredentials)
     ONLY to the default user. Without it they were silently dropped. */}}
users:
  - default
  - name: root
    lock_passwd: false
{{- if $allSSHKeys }}
    ssh_authorized_keys:
      {{- range $allSSHKeys }}
      - {{ . | quote }}
      {{- end }}
{{- end }}
  - name: cloud-user
    lock_passwd: false
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    passwd: {{ $vmPassHash | quote }}
{{- if $allSSHKeys }}
    ssh_authorized_keys:
      {{- range $allSSHKeys }}
      - {{ . | quote }}
      {{- end }}
{{- end }}
chpasswd:
  list: |
    root:{{ $vmPass }}
    cloud-user:{{ $vmPass }}
  expire: false
## ssh_pwauth: false — SSH is key-only (mdb-virt-01 / iscf-ia-04). The Concert public key
## reaches authorized_keys via KubeVirt accessCredentials (see virtualmachine.yaml).
## Console login with the chpasswd password is unaffected (it is not SSH).
ssh_pwauth: false
write_files:
  - path: /etc/mongo-init-env
    permissions: '0600'
    content: |
      DB_NAME={{ .Values.mongodb.databaseName }}
      DB_USER={{ .Values.mongodb.databaseUser }}
      DB_PASS={{ $dbPass }}
      ADMIN_PASS={{ $rootPass }}
      MONGO_RS_ENABLED=true
      MONGO_RS_NAME={{ $rsName }}
      MONGO_RS_MEMBERS={{ $memberList }}
      MONGO_RS_SELF={{ $selfHost }}
      MONGO_RS_INDEX={{ $idx }}

  - path: /etc/mongo-probe-pass-env
    ## Root password for Concert compliance checks (mdb-auth-02, mdb-rbac-01, mdb-rbac-02).
    ## Persists in root-only /etc so checks can verify DB posture after first-boot shreds init-env.
    permissions: '0600'
    owner: 'root:root'
    content: |
      ADMIN_PASS={{ $rootPass }}

  - path: /etc/logrotate.d/mongodb
    ## mdb-aud-03 (iscf-gov-01/ai-13): log retention 90+ days (weekly x 13 = 91 days).
    permissions: '0644'
    owner: 'root:root'
    content: |
      /var/log/mongodb/*.log {
          weekly
          rotate 13
          compress
          missingok
          notifempty
          copytruncate
      }

  - path: /etc/mongodb-keyfile
    ## Plain text — no encoding. sharedKeyFile is randAlphaNum (alphanumeric),
    ## or b64dec of a Kubernetes Secret, or an explicit plain-text value.
    ## MongoDB keyFile must be 6–1024 printable chars written as-is to disk.
    ## Quoted to prevent YAML special characters from breaking cloud-init parsing.
    content: {{ $keyFile | quote }}
    permissions: '0400'
    owner: 'mongod:mongod'
  {{- if include "mongodb-vm.val" (list . "vip.enabled") | eq "true" }}
  - path: /etc/mongo-probe-pass
    ## Root password read by mongo-primary-probe.py at startup.
    ## Only this credential file is written at runtime; the probe script and
    ## systemd unit are baked into the bootc image (scripts/mongo-primary-probe.py
    ## and units/mongo-primary-probe.service) to avoid OSError(30) — /usr/local/bin
    ## is read-only in the OSTree-managed /usr tree and cloud-init write_files
    ## cannot write there; doing so aborts the entire write_files module.
    content: {{ $rootPass }}
    permissions: '0400'
    owner: 'root:root'
{{- end }}
  - path: /etc/mongo-compliance-env
    permissions: '0600'
    content: |
      ## Phase 2 compliance flags — sourced by mongo-first-boot.sh
      ## mdb-enc-02 (iscf-cr-01/dr-06): WiredTiger encryption-at-rest
      MONGO_COMPLIANCE_ENCRYPTION={{ include "mongodb-vm.val" (list . "compliance.enableEncryption") | default "false" | lower }}
      ## mdb-aud-01 (iscf-ia-04/gov-03/dr-10) + mdb-aud-02 (iscf-ia-04/gov-02/ai-04)
      MONGO_COMPLIANCE_AUDIT={{ include "mongodb-vm.val" (list . "compliance.auditLog.enabled") | default "false" | lower }}
      MONGO_COMPLIANCE_AUDIT_PATH={{ include "mongodb-vm.val" (list . "compliance.auditLog.path") | default "/var/log/mongodb/audit.json" }}
      MONGO_COMPLIANCE_AUDIT_AUTH_SUCCESS={{ include "mongodb-vm.val" (list . "compliance.auditLog.auditAuthorizationSuccess") | default "true" | lower }}

  {{- if $vb.enabled }}
  ## Phase 3 — mdb-enc-01 (iscf-cr-03/dr-07/ai-03): TLS in transit via the
  ## tenant Vault PKI. Each member issues its OWN certificate (CN = its member
  ## FQDN) with its OWN single-use wrapped token — index-matched like the
  ## keyfile. The TLS private key NEVER transits Kubernetes.
  - path: /etc/mongo-tls-env
    permissions: '0600'
    content: |
      ## TLS flags — sourced by mongo-first-boot.sh, mongo-rs-init.sh and
      ## mongo-primary-probe.py (persists in /etc; nothing shreds it).
      MONGO_TLS_ENABLED=true
      MONGO_TLS_CERT_FILE=/etc/mongodb/tls/server.pem
      MONGO_TLS_CA_FILE=/etc/mongodb/tls/ca.pem
      MONGO_TLS_MIN_VERSION={{ $vb.minimumVersion }}
  - path: /etc/mongo-vault/env
    permissions: '0644'
    content: |
      ## Vault PKI bootstrap — consumed by mongo-vault-fetch-certs.py.
      ## Names/paths/SANs only; the credentials live in the files below.
      VAULT_ADDR={{ $vb.address }}
      VAULT_CACERT=/etc/mongo-vault/vault-ca.pem
      VAULT_PKI_MOUNT={{ $vb.pkiMount }}
      VAULT_PKI_ROLE={{ $vb.pkiRole }}
      VAULT_ROLE_ID_FILE=/etc/mongo-vault/role_id
      VAULT_WRAPPED_SID_FILE=/etc/mongo-vault/wrapped-secret-id
      VAULT_RENEWAL_SID_FILE=/etc/mongo-vault/renewal-secret-id
      MONGO_TLS_CN={{ $selfHost }}
      MONGO_TLS_ALT_NAMES={{ $vb.altNames }}
      MONGO_TLS_IP_SANS=127.0.0.1
      MONGO_TLS_TTL={{ $vb.certTTL }}
      MONGO_TLS_CERT_DIR=/etc/mongodb/tls
      MONGO_TLS_MIN_REMAINING_S={{ $vb.minRemainingS }}
  - path: /etc/mongo-vault/role_id
    ## AppRole RoleID — an identifier, NOT a secret (Vault AppRole docs).
    permissions: '0444'
    content: |
      {{ $vb.roleId }}
  - path: /etc/mongo-vault/renewal-role-id
    ## RoleID of the RENEWAL AppRole (also not a secret). The renewal
    ## secret-id belongs to that role — AppRole login requires the matching
    ## role_id/secret_id pair, so the renewal branch must use this one.
    permissions: '0444'
    content: |
      {{ $vb.renewalRoleId }}
  - path: /etc/mongo-vault/wrapped-secret-id
    ## THIS member's single-use response-wrapping token (index-matched).
    ## Consumed at first boot, then deleted by the fetch script; replay is
    ## detectable (second unwrap 400s; Vault audit log shows the first).
    permissions: '0400'
    content: |
      {{ index $vb.wrapped (int $idx) }}
  - path: /etc/mongo-vault/renewal-secret-id
    ## THIS member's persistent secret-id for the daily renewal timer.
    permissions: '0400'
    content: |
      {{ index $vb.renewal (int $idx) }}
  - path: /etc/mongo-vault/vault-ca.pem
    ## CA that signed Vault's own HTTPS listener — PUBLIC material, distinct
    ## from the PKI CA (which the issue response returns as issuing_ca).
    permissions: '0644'
    content: |
      {{ $vb.caCert | nindent 6 }}
  ## Systemd drop-ins (TLS deployments only) — applied by write_files before
  ## runcmd; the daemon-reload runcmd line below loads them.
  - path: /etc/systemd/system/mongodb-first-boot.service.d/vault-tls.conf
    permissions: '0644'
    content: |
      [Unit]
      ## Fail closed: first-boot must not run if the Vault cert fetch failed
      ## (Requires= propagates the failure; the baked unit uses Wants= so a
      ## condition-skipped fetch never blocks non-TLS VMs).
      Requires=mongo-vault-certs.service
  - path: /etc/systemd/system/mongod.service.d/tls.conf
    permissions: '0644'
    content: |
      [Unit]
      ## Reboot fail-closed: mongod never starts without its TLS material,
      ## and never with an unrenewable certificate — Requires= blocks mongod
      ## when the per-boot re-check fails (expired cert + Vault unreachable).
      ## With a valid cert the fetch fast-path returns instantly without
      ## contacting Vault, so healthy boots pay nothing for this.
      Requires=mongo-vault-certs.service
      ConditionPathExists=/etc/mongodb/tls/server.pem
  {{- end }}

  - path: /etc/mongo-rsyslog-env
    permissions: '0600'
    content: |
      ## rsyslog injection flags — sourced by mongo-first-boot.sh
      MONGO_RSYSLOG_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_FWD_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_FWD_HOST={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.host") | default "" | quote }}
      MONGO_RSYSLOG_FWD_PORT={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.port") | default "514" }}
      MONGO_RSYSLOG_FWD_PROTOCOL={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.protocol") | default "tcp" | quote }}
      MONGO_RSYSLOG_FWD_FORMAT={{ include "mongodb-vm.val" (list . "logging.rsyslog.forwarding.format") | default "rfc5424" | quote }}
      MONGO_RSYSLOG_MONGOD_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.enabled") | default "true" | lower }}
      MONGO_RSYSLOG_MONGOD_TAG={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.tag") | default "mongodb-mongod" | quote }}
      MONGO_RSYSLOG_MONGOD_FACILITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.facility") | default "local6" | quote }}
      MONGO_RSYSLOG_MONGOD_SEVERITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.mongodLog.severity") | default "info" | quote }}
      MONGO_RSYSLOG_AUDIT_ENABLED={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.enabled") | default "false" | lower }}
      MONGO_RSYSLOG_AUDIT_PATH={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.path") | default "/var/log/mongodb/audit.json" | quote }}
      MONGO_RSYSLOG_AUDIT_TAG={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.tag") | default "mongodb-audit" | quote }}
      MONGO_RSYSLOG_AUDIT_FACILITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.facility") | default "local7" | quote }}
      MONGO_RSYSLOG_AUDIT_SEVERITY={{ include "mongodb-vm.val" (list . "logging.rsyslog.fileMonitoring.auditLog.severity") | default "notice" | quote }}
      MONGO_RSYSLOG_RATELIMIT_INTERVAL={{ include "mongodb-vm.val" (list . "logging.rsyslog.rateLimit.intervalSeconds") | default "5" }}
      MONGO_RSYSLOG_RATELIMIT_BURST={{ include "mongodb-vm.val" (list . "logging.rsyslog.rateLimit.burstCount") | default "500" }}
  {{- $rsyslogCustom := include "mongodb-vm.val" (list . "logging.rsyslog.customConf") }}
  {{- if $rsyslogCustom }}
  - path: /etc/mongo-rsyslog-custom.conf
    content: |
      {{ $rsyslogCustom | nindent 6 }}
    permissions: '0640'
  {{- end }}
  ## mdb-aud-03 (iscf-gov-01 / iscf-ai-13): 91-day retention (weekly x 13).
  ## The compliance check reads this rule and requires rotate >= 13.
  - path: /etc/logrotate.d/mongodb
    permissions: '0644'
    owner: root:root
    content: |
      /var/log/mongodb/*.log {
          weekly
          rotate 13
          compress
          missingok
          notifempty
          copytruncate
      }
  {{- $ntpServer := include "mongodb-vm.val" (list . "ntp.server") }}
  {{- if $ntpServer }}
  ## mdb-vm-01 (iscf-mi-03): site-specific NTP server (chrony drop-in)
  - path: /etc/chrony.d/site-ntp.conf
    permissions: '0644'
    content: |
      server {{ $ntpServer }} iburst
  {{- end }}
runcmd:
  - mkdir -p /var/log/mongodb && chown -R mongod:mongod /var/log/mongodb || true
  {{- if $ntpServer }}
  - systemctl restart chronyd || true
  {{- end }}
  ## mdb-aud-03: the log directory must exist before mongod writes to it.
  ## /var/log/mongodb is created with mongod:mongod ownership by the image.
  {{- if $vb.enabled }}
  ## Phase 3 (mdb-enc-01): reload systemd (the TLS drop-ins above were just
  ## written by write_files), then fetch THIS member's TLS certificate.
  ## systemctl start blocks until the oneshot fetch completes or fails; on
  ## failure the mongodb-first-boot.service Requires= drop-in (loaded by the
  ## daemon-reload above) aborts first-boot: no certificate, no mongod,
  ## never a plaintext start.
  - systemctl daemon-reload
  - systemctl start mongo-vault-certs.service
  ## Daily renewal timer — fast-path no-op while the cert has margin.
  - systemctl enable --now mongo-vault-renew.timer
  {{- end }}
  ## Trigger first-boot via systemctl start — this detaches mongo-first-boot.sh from the
  ## cloud-init runcmd process group entirely. Running the script inline in runcmd means
  ## any cloud-init session timeout or disconnect kills the script mid-run.
  ## mongodb-first-boot.service is Type=oneshot — systemctl start blocks until it completes.
  ## first-boot (member-0) copies the RS bootstrap env to /etc/mongo-rs-init.env and starts
  ## mongo-rs-init.service, which retries until the RS has a PRIMARY and survives reboots.
  ## No plaintext /tmp copy of the credentials is made any more.
  - systemctl start mongodb-first-boot.service
{{- if include "mongodb-vm.val" (list . "vip.enabled") | eq "true" }}
  ## mongo-primary-probe.service is baked into the image.
  ## Use systemd-run --no-block to avoid deadlocking the runcmd shell:
  ## calling `systemctl start` on a simple service from within a cloud-init runcmd
  ## cgroup causes systemd to wait for the service to become active while the runcmd
  ## is still blocking the same transaction — resulting in a permanent hang.
  - systemd-run --unit=mongo-probe-launcher --no-block /bin/bash -c 'systemctl start mongo-primary-probe.service'
{{- end }}
{{- end }}
