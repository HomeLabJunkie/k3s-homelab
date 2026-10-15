#!/usr/bin/env bash
# Removes Rancher and everything it installed by itself from the cluster
# kubectl points at: Fleet, Turtles and Cluster API, its webhook, the system
# upgrade controller, their CRDs and objects, namespaces and RBAC.
#
# Rancher's own rancher-cleanup script is not used: it also deletes every
# ClusterRole named monitoring-* or logging-* and every Prometheus Operator
# object and CRD, which here belong to kube-prometheus-stack and Loki.
#
# K3s's own helm.cattle.io and k3s.cattle.io APIs are never touched.
#
# Usage:
#   scripts/remove-rancher.sh            plan: list what would be deleted
#   scripts/remove-rancher.sh --execute  delete it (asks to type REMOVE RANCHER)
#   scripts/remove-rancher.sh --execute --yes
#
# Run it after the rancher application is gone from git, so Argo CD does not
# put Rancher back. It can be run again; each step skips what is already gone.
set -Eeuo pipefail

EXECUTE=false
YES=false
for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=true ;;
    --yes) YES=true ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Helm releases Rancher installs for itself, and its own chart.
RELEASES_RE='^(rancher|rancher-webhook|rancher-turtles|system-upgrade-controller|fleet|fleet-crd|fleet-agent-local)$'
# Namespaces Rancher creates: its own, Fleet's, its projects (p-xxxxx), its
# users (user-xxxxx) and its local cluster.
NAMESPACE_RE='^(cattle-[a-z0-9-]+|fleet-default|fleet-local|cluster-fleet-[a-z0-9-]+|local|p-[a-z0-9]{5}|user-[a-z0-9]{5})$'
# API groups of Rancher's CRDs: every *.cattle.io except K3s's own two, and
# Cluster API, which Rancher's Turtles installed.
CRD_GROUP_RE='(^|\.)(cattle\.io|cluster\.x-k8s\.io)$'
KEEP_GROUP_RE='^(helm|k3s)\.cattle\.io$'
# Label and annotation keys that only Rancher writes. objectset.rio.cattle.io
# is not one: K3s writes it too.
MARK_RE='^(cattle\.io/(creator|status)|lifecycle\.cattle\.io/|authz\.(cluster|management)\.cattle\.io/|management\.cattle\.io/|field\.cattle\.io/|fleet\.cattle\.io/)'
# ClusterRole and ClusterRoleBinding names Rancher, Fleet and Turtles use.
RBAC_NAME_RE='^(cattle-|fleet|gitjob|helmops|capi-|rancher|provisioning-rke|rke2-machineconfig|pod-impersonation-helm-|grb-|crb-|p-[a-z0-9]{5}-namespaces-|pre-upgrade-job-delete-clusterctl-configmap$|local-cluster(owner|member)$|cluster-owner$|u-[a-z0-9]{10}-view$|user-[a-z0-9]{5}-view$)'

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# kubectl delete that clears finalizers first, so nothing waits for a
# controller that is already gone.
force_delete() {
  local -a ns_args=()
  if [[ "$1" == "-n" ]]; then ns_args=(-n "$2"); shift 2; fi
  kubectl "${ns_args[@]}" patch "$@" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  kubectl "${ns_args[@]}" delete "$@" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

kubectl version --request-timeout=10s >/dev/null || { echo "ERROR: cannot reach the cluster" >&2; exit 1; }
say "Cluster: $(kubectl config current-context)"

# --- Guard: Argo CD must no longer want Rancher ------------------------------
wanted="$(kubectl -n argocd get applications.argoproj.io root -o json 2>/dev/null |
  python3 -c 'import json,sys
d=json.load(sys.stdin)
print(any(r.get("kind")=="Application" and r.get("name")=="rancher" and not r.get("requiresPruning") for r in d.get("status",{}).get("resources",[])))' || echo unknown)"
if [[ "$wanted" == "True" ]]; then
  if $EXECUTE; then
    echo "ERROR: the root application still deploys rancher. Merge the change that removes it from git first." >&2
    exit 1
  fi
  say "NOTE: the root application still deploys rancher; --execute will refuse until that is merged."
fi

# --- What is there -------------------------------------------------------------
namespaces="$(kubectl get namespaces -o name | sed 's#namespace/##' | grep -E "$NAMESPACE_RE" || true)"
releases="$(helm list -A --no-headers 2>/dev/null | awk '{print $1" "$2}' | while read -r r n; do
  [[ "$r" =~ $RELEASES_RE ]] && echo "$n/$r"; done || true)"
crds="$(kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name} {.spec.group}{"\n"}{end}' |
  while read -r name group; do
    [[ "$group" =~ $CRD_GROUP_RE && ! "$group" =~ $KEEP_GROUP_RE ]] && echo "$name"
  done || true)"
