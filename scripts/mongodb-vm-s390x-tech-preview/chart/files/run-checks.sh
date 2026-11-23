#!/bin/bash
# In-cluster runner for the MongoDB VM compliance checks.
#
# Runs as a CronJob (or on demand) in the instance namespace. For each VM
# Service in VM_SERVICES it pipes vm_checks.sh over SSH (pod network, port 22)
# as cloud-user, the same user Concert uses, and stores the output. Results are
# written to the ConfigMap RESULTS_CM. Concert reads that ConfigMap through the
# cluster API. No port is opened on the node network.
#
# Host keys: VM host keys are generated at first boot and are not known to the
# chart, so they are trusted on first use (accept-new) per run. The Service
# names resolve only inside the cluster, so the risk is limited to the pod
# network. Pinning them needs the keys to be set in cloud-init (see docs).
#
# Env:
#   VM_SERVICES   space-separated per-VM ClusterIP Service names
#   RESULTS_CM    results ConfigMap name
#   NAMESPACE     release namespace
#   SSH_KEY       private key path (mounted from <instance>-concert-ssh)
#   CHECK_SCRIPT  vm_checks.sh path (mounted from the chart ConfigMap)
#   CLUSTER_NAME, INSTANCE_NAME  stamps written into the results
set -u

KEY=/tmp/concert_key
cp "$SSH_KEY" "$KEY" && chmod 0600 "$KEY"
SSH_OPTS="-i $KEY -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VM_COUNT=$(echo $VM_SERVICES | wc -w)

# The ConfigMap is pre-created by the chart. Write it with a merge patch against
# the in-cluster API, using curl and the pod's ServiceAccount token. This needs
# only the patch verb (the Role grants no create) and no oc binary. Every write
# carries the same runId so a reader can tell this run apart from a stale one.
# Per-VM keys are fixed for a given VM set, so a rerun overwrites them in place.
write_cm() {
  local status="$1" finished="$2"; shift 2
  local data
  data=$(python3 - "$status" "$RUN_ID" "$STARTED" "$finished" "$VM_COUNT" "$@" <<'PY'
import json, os, sys
status, run_id, started, finished, vm_count, *pairs = sys.argv[1:]
data = {"status": status, "runId": run_id, "startedAt": started,
        "finishedAt": finished, "clusterName": os.environ.get("CLUSTER_NAME", ""),
        "instanceName": os.environ.get("INSTANCE_NAME", ""), "vmCount": vm_count}
for p in pairs:
    k, v = p.split("=", 1)
    data[k] = v
print(json.dumps({"data": data}))
PY
)
  local SA=/var/run/secrets/kubernetes.io/serviceaccount
  curl -sS --fail --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" \
    -H "Content-Type: application/merge-patch+json" -X PATCH --data "$data" \
    "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}/api/v1/namespaces/${NAMESPACE}/configmaps/${RESULTS_CM}" > /dev/null
}

write_cm running "" 

FAILED=0; ARGS=()
for SVC in $VM_SERVICES; do
  OUT=$(ssh $SSH_OPTS cloud-user@"$SVC.$NAMESPACE.svc.cluster.local" "SUDO=1 bash -s" < "$CHECK_SCRIPT" 2>&1)
  RC=$?
  [ $RC -ne 0 ] && FAILED=1
  ARGS+=("$SVC.txt=$OUT" "$SVC.rc=$RC")
done

write_cm complete "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ARGS[@]}" || FAILED=1
rm -f "$KEY"
exit $FAILED
