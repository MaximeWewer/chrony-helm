# chrony-helm

Helm chart for a hardened [chrony](https://chrony-project.org) NTP/NTS server
on Kubernetes, built on the distroless, non-root image from
[chrony-docker](https://github.com/maximewewer/chrony-docker).

```sh
helm install chrony oci://ghcr.io/maximewewer/charts/chrony -n time --create-namespace
helm test -n time chrony
```

- **Three shapes** - Deployment (default), StatefulSet (drift and NTS cookies
  survive restarts), DaemonSet (node-local time, or node clock discipline on
  the host network).
- **NTS both ways** - authenticated upstreams by default; NTS server with a
  cert-manager or existing certificate, and cookie keys shared by every
  replica so a client may hit any of them.
- **Hardened by default** - uid 65532, read-only root filesystem, every
  capability dropped, seccomp (RuntimeDefault + chronyd's own filter), no
  service account token, port 123 through the namespaced
  `ip_unprivileged_port_start` sysctl instead of a capability.
- **Operable** - probes that query the server like a real client, a config
  check init container that shows the exact chrony.conf, `helm test`, an
  ntp-exporter sidecar with ServiceMonitor and alerts, NetworkPolicy, PDB.

Full documentation and the values reference: [charts/chrony](charts/chrony/README.md).

## Layout

```
charts/chrony/              the chart
charts/chrony/ci/           one values file per supported shape - rendered,
                            validated and (for the bare-cluster ones) installed by CI
scripts/check-manifests.py  structural checks helm lint does not do
Makefile                    docs, lint, template, kubeconform, e2e
.github/workflows/          lint-test (every PR), release-helm (CalVer to GHCR)
```

## Development

```sh
make docs          # regenerate charts/chrony/README.md (helm-docs)
make lint template # lint + render/check every ci/*-values.yaml
make kubeconform   # schema validation (docker)
make e2e           # install on the current context and run helm test
```

## License

MIT