webhooks="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json |
  NAMESPACE_RE="$NAMESPACE_RE" python3 -c 'import json,os,re,sys
ns=re.compile(os.environ["NAMESPACE_RE"])
for i in json.load(sys.stdin)["items"]:
    svc=[w.get("clientConfig",{}).get("service",{}).get("namespace","") for w in i.get("webhooks",[])]
    if i["metadata"]["name"]=="rancher.cattle.io" or any(ns.match(s) for s in svc if s):
        print(i["kind"].lower()+"/"+i["metadata"]["name"])')"
apiservices="$(kubectl get apiservices -o json |
  NAMESPACE_RE="$NAMESPACE_RE" python3 -c 'import json,os,re,sys
ns=re.compile(os.environ["NAMESPACE_RE"])
for i in json.load(sys.stdin)["items"]:
    s=i["spec"].get("service") or {}
    if s and ns.match(s.get("namespace","")):
        print(i["metadata"]["name"])')"
rbac="$(kubectl get clusterroles,clusterrolebindings -o json |
  MARK_RE="$MARK_RE" RBAC_NAME_RE="$RBAC_NAME_RE" RELEASES_RE="$RELEASES_RE" python3 -c 'import json,os,re,sys
mark=re.compile(os.environ["MARK_RE"]); name=re.compile(os.environ["RBAC_NAME_RE"]); rel=re.compile(os.environ["RELEASES_RE"])
for i in json.load(sys.stdin)["items"]:
    m=i["metadata"]
    keys=list(m.get("labels") or {})+list(m.get("annotations") or {})
    owned=any(re.search(r"(cattle\.io|cluster\.x-k8s\.io)/",o.get("apiVersion","")) and not re.search(r"(helm|k3s)\.cattle\.io/",o["apiVersion"]) for o in m.get("ownerReferences") or [])
    helm=bool(rel.match((m.get("annotations") or {}).get("meta.helm.sh/release-name","")))
    if name.match(m["name"]) or owned or helm or any(mark.match(k) for k in keys):
        print(i["kind"].lower()+"/"+m["name"])')"
extras="$(
  kubectl -n kube-system get configmap cattle-controllers -o name 2>/dev/null || true
  kubectl get priorityclass rancher-critical -o name 2>/dev/null || true
)"
app="$(kubectl -n argocd get applications.argoproj.io rancher -o name 2>/dev/null || true)"

count() { if [[ -z "$1" ]]; then echo 0; else wc -l <<<"$1" | tr -d ' '; fi; }
step "Plan"
say "Argo CD application:   ${app:-none}"
say "Helm releases ($(count "$releases")):     $(tr '\n' ' ' <<<"$releases")"
say "Webhooks ($(count "$webhooks")):          $(tr '\n' ' ' <<<"$webhooks")"
say "API services ($(count "$apiservices")):      $(tr '\n' ' ' <<<"$apiservices")"
say "CRDs ($(count "$crds")), with every object of each kind"
say "Namespaces ($(count "$namespaces")):        $(tr '\n' ' ' <<<"$namespaces")"
say "ClusterRoles and bindings ($(count "$rbac")):"
while read -r line; do say "  $line"; done <<<"$rbac"
say "Other:                 $(tr '\n' ' ' <<<"$extras")"
say "Rancher's labels and annotations are removed from the namespaces that stay."

if ! $EXECUTE; then
  say ""
  say "Nothing was changed. Run with --execute to delete the above."
  exit 0
fi
if ! $YES; then
  read -r -p "Type REMOVE RANCHER to continue: " answer
  [[ "$answer" == "REMOVE RANCHER" ]] || { echo "Cancelled."; exit 1; }
fi

# --- 1. Stop everything that would recreate what follows ----------------------
step "Removing the Argo CD application and stopping Rancher's controllers"
if [[ -n "$app" ]]; then
  # Without its finalizer Argo CD deletes only the Application, not what it
  # deployed; the steps below remove that.
  force_delete -n argocd applications.argoproj.io rancher
fi
for ns in $namespaces; do
  kubectl -n "$ns" delete deployments,daemonsets,statefulsets,jobs,cronjobs --all \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
for ns in $namespaces; do
  kubectl -n "$ns" wait --for=delete pod --all --timeout=180s >/dev/null 2>&1 || true
done

# --- 2. Webhooks, so nothing blocks the deletes --------------------------------
step "Deleting webhooks"
for w in $webhooks; do force_delete "$w"; say "  $w"; done

# --- 3. Helm releases, without their hooks ------------------------------------
step "Uninstalling Helm releases"
for nr in $releases; do
  helm uninstall "${nr#*/}" -n "${nr%%/*}" --no-hooks --timeout 2m >/dev/null 2>&1 || true
  say "  $nr"
done

# --- 4. Aggregated APIs served from the namespaces about to go ----------------
step "Deleting API services"
for a in $apiservices; do force_delete apiservice "$a"; say "  $a"; done

