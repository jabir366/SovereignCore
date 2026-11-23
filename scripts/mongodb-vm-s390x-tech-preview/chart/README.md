# MongoDB Enterprise Advanced VM s390x Helm Chart

Deploys a MongoDB Enterprise Advanced instance as an OpenShift Virtualization VirtualMachine on IBM Z and LinuxONE (**s390x**) nodes using a bootc-built ContainerDisk or PVC source image. Requires an OpenShift cluster with OpenShift Virtualization (KubeVirt), Containerized Data Importer (CDI), s390x worker nodes, and a `ReadWriteOnce`-capable block StorageClass.

### Cluster Prerequisites for Optional Features
- **Backup (`backup.enabled: true`)**: Requires the **Red Hat OADP (Velero)** operator installed on the target spoke cluster before cluster import.
- **External VIP (`vip.enabled: true`, `vip.lb_type: "external"`) vs Kyverno (`network.blockExternalServices: true`)**:
  - `network.blockExternalServices: true` deploys a Kyverno policy that enforces `ClusterIP`-only services (`mdb-net-03`).
  - If `network.blockExternalServices: true` is enabled, Kyverno must be installed on the spoke cluster, and `vip.enabled` must be `false`.
  - If using MetalLB external VIP (`vip.enabled: true`), keep `network.blockExternalServices: false` (default) to avoid policy rejection.

The chart is deployed by the Sovereign Core catalog broker (`byop-broker`); it is not installed directly with Helm. Packaging and push instructions are in the component README (`mongodb-s390x/README.md` in the catalog repository).

---

## Configuration reference

| Parameter | Description | Default |
|---|---|---|
| `diskImage.sourceContainerDisk` | ContainerDisk image reference in registry (highest priority) | `""` |
| `diskImage.sourceURL` | HTTP URL to the boot disk qcow2 image | `""` |
| `diskImage.sourcePVCName` | Pre-existing PVC name to clone as the boot disk | `""` |
| `diskImage.sourcePVCNamespace` | Namespace of the pre-existing PVC to clone | `""` |
| `diskImage.pullSecret` | Secret containing registry credentials for CDI | `""` |
| `diskImage.certConfigMap` | ConfigMap containing the registry CA certificate for TLS verification | `""` |
| `diskImage.storageClassName` | StorageClass for the VM boot PVC (must support RWO block on s390x) | `ocs-storagecluster-ceph-rbd-virtualization` |
| `diskImage.diskSizeGi` | VM boot disk size in GiB | `25` |
| `vm.cpuCores` | Number of vCPU cores | `2` |
| `vm.memoryGi` | Memory allocation in GiB | `4` |
| `vm.machineType` | Virtual machine type (mandatory for IBM Z) | `s390-ccw-virtio` |
| `mongodb.databaseName` | Application database name | `appdb` |
| `mongodb.databaseUser` | Application database user | `appuser` |
| `mongodb.keyFile` | Shared keyFile content for Replica Set inter-member authentication (auto-generated if empty) | `""` |
| `ha.enabled` | Enable 3-node MongoDB Replica Set High Availability | `false` |
| `ha.replicaCount` | Number of replica set members (must be odd: 3 or 5) | `3` |
| `ha.replicaSetName` | MongoDB replica set name | `rs0` |
| `ha.port` | MongoDB listen port | `27017` |
| `ha.headlessServiceName` | Base name for per-member headless services | `""` |
| `vip.enabled` | Enable MetalLB / NodePort VIP service for HA deployments | `false` |
| `vip.lb_type` | VIP service type: `local` (NodePort) or `external` (LoadBalancer) | `local` |
| `vip.nodePort` | NodePort for local VIP mode (`0` for auto-assign) | `0` |
| `vip.metallbAddressPool` | MetalLB IPAddressPool for external VIP mode | `""` |
| `vip.probe.periodSeconds` | Interval between VM readiness probes (tcpSocket: 27017) | `10` |
| `vip.probe.failureThreshold` | Consecutive failures before marking VM unready | `3` |
| `vip.probe.successThreshold` | Consecutive successes before marking VM ready | `1` |
| `vip.probe.timeoutSeconds` | Probe request timeout | `3` |
| `networkPolicy.enabled` | Enable default-deny NetworkPolicy (mdb-net-02/04) | `true` |
| `serviceAccount.enabled` | Enable dedicated ServiceAccount with minimal RBAC (mdb-rbac-03), shared by VM and Fluentbit | `true` |
| `governance.namespaceLabel.enabled` | Enable sovereignty/control-owner namespace label hook (mdb-gov-01) | `true` |
| `governance.namespaceLabel.controlOwner` | Control owner tag applied to namespace | `tenant` |
| `network.blockExternalServices` | Deploy Kyverno policy blocking NodePort/LoadBalancer Services (mdb-net-03) | `false` |
| `compliance.enableEncryption` | Enable WiredTiger encryption-at-rest (mdb-enc-02) | `false` |
| `compliance.auditLog.enabled` | Enable JSON audit logging in mongod.conf (mdb-aud-01) | `false` |
| `compliance.auditLog.path` | Audit log destination path inside VM guest | `/var/log/mongodb/audit.json` |
| `compliance.auditLog.auditAuthorizationSuccess` | Log successful authorization attempts | `true` |
| `logging.rsyslog.enabled` | Enable rsyslog configuration drop-in inside VM guest | `false` |
| `logging.rsyslog.forwarding.enabled` | Enable remote syslog forwarding | `false` |
| `logging.rsyslog.forwarding.host` | Remote syslog collector hostname or IP | `""` |
| `logging.rsyslog.forwarding.port` | Remote syslog collector port | `514` |
| `logging.rsyslog.forwarding.protocol` | Syslog transport protocol (`tcp` / `udp`) | `tcp` |
| `logging.rsyslog.forwarding.format` | Syslog message format (`rfc5424` / `rfc3164`) | `rfc5424` |
| `logging.fluentbit.enabled` | Deploy Fluent-bit DaemonSet for log collection and shipping (mdb-aud-05) | `false` |
| `logging.fluentbit.siemEndpoint` | SIEM collector endpoint | `""` |
| `logging.fluentbit.siemPort` | SIEM collector port | `5044` |
| `logging.fluentbit.tlsEnabled` | Enable TLS for Fluent-bit forwarding | `true` |
| `backup.enabled` | Enable Velero VolumeSnapshotSchedule for automated VM backup (mdb-dr-01) | `false` |
| `backup.schedule` | Cron schedule for snapshot backups | `0 2 * * *` |
| `backup.retention` | Backup snapshot retention duration | `720h` |
| `backup.storageLocation` | Velero backup storage location | `default` |
| `monitoring.enabled` | Deploy PrometheusRule for Replica Set health alerts (mdb-rs-01) | `false` |
| `monitoring.alerts.replicaSetNotHealthy.enabled` | Enable alert for unhealthy Replica Set state | `true` |
| `monitoring.alerts.primaryFailover.enabled` | Enable alert for primary member failover events | `true` |
| `concert.enabled` | Enable IBM Concert automated security & compliance scanning (mdb-con-01) | `false` |
| `concertSSHKeySecret` | Name of pre-existing Concert SSH key Secret (empty = auto-generate per instance) | `""` |
| `sshAuthorizedKeys` | Optional additional operator SSH public keys | `[]` |
| `imagePullSecrets` | Pre-existing image pull secrets for container registry | `[]` |
| `instance.name` | Instance name used in resource names (`<name>-mongodb-...`); falls back to release name | `""` |
| `instance.id`, `instance.environment`, `instance.clusterName` | Broker-injected metadata labels / annotations | `""` |
| `namespaceOverride` | Namespace written into manifests | `""` |
| `nameOverride`, `fullnameOverride` | Override resource naming | `""` |
| `database_name`, `database_user`, `database_password`, `admin_password`, `storage_class_name`, `storage_size_gi`, `instance_name` | Flat values passed by the broker. When set they take precedence via template overrides | unset |

