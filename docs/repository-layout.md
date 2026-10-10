# Repository layout

[Back to the README](../README.md)

```text
.
├── README.md
├── docs/                           # Reference documentation (start at README.md)
├── deploy.sh                       # End-to-end production deployment
├── dr-status.sh                    # Read-only DR readiness dashboard
├── repo-doctor.sh                  # Aggregate repo + DR readiness report
├── workstation-readiness.sh        # Operator workstation preflight
├── maintain-cluster.sh             # Safe rolling cluster maintenance wrapper
├── maintain-node.sh                # Single-node maintenance (toolchain-gated)
├── update-os.sh                    # Rolling OS package updates
├── workflow-check.sh               # Validate lifecycle entry points, no changes
├── site.yml                        # Explicit initial/bootstrap provisioning
├── reset.sh / reboot.sh            # ansible-playbook wrappers
├── ansible.cfg
├── requirements.in / requirements.txt  # pip-compile source + lock
├── collections/requirements.yml    # Pinned Ansible collections
├── maintenance/
│   ├── reconcile-existing-cluster.yml   # Safe normal cluster reconciliation
│   ├── reconcile-k3s-server.yml         # Safe single-server reconciliation
│   └── reconcile-k3s-agent.yml          # Safe single-agent reconciliation
├── inventory/
│   ├── k3s-ansible/                # group_vars/ + hosts.ini.template
│   └── sample/
├── roles/                          # K3s / host Ansible roles
├── molecule/                       # Scenario tests (default, cilium, calico, …)
├── config/
│   ├── cluster.env.example         # Non-secret environment template
│   ├── email.env.example
│   └── toolchain.env               # Supported ansible-core / Python ranges
├── scripts/
│   ├── check-ansible-toolchain.sh          # Gates deploy.sh / maintain-node.sh
│   ├── check-requirements-toolchain-sync.sh # CI: requirements.in ↔ toolchain.env
│   ├── ensure-ansible-collections.sh
│   ├── render-config.sh / prepare-env.sh / run-deploy.sh
│   ├── scan-secrets.sh                     # CI secret/config scan
│   ├── validate-manifests.sh               # kubeconform against the cluster's CRDs
│   └── install-velero-backup.sh
├── apps/                           # longhorn/ trilium/ (Helm values / manifests)
├── templates/                      # envsubst sources rendered to rendered/
├── manifests/backup/              # Longhorn snapshot class, recurring + Velero schedules
├── backup/                         # backup.sh, remote-storage.sh, verify-*.sh
├── monitoring/                     # dr-monitor.sh, dr-notify.sh
├── systemd/                        # k3s-dr backup/verify/monitor/Velero+Longhorn canaries
├── tests/                          # Shell safety tests run by repo-safety.yml
├── recovery/
│   ├── DR-RUNBOOK.md
│   ├── apps.conf
│   ├── dr-preflight.sh
│   ├── dr-find-backups.sh
│   ├── dr-generate-restore.sh
│   ├── dr-validate-generated.sh
│   ├── dr-plan.sh
│   ├── dr-apply-restore.sh
│   ├── dr-bind-restores.sh
│   ├── dr-generate-validation.sh
│   ├── dr-apply-validation.sh
│   ├── dr-validate-apps.sh
│   ├── dr-cleanup.sh
│   └── dr-rehearsal.sh
├── .sops.yaml
└── .github/                        # workflows/ + dependabot.yml
```

Additional manifests and Helm values at the repository root (`traefik-*.yaml`,
`longhorn-*.yaml`, `monitoring-*.yaml`, `loki-values.yaml`, `alloy-values.yaml`,
`trilium-*.yaml`, `vaultwarden-*.yaml`, `cloudflared*.yaml`,
`clusterissuer-letsencrypt.yaml`, `website.yaml`, dashboards, and ingress files)
define Traefik, Longhorn, monitoring, logging, Trilium, Vaultwarden,
Cloudflare, certificates, and ingress behavior used by `deploy.sh`. Many are
environment-specific and generated from `templates/`, so they are git-ignored.