# --- 5. Every object of each Rancher CRD, then the CRD ------------------------
step "Deleting CRDs and their objects"
for crd in $crds; do
  scope="$(kubectl get crd "$crd" -o jsonpath='{.spec.scope}' 2>/dev/null || true)"
  [[ -n "$scope" ]] || continue
  if [[ "$scope" == "Namespaced" ]]; then
    kubectl get "$crd" -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null |
      while read -r ns name; do [[ -n "$name" ]] && force_delete -n "$ns" "$crd" "$name"; done
  else
    kubectl get "$crd" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
      while read -r name; do [[ -n "$name" ]] && force_delete "$crd" "$name"; done
  fi
  force_delete crd "$crd"
done
for _ in {1..30}; do
  left="$(kubectl get crd -o jsonpath='{range .items[*]}{.spec.group}{"\n"}{end}' |
    grep -E "$CRD_GROUP_RE" | grep -Evc "$KEEP_GROUP_RE" || true)"
  [[ "$left" == 0 ]] && break
  sleep 2
done
say "  $(count "$crds") CRDs deleted; ${left:-0} still terminating"

# --- 6. Namespaces --------------------------------------------------------------
step "Deleting namespaces"
for ns in $namespaces; do
  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
for ns in $namespaces; do
  if ! kubectl wait --for=delete "namespace/$ns" --timeout=90s >/dev/null 2>&1; then
    # Stuck on objects whose controller is gone: clear their finalizers.
    for kind in $(kubectl api-resources --namespaced --verbs=list -o name 2>/dev/null); do
      kubectl -n "$ns" get "$kind" -o name 2>/dev/null | while read -r obj; do
        force_delete -n "$ns" "$obj"
      done
    done
    kubectl wait --for=delete "namespace/$ns" --timeout=60s >/dev/null 2>&1 ||
      say "  WARNING: namespace $ns is still terminating"
  fi
  say "  $ns"
done

# --- 7. Cluster-wide RBAC and the rest -----------------------------------------
step "Deleting ClusterRoles, bindings and other leftovers"
for r in $rbac $extras; do force_delete "$r"; done
say "  $(count "$rbac") RBAC objects, $(count "$extras") others"

step "Removing Rancher's labels and annotations from the remaining namespaces"
kubectl get namespaces -o json | MARK_RE="$MARK_RE" python3 -c 'import json,os,re,sys
mark=re.compile(os.environ["MARK_RE"])
for i in json.load(sys.stdin)["items"]:
    m=i["metadata"]
    for kind in ("labels","annotations"):
        keys=[k for k in (m.get(kind) or {}) if mark.match(k)]
        if keys: print(kind, m["name"], " ".join(k+"-" for k in keys))' |
  while read -r kind ns keys; do
    # shellcheck disable=SC2086 # one argument per key
    if [[ "$kind" == labels ]]; then
      kubectl label namespace "$ns" $keys >/dev/null
    else
      kubectl annotate namespace "$ns" $keys >/dev/null
    fi
  done

# --- 8. Check -------------------------------------------------------------------
step "Checking"
status=0
if ! kubectl api-resources >/dev/null 2>"${TMPDIR:-/tmp}/remove-rancher-discovery.$$"; then
  say "  FAIL: API discovery reports errors:"; sed 's/^/    /' "${TMPDIR:-/tmp}/remove-rancher-discovery.$$"; status=1
fi
rm -f "${TMPDIR:-/tmp}/remove-rancher-discovery.$$"
for crd in helmcharts.helm.cattle.io helmchartconfigs.helm.cattle.io addons.k3s.cattle.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 || { say "  FAIL: K3s's $crd is missing"; status=1; }
done
left_ns="$(kubectl get namespaces -o name | sed 's#namespace/##' | grep -E "$NAMESPACE_RE" || true)"
[[ -z "$left_ns" ]] || { say "  FAIL: namespaces left: $(tr '\n' ' ' <<<"$left_ns")"; status=1; }
left_crd="$(kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name} {.spec.group}{"\n"}{end}' |
  awk '{print $2" "$1}' | grep -E "^[^ ]*(cattle\.io|cluster\.x-k8s\.io) " | grep -Ev '^(helm|k3s)\.cattle\.io ' || true)"
[[ -z "$left_crd" ]] || { say "  FAIL: CRDs left: $(awk '{print $2}' <<<"$left_crd" | tr '\n' ' ')"; status=1; }
unavailable="$(kubectl get apiservices --no-headers | awk '$3 != "True" {print $1}')"
[[ -z "$unavailable" ]] || { say "  FAIL: API services not available: $unavailable"; status=1; }
if [[ "$status" == 0 ]]; then
  say "  Rancher is gone; K3s's own APIs are intact."
fi
exit "$status"
