# Platform components

[Back to the README](../README.md)

Networking, ingress, certificates and storage. Environment-specific addresses
come from `config/cluster.env`.

## Networking

K3s is installed with the built-in Flannel and Traefik components disabled so that networking and ingress are managed explicitly.

Current networking flow:

```text
Clients / Cloudflare
        |
        v
Cloudflare Tunnel / LAN
        |
        v
MetalLB service address
        |
        v
Traefik
        |
        v
Kubernetes Services / Pods
```

The Kubernetes API is exposed through a kube-vip virtual IP:

```text
kubectl / automation
        |
        v
kube-vip :6443
        |
        +---- K3s server 0
        +---- K3s server 1
        +---- K3s server 2
```

Cilium provides pod networking and Hubble provides network observability. MetalLB is configured in Layer 2 mode for service load-balancer addresses.

## Cilium and Hubble

Cilium is the active CNI.

The current configuration uses:

- native routing mode
- cluster CIDR `10.42.0.0/16`
- Hubble enabled
- kube-proxy-compatible K3s networking configuration
- Flannel disabled

### Watching traffic with Hubble

Hubble records every connection Cilium handles, with the pods on each end and
whether policy allowed it. The relay and UI run in `kube-system`. The UI is
not published; reach it with
`kubectl -n kube-system port-forward svc/hubble-ui 12000:80` and open
<http://localhost:12000>. From the command line, the Cilium agent carries the
`hubble` client:

```bash
RELAY="$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}')"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --server "$RELAY:80" --namespace website --verdict DROPPED -f
```

Each node keeps only its last few thousand flows, about a minute on this
cluster, so follow (`-f`) while the traffic happens.

### Network policies

`apps/network-policies/` holds standard Kubernetes NetworkPolicies, applied by
`deploy.sh` and enforced by Cilium. A namespace listed there denies all
traffic by default and allows only what its file names. Namespaces without a
file are unrestricted.

| Namespace | Allowed in | Allowed out |
| --- | --- | --- |
| `website` | Traefik to nginx (8080) and fb-search (8000); Prometheus to fb-search metrics (9100) | Cluster DNS; git-sync to the internet on 22 (GitHub); fb-search to the internet on 443 |
| `cloudflared` | Prometheus to the metrics port (20241) | Cluster DNS; the internet on 7844 (Cloudflare's edge) and 443 (its API); Traefik's pods on 8000 and 8443 |
| `trilium` | Traefik to Trilium (8080); pods in the same namespace | Cluster DNS; the internet on 443; pods in the same namespace |
| `vaultwarden` | Traefik to Vaultwarden (8080); pods in the same namespace | Cluster DNS; the internet on 443 and 587 (mail through Gmail); pods in the same namespace |

"The internet" excludes the private ranges, so these pods cannot reach the
home network, the nodes, the Kubernetes API or other pods. The kubelet's
probes need no rule: Cilium always lets a node reach its own pods.

Three details that are easy to trip over:

- The tunnel's origin is Traefik's load-balancer address, `192.168.0.200:443`.
  Cilium translates that to a Traefik pod before it checks policy, so the
  cloudflared rule names the Traefik pods and their container ports (8000 and
  8443), not the address.
- Trilium and Vaultwarden allow traffic within their own namespace because
  `recovery/restore.sh --health-check` starts a pod there that calls the
  application's Service.
- cloudflared's ICMP probes to the internet at start-up are dropped. Only its
  optional ICMP proxying uses them, which this tunnel does not.

To write policies for another namespace without risking an outage:

1. Record what it does: `hubble observe --namespace <ns> -f` while using the
   application.
2. Put its endpoints in audit mode, so policy is evaluated but nothing is
   dropped. On the node running each pod:
   `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled`, with the ID from
   `kubectl -n <ns> get ciliumendpoints`.
3. Apply the policies and watch `hubble observe --namespace <ns> --verdict AUDIT`.
   Anything listed would have been dropped.
4. When only unwanted traffic is listed, set `PolicyAuditMode=Disabled`.

Audit mode is per pod and is lost when the pod restarts, after which the
policy is enforced. Deleting the policies restores open networking at once:
`kubectl delete -f apps/network-policies/<namespace>.yaml`.

## kube-vip

kube-vip provides the highly available Kubernetes API endpoint across the K3s server nodes.

The API VIP is loaded from:

```text
KUBE_VIP
```

in `config/cluster.env`.

`KUBE_VIP` has no documentation-address fallback in normal operation.
Deployment stops before Ansible if the value is missing, invalid, unusable, or
in the `192.0.2.0/24` TEST-NET range. The kube-vip manifest renders the
validated address explicitly rather than allowing an empty `address` value.

## MetalLB

MetalLB provides Kubernetes `LoadBalancer` service addresses.

Current mode:

```text
Layer 2
```

The pool is supplied through:

```text
METALLB_IP_RANGE
```

## Traefik

Traefik is installed separately with Helm rather than using the K3s bundled Traefik.

It handles application ingress and TLS-enabled service exposure.

Routes that use a Traefik middleware are `IngressRoute` objects, not Kubernetes
`Ingress` objects: Longhorn, Grafana, Prometheus, Trilium, the
`www` redirect and the Traefik dashboard. Traefik reads Ingresses and its own
CRDs through two separate providers. At startup the Ingress routes used to load
a moment before the middlewares, and each one logged
`middleware "...@kubernetescrd" does not exist` (harmless, since the pod was not
Ready yet). IngressRoutes and Middlewares load together, so the errors are
gone. Routes without a middleware (Authelia, Rancher, Vaultwarden, the website)
are still Ingresses. `deploy.sh` removes the replaced Ingress after applying
each IngressRoute.

Chart upgrades and value changes are recorded in the [changelog](CHANGELOG.md).

## cert-manager

cert-manager issues and renews certificates using the configured Let's Encrypt `ClusterIssuer`.

Cloudflare API credentials are loaded from the encrypted/local secrets file and are not committed to the repository.

## Cloudflare Tunnel

A Cloudflare Tunnel provides external connectivity without exposing the Kubernetes nodes directly.

The tunnel token is injected into a Kubernetes Secret during deployment.

The pods run with a restricted security context: the image's non-root user
(65532), a read-only root filesystem, no Linux capabilities, no privilege
escalation, and the runtime's default seccomp profile.

## Authelia

Authelia is the login portal in front of the admin UIs. See [Authelia](authelia.md).

## Longhorn storage

Longhorn is the default Kubernetes StorageClass.

All K3s nodes are prepared for dedicated Longhorn storage at:

```text
/var/lib/storage/longhorn
```

The deployment process:

1. Runs `longhorn-host-prep.yml` on the nodes.
2. Annotates each Kubernetes node with the Longhorn disk configuration.
3. Installs Longhorn with Helm.
4. Waits for managers, drivers, UI, and pods.
5. Verifies every node has the expected dedicated storage path.
6. Makes `longhorn` the default StorageClass.
7. Removes default status from `local-path`.

Persistent application data is intentionally stored on Longhorn so it can be protected through Longhorn backup and restored independently during DR.
