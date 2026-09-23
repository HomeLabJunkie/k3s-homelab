# Operator laptop setup

Use the existing operator workstation as the reference, preserving its pending
working-tree changes when transferring the repository. Keep credentials and
local configuration out of Git.

## Omarchy tools

```bash
omarchy pkg add kubectl helm github-cli sops age direnv argon2
cd ~/Work/k3s-homelab
python -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
source .venv/bin/activate
./scripts/ensure-ansible-collections.sh
```

To match the ThinkPad's automatic activation, add `eval "$(direnv hook bash)"`
to `~/.bashrc` once, review the repo's `.envrc`, and run `direnv allow` in the
repository. Open a new terminal for the shell hook to take effect.

Versions matched to the ThinkPad on 2026-09-17: kubectl 1.36.4, Helm 4.2.2,
GitHub CLI 2.100.0, SOPS 3.13.3, age 1.3.2, and direnv 2.37.1. Python
dependencies and Ansible collections are pinned by the repository.

## Access and local files

Provision these through an authenticated private channel, with explicit approval
before copying existing private credentials:

- `~/.kube/config` for Kubernetes access.
- A cluster SSH key and host configuration for the six nodes and `k3s-dr`.
- `~/.config/sops/age/keys.txt` for the encrypted secrets file.
- Ignored repo files: `config/cluster.env`, `inventory/k3s-ansible/hosts.ini`,
  `.secrets.enc`, and any locally configured email settings.
- Helm repository configuration, including `https://traefik.github.io/charts`.

Use mode `700` for credential directories and `600` for private keys and
kubeconfig. Do not print credentials, commit them, or copy them into documentation.
GitHub and Fortress access are separate capabilities; provision them separately
when required. Installing `gh` does not authenticate it.

## Verification

```bash
source .venv/bin/activate
kubectl get nodes
helm list -A
./repo-doctor.sh --quick
./deploy.sh --preflight-only
./workstation-readiness.sh
```

Full readiness includes SSH maintenance checks, backup verification, and DR
validation. Tool installation alone does not establish workstation readiness.
Preserve any warnings and failed checks in the handoff record.

## Laptop handoff — 2026-09-17

The repository and pending working-tree changes were copied from the ThinkPad
to `~/Work/k3s-homelab`. The tools and project dependencies above were installed,
and automatic environment activation was enabled.

With explicit approval, the kubeconfig, cluster SSH private key, and SOPS age
key were transferred privately and stored with mode `600`. Cluster node and
`k3s-dr` SSH configuration and Helm repositories were provisioned. GitHub and
Fortress private keys remain on the ThinkPad; GitHub authentication on this
laptop is still pending.

Verified directly from this laptop:

- Kubernetes API access with all six nodes Ready.
- Cluster-node and DR-host SSH access, and SOPS decryption.
- Deployment preflight, production backup verification, DR readiness checks,
  and the plan-only DR rehearsal.
- Ansible 2.21.3 / Python 3.14.7 and all four pinned Ansible collections.

The first full readiness run hit exit `141` in the maintenance node lookup.
The lookup now consumes the complete `kubectl` output instead of closing its
pipe early. Maintenance regression tests cover streamed node output.
The rerun passed on all six nodes with no node changes. Together with the
completed readiness stages, this establishes workstation readiness with the
repository warnings below. The original failed report remains intact at
`logs/readiness/workstation-readiness-20260917-132250.log`; the successful
maintenance rerun is recorded at
`logs/maintenance/maintain-cluster-20260917-132425.log`.
Repository checks warn about preserved uncommitted changes and unavailable
GitHub fetch authentication. DR status warns about the uncommitted changes.
