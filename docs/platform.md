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