The chart creates a `Secret` named `<instance>-mongodb-creds` holding `admin_password`, `app_password`, `database`, `username`, `connection-string`, `primary-service`, and `rs-connection-string`. Inside the cluster the database is reachable at `<instance>-mongodb-0.<namespace>.svc:27017` (standalone or per-member headless service) or `<instance>-mongodb-vip.<namespace>.svc:27017` (when HA VIP is enabled).

---

## Broker deployment behaviour (byop-broker)

The broker renders `template/values.yaml.tmpl` into a Helm values override and deploys the chart with it:

- Credentials (admin and application user passwords) are auto-generated and passed securely; they are stored in the spoke cluster's credentials Secret and never written to Git or static templates.
- Key inter-member replica set authentication `keyFile` is automatically generated per deployment and distributed via Secret.
- The boot disk container image reference (`diskImage.sourceContainerDisk`) is populated from the broker's configured container registry mirror.
- Image pull secrets (`imagePullSecrets`) are passed from the catalog provisioning parameters if authentication is required.

---

## Node scheduling

`virtualmachine.yaml` enforces `nodeSelector: kubernetes.io/arch: s390x` and `machineType: s390-ccw-virtio`, so the VM only schedules on IBM Z / LinuxONE worker nodes supporting KubeVirt with CCW bus devices. If the cluster has no schedulable s390x nodes with virtualization capabilities, the VM stays `Pending`.

## OpenShift Virtualization storage and permissions

The boot disk is dynamically provisioned as a `DataVolume` (CDI) into a PVC with `accessModes: [ReadWriteOnce]` and `volumeMode: Block` (or `Filesystem` depending on StorageClass). Storage encryption at rest (mdb-enc-05) is supported using Ceph RBD encrypted storage classes (e.g. `ocs-storagecluster-ceph-rbd-encrypted`).
