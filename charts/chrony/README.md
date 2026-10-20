# chrony

Hardened chrony NTP/NTS server for Kubernetes - distroless, non-root,
seccomp-filtered chronyd as a Deployment, StatefulSet or DaemonSet, with
NTS (client and server), shared NTS cookie keys across replicas,
cert-manager integration and an ntp-exporter sidecar.

The image is [chrony-docker](https://github.com/maximewewer/chrony-docker)
(`ghcr.io/maximewewer/chrony-docker`):
static chronyd/chronyc on distroless, uid 65532, seccomp filter on, command
port disabled (Unix socket only). The chart drives its `chrony-entrypoint`
through environment variables - it never templates a chrony.conf unless you
ask it to.

## Install

```sh
helm install chrony oci://ghcr.io/maximewewer/charts/chrony \
  --namespace time --create-namespace
helm test -n time chrony
```

Defaults: a Deployment of 2 replicas syncing over **NTS** from four public
servers (Cloudflare, Netnod, PTB x2), serving NTP on UDP/123 to private
address ranges through a ClusterIP Service, not touching any node clock.

## Choosing a shape

| Goal | Values |
|------|--------|
| In-cluster NTP service | defaults |
| Fast resync after restarts (drift file + NTS cookies kept) | `workload.kind: StatefulSet` |
| Public NTP/NTS server | `service.type: LoadBalancer`, `service.externalTrafficPolicy: Local` (required with rate limiting), `chrony.allow: [all]`, `chrony.rateLimit: "on"`, `nts.server.enabled: true` |
| Node-local time for pods | `workload.kind: DaemonSet`, `service.internalTrafficPolicy: Local` |
| Discipline the node clocks | `workload.kind: DaemonSet`, `hostNetwork: true`, `clockControl.enabled: true` |
| Internal upstreams only (no Internet) | `nts.client.enabled: false`, `chrony.servers: [ntp1.corp, ntp2.corp]` |

`ci/*-values.yaml` holds a working example of each.

## How it is wired

* **State.** chronyd keeps drift, NTS cookies and its command
  socket in `/run/chrony/state`. The volume (emptyDir, or a PVC with a
  StatefulSet) is mounted on `/run/chrony` and the entrypoint locks `state/`
  down to 0700: chronyd refuses to open its command socket in a
  world-accessible directory, which is exactly what a fresh emptyDir is - and
  without the socket, `chronyc` and the exporter go blind. `/run/chrony/**`
  rather than the image's `/var/lib/chrony`: Ubuntu's AppArmor profile for
  `/usr/sbin/chronyd` attaches by path to any unconfined process running that
  binary - containers included - and only lets it write `/var/lib/chrony/*`
  one level deep, but all of `/run/chrony/**`. The image uses the same path,
  and installs chronyd as `/usr/local/sbin/chronyd` so that profile does not
  attach at all (it would also block the runtime's SIGTERM).
* **Port 123 without root.** The pod sets the namespaced sysctl
  `net.ipv4.ip_unprivileged_port_start=123` (a *safe* sysctl since Kubernetes
  1.22), so chronyd binds 123 as uid 65532 with no capability. Keep the
  container on 123 when serving NTS: chronyd announces any other NTP port to
  its NTS-KE clients, and a Service remapping it would send them to the wrong
  port (the chart refuses to render that combination).
* **Probes.** `chrony-entrypoint health` (startup/liveness) checks the
  socket is bound and the server answers, synchronised or not - restarting
  every replica during an upstream outage would only make it worse.
  `chrony-entrypoint ready` (readiness) requires usable time: stratum, leap
  status, root distance under `probes.readyMaxRootDistance`, and the NTS-KE
  listener when serving NTS. A cold replica needs a few polls before it is
  Ready, so rollouts surge first and never drop a serving pod early.
* **Config check.** An init container runs `chrony-entrypoint config`, which
  has chronyd parse the rendered configuration: a typo fails the pod with the
  parser message instead of a crash loop, and
  `kubectl logs <pod> -c config` shows the exact chrony.conf in use.

## NTS server

```yaml
replicaCount: 3
nts:
  server:
    enabled: true
    certificate:
      certManager:
        enabled: true
        issuerRef: {name: letsencrypt, kind: ClusterIssuer}
        dnsNames: [time.example.org]
      reloaderAnnotation: true   # restart on renewal (stakater/Reloader)
service:
  type: LoadBalancer
  externalTrafficPolicy: Local
chrony:
  allow: [all]
  rateLimit: "on"
  ntsRateLimit: "on"
```

Or bring a `kubernetes.io/tls` Secret with `nts.server.certificate.existingSecret`.

**Shared cookie keys.** Behind a Service, the NTS-KE handshake and the NTP
requests of one client can land on different replicas, and a replica can only
decrypt the cookies it issued. With more than one replica, a pre-install /
pre-upgrade hook Job (`alpine/kubectl`, RBAC limited to creating Secrets and
reading this one) creates chronyd's key file in the Secret
`<fullname>-nts-keys` **only when it is missing**, and every pod loads it at
startup. The keys are never rendered by the chart, so Argo CD (which runs the
hook as PreSync) or `helm template` cannot regenerate them. The Secret is not
owned by the release: it survives an uninstall, and so do the cookies clients
hold.

chronyd does not rotate shared keys (`ntsrotate 0`). To rotate: delete the
Secret, `helm upgrade` (the Job creates new keys), then
`kubectl rollout restart` the workload - clients whose cookies stop working
redo NTS-KE on their own.

To manage the keys yourself (External Secrets, Sealed Secrets...), generate
the file and point `nts.server.sharedKeys.existingSecret` at it - no Job then:

```sh
# chronyd key dump format: header, key age, then 4 keys with consecutive ids
# (the last one is current); 15 = AES-SIV-CMAC-256, 32-byte keys.
{
  echo NKS1; echo 0.0
  base=$(( $(od -An -N4 -tu4 /dev/urandom) & 0x7ffffff0 ))
  for i in 0 1 2 3; do
    printf '%08X %s 15\n' $((base + i)) "$(openssl rand -hex 32 | tr a-f A-F)"
  done
} > ntskeys
kubectl create secret generic chrony-nts-keys --from-file=ntskeys
```

```yaml
nts:
  server:
    sharedKeys:
      existingSecret: chrony-nts-keys
```

chronyd only reads its certificate at startup: without `reloaderAnnotation`
(or an equivalent), restart the pods after a renewal and before the old
certificate expires.

## Node clock discipline

```yaml
workload:
  kind: DaemonSet
hostNetwork: true
clockControl:
  enabled: true
tolerations:
  - operator: Exists
priorityClassName: system-node-critical
```

chronyd starts as root with `SYS_TIME`, `NET_BIND_SERVICE`, `SETUID`,
`SETGID` and `DAC_OVERRIDE`, binds its sockets, then drops to uid 65532
keeping `CAP_SYS_TIME` only. The clock is not namespaced: this steers the
node, so nothing else on the node may (disable systemd-timesyncd / the node's
own chronyd), and the chart refuses more than one replica of a Deployment or
StatefulSet in this mode.

## Changing sources without a restart

`chrony.sourceFiles` lands in `/etc/chrony/sources.d`. With
`chrony.sourceFilesRolloutOnChange: false`, an upgrade only updates the
mounted files (kubelet syncs them within a minute); then:

```sh
for p in $(kubectl get pods -l app.kubernetes.io/instance=<release> -o name); do
  kubectl exec "$p" -c chrony -- chronyc -h /run/chrony/state/chronyd.sock reload sources
done
```

No measurement is lost. Everything else (environment, `confFiles`,
`config.inline`) rolls the pods, since the entrypoint renders at startup.

## Monitoring

`monitoring.enabled` adds the [ntp-exporter](https://github.com/MaximeWewer/ntp-exporter)
sidecar in agent mode, a `<fullname>-metrics` ClusterIP Service (kept off the
client Service, which may be a LoadBalancer), and optionally a ServiceMonitor
and a PrometheusRule. Per replica, labelled with its `node`:

* `ntp_chrony_*` - chronyd's tracking report, read over the Unix command
  socket: selected source, stratum, leap status, offset, dispersion, last
  update;
* `ntp_up`, `ntp_response_valid`, `ntp_root_distance_seconds`, ... for
  `server="127.0.0.1:123"` - the replica queried over NTP on localhost, i.e.
  what its clients actually receive;
* `ntp_kernel_*` - only with `clockControl`, where the node clock is chronyd's.

Alerts: chronyd unreadable, unsynchronised, stale (holdover), offset, stratum,
no valid time served, served root distance. To watch the Service from outside
the pods - and the NTS-KE certificate expiry - run a separate ntp-exporter in
probe mode against it.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| `Disabled command socket` in the chronyd log | the state directory is world-accessible or not owned by 65532 / fsGroup 65532 - keep `CHRONY_STATE_DIR` on `state/` and `podSecurityContext.fsGroup: 65532` |
| `Could not open /.../chrony.conf : Permission denied` (kernel log: `apparmor="DENIED" profile="/usr/sbin/chronyd"`) | image older than chrony-docker `2026.10.1` (rebuilt 2026-10-20): the node's AppArmor profile for `/usr/sbin/chronyd` caught an unconfined container |
| `NTP_PORT=123 is below net.ipv4.ip_unprivileged_port_start` | hostNetwork without root: set the sysctl on the nodes, or use `clockControl` |
| Pods never Ready, `root distance ... above READY_MAX_ROOT_DISTANCE` | still converging (minutes on a cold start), or upstream unreachable: check egress UDP/123 and, for NTS, TCP/4460 |
| Custom `chrony.config`: pods never Ready, `connection refused` / no reply from `127.0.0.1` | the probes query the server on localhost: add `allow 127.0.0.1` and `allow ::1` |
| `helm test` times out | `chrony.allow` does not cover the pod network, or a NetworkPolicy blocks the test pod |
| `Fatal error : Another chronyd may already be running (pid=1)` after a restart | image older than chrony-docker `2026.10.1` (rebuilt 2026-10-20), which disables the pidfile and removes a stale one |

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Full affinity; takes precedence over the presets below. |
| chrony.allow | list | `["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","fc00::/7"]` | Networks allowed to query this server (`allow`). Localhost is always allowed for the probes. Behind a `Cluster` Service the source address is often SNATed to a node IP, hence the private ranges by default; use `service.externalTrafficPolicy: Local` to see real client addresses. `all` opens the server to everyone - set `rateLimit` then. |
| chrony.authSelectMode | string | `""` | `authselectmode` (require / prefer / mix / ignore). Empty = `require` when every source is NTS, chrony's default otherwise. |
| chrony.bindAddresses | list | `[]` | `bindaddress` entries. Empty = every address of the pod. |
| chrony.clientLogLimit | string | `""` | `clientloglimit` in bytes (memory used to track clients). |
| chrony.confFiles | object | `{}` | Drop-in files (`<name>.conf`) mounted in /etc/chrony/conf.d and loaded with `confdir` after the generated directives. |
| chrony.config.existingConfigMap | string | `""` | Existing ConfigMap holding a complete chrony.conf. |
| chrony.config.inline | string | `""` | Complete chrony.conf, rendered through `tpl`. |
| chrony.config.key | string | `"chrony.conf"` | Key of the configuration in `existingConfigMap`. |
| chrony.deny | list | `[]` | Networks refused (`deny`), evaluated before `allow`. |
| chrony.extraArgs | list | `[]` | Extra chronyd command line arguments. |
| chrony.extraConf | string | `""` | Raw directives appended to the generated chrony.conf. |
| chrony.ipMode | string | `""` | Address family (`4` or `6`). Empty = both. |
| chrony.leapSecList | string | `""` | `leapseclist` path, or `off`. Empty = the list shipped in the image. |
| chrony.leapSecMode | string | `""` | `leapsecmode` (system / step / slew / ignore). |
| chrony.local | object | `{"distance":"","orphan":false,"stratum":""}` | `local` reference: keep serving time when every upstream is lost. Use `orphan` with several replicas so they agree on one orphan leader. |
| chrony.logLevel | string | `""` | chronyd log level (`-L`): 0 informational ... 3 fatal. Empty = chronyd. |
| chrony.logs | string | `""` | `log` statistics written to the state directory (e.g. `tracking measurements statistics`). They are files, not stdout. |
| chrony.maxDistance | string | `""` | `maxdistance` in seconds. |
| chrony.maxJitter | string | `""` | `maxjitter` in seconds. |
| chrony.minSources | string | `""` | `minsources`: sources that must agree before the clock is updated. |
| chrony.noClientLog | bool | `false` | `noclientlog`: do not track clients at all (disables `rateLimit`). |
| chrony.ntsRateLimit | string | `""` | `ntsratelimit` for NTS-KE, same syntax as `rateLimit`. |
| chrony.peers | list | `[]` | `peer` sources (symmetric associations). |
| chrony.pools | list | `[]` | `pool` sources (e.g. `pool.ntp.org`, which has no NTS - disable `nts.client.enabled` or give the pool entry its own options). |
| chrony.rateLimit | string | `""` | `ratelimit` for NTP: `on` = chrony's recommended `interval 3 burst 8 leak 2`, or raw arguments, or empty / `off`. |
| chrony.refclocks | list | `[]` | `refclock` lines, without the keyword (e.g. `PHC /dev/ptp0 poll 2`). The device must also be mounted through `extraVolumes`. |
| chrony.scfilterLevel | int | `1` | Seccomp filter level (`-F`). 1 = kill on a forbidden syscall, 0 = off. |
| chrony.servers | list | `["time.cloudflare.com","nts.netnod.se","ptbtime1.ptb.de","ptbtime2.ptb.de"]` | `server` sources. Defaults to four public NTS servers, authenticated with `nts.client.enabled` - needs egress on UDP/123 and TCP/4460. |
| chrony.smoothTime | string | `""` | `smoothtime` arguments, for leap smearing (e.g. `400 0.001 leaponly`). |
| chrony.sourceFiles | object | `{}` | Source files (`<name>.sources`, server/pool/peer lines) mounted in /etc/chrony/sources.d. chronyd re-reads them on `chronyc reload sources`, so they can change without losing measurements - see `sourceFilesRolloutOnChange`. |
| chrony.sourceFilesRolloutOnChange | bool | `true` | Roll the pods when `sourceFiles` change. Set to false to update the mounted files in place and run `chronyc reload sources` instead (see the chart README). |
| chrony.sourceOptions | string | `"iburst minpoll 6 maxpoll 10"` | Options appended to every bare server/pool/peer entry. |
| clockControl.enabled | bool | `false` | Let chronyd step/slew the NODE clock (the clock is not namespaced). Starts chronyd as root with CAP_SYS_TIME; it drops to uid 65532 right after binding, keeping only that capability. Use it with a DaemonSet and only where nothing else (systemd-timesyncd, the node's own chronyd) disciplines the clock. |
| commonLabels | object | `{}` | Labels added to every resource the chart renders. |
| configCheck | object | `{"enabled":true}` | Init container running `chrony-entrypoint config`: renders the configuration, has chronyd parse it (fails the pod with the parser error instead of a crash loop) and prints it to `kubectl logs -c config`. Always on with `clockControl` - it also creates the state directory as uid 65532. |
| containerPorts.ntp | int | `123` | NTP port inside the pod. Keep 123: an NTS server advertises any other port to its clients, and a Service remapping it would then break NTS. |
| containerPorts.nts | int | `4460` | NTS-KE port inside the pod. |
| dnsPolicy | string | `""` | Pod DNS policy. Empty = ClusterFirstWithHostNet with hostNetwork, ClusterFirst otherwise. |
| emptyDir | object | `{"medium":"","sizeLimit":"16Mi"}` | emptyDir state volume options (Deployment / DaemonSet, or StatefulSet without persistence). |
| exporterSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Exporter container security context. |
| extraDeploy | list | `[]` | Extra manifests rendered with the release (through `tpl`). |
| extraEnv | list | `[]` | Extra environment variables for chronyd (any chrony-entrypoint variable). |
| extraEnvFrom | list | `[]` | Extra envFrom sources for chronyd. |
| extraInitContainers | list | `[]` | Extra init containers, run before `config`. |
| extraVolumeMounts | list | `[]` | Extra chronyd volume mounts. |
| extraVolumes | list | `[]` | Extra pod volumes (e.g. `/dev/ptp0` for a PHC refclock). |
| fullnameOverride | string | `""` | Override the full resource name (`<release>-chrony` by default). |
| hostNetwork | bool | `false` | Run in the node network namespace (DaemonSet use case: serve NTP on the node IPs). The port sysctl below cannot be set in the host namespace, so a non-root chronyd then needs `net.ipv4.ip_unprivileged_port_start <= 123` on the node itself, or `clockControl.enabled` (runs chronyd as root). |
| image.digest | string | `""` | Image digest (`sha256:...`). When set it wins over the tag. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/maximewewer/chrony-docker"` | chrony image: static chronyd/chronyc on distroless, non-root (65532). |
| image.tag | string | `"2026.10.1"` | Image tag (CalVer of chrony-docker; the chart's appVersion is the chrony release it ships). |
| imagePullSecrets | list | `[]` | Pull secrets for private registries (`[{name: regcred}]`). |
| livenessProbe | object | `{"exec":{"command":["/chrony-entrypoint","health"]},"failureThreshold":3,"periodSeconds":30,"timeoutSeconds":10}` | Liveness: sockets bound and the server answers, synchronised or not - restarting every replica during an upstream outage would only make it worse. |
| minReadySeconds | int | `0` | Seconds a new pod must stay Ready before it counts as available. |
| monitoring.enabled | bool | `false` | Run the exporter sidecar and the `<fullname>-metrics` Service. |
| monitoring.exporter.collectionInterval | string | `"60s"` | Interval between two measurement cycles (5s to 1h). A burst to an unreachable server must fit in it: keep 30s or more. |
| monitoring.exporter.extraEnv | list | `[]` | Extra exporter environment variables (`NTP_EXPORTER_*`). |
| monitoring.exporter.image.digest | string | `""` | Exporter digest; wins over the tag. |
| monitoring.exporter.image.pullPolicy | string | `"IfNotPresent"` | Pull policy. |
| monitoring.exporter.image.repository | string | `"ghcr.io/maximewewer/ntp-exporter"` | Exporter image. |
| monitoring.exporter.image.tag | string | `"2026.10.1"` | Exporter tag. |
| monitoring.exporter.kernel | string | `"auto"` | Kernel option (node clock state): auto = on with `clockControl`, where it reflects what chronyd does; true / false forces. |
| monitoring.exporter.logLevel | string | `"info"` | debug / info / warn / error. |
| monitoring.exporter.measureLocalServer | bool | `true` | Measure the local chronyd over NTP on localhost. |
| monitoring.exporter.port | int | `9559` | Metrics port. |
| monitoring.exporter.referenceServers | list | `[]` | Extra reference servers measured from the pod (at most 2 in total with the local server; `nts://host` for NTS). Not pools nor public servers: every replica queries them. |
| monitoring.exporter.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"5m","memory":"24Mi"}}` | Exporter resources. |
| monitoring.prometheusRule.additionalRules | list | `[]` | Extra rules appended to the group. |
| monitoring.prometheusRule.defaultsEnabled | bool | `true` | Ship the built-in alerts (chronyd unreadable, not synchronised, stale, local server not serving usable time, offset, stratum). |
| monitoring.prometheusRule.enabled | bool | `false` | Create a PrometheusRule. |
| monitoring.prometheusRule.labels | object | `{}` | Extra labels. |
| monitoring.prometheusRule.maxOffsetSeconds | float | `0.1` | Alert when chronyd's |system time offset| stays above this (seconds). |
| monitoring.prometheusRule.maxRootDistanceSeconds | int | `1` | Alert when the local server's root distance stays above this (seconds). |
| monitoring.prometheusRule.maxStratum | int | `10` | Alert when the stratum stays above this. |
| monitoring.prometheusRule.severity | string | `"warning"` | Severity label of the built-in alerts. |
| monitoring.serviceMonitor.enabled | bool | `false` | Create a prometheus-operator ServiceMonitor. |
| monitoring.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| monitoring.serviceMonitor.labels | object | `{}` | Extra labels (e.g. the `release` your Prometheus selects). |
| monitoring.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| monitoring.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| monitoring.serviceMonitor.scrapeTimeout | string | `"10s"` | Scrape timeout. |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| networkPolicy.allowDNS | bool | `true` | Allow DNS to kube-dns (UDP/TCP 53) - sources are hostnames. |
| networkPolicy.enabled | bool | `false` | Default-deny the chrony pods, then open what they need. |
| networkPolicy.extraEgress | list | `[]` | Extra egress rules, verbatim. |
| networkPolicy.extraIngress | list | `[]` | Extra ingress rules, verbatim. |
| networkPolicy.ingressFrom | list | `[]` | Who may query NTP / NTS-KE (NetworkPolicyPeer list). Empty = any source - chrony's own `allow` still applies. |
| networkPolicy.prometheusNamespace | string | `""` | Namespace of Prometheus, allowed on the metrics port. Empty = the release namespace. |
| networkPolicy.upstreamCIDRs | list | `["0.0.0.0/0","::/0"]` | Destinations of upstream NTP (UDP/123) and NTS-KE (TCP/4460). |
| nodeAffinityPreset | object | `{"key":"","type":"","values":[]}` | Pin pods to nodes with a label. |
| nodeAffinityPreset.key | string | `""` | Node label key. |
| nodeAffinityPreset.type | string | `""` | "" / soft / hard. |
| nodeAffinityPreset.values | list | `[]` | Accepted values. |
| nodeSelector | object | `{}` | Node selector. |
| nts.client.enabled | bool | `true` | Authenticate every bare server/pool/peer entry with NTS (`nts` option). With all sources on NTS, `authselectmode require` is implied. |
| nts.client.trustedCertsSecret | string | `""` | Secret with extra CA certificates (PEM) trusted for NTS-KE, for an internal NTS server. Mounted in /etc/chrony/nts-trust and passed to `ntstrustedcerts`. The system bundle stays trusted. |
| nts.server.certificate.certManager.dnsNames | list | `[]` | DNS names the clients use to reach the NTS-KE endpoint. The first is the common name. |
| nts.server.certificate.certManager.duration | string | `"2160h"` | Certificate lifetime. |
| nts.server.certificate.certManager.enabled | bool | `false` | Request the certificate from cert-manager. |
| nts.server.certificate.certManager.issuerRef.group | string | `"cert-manager.io"` | Issuer API group. |
| nts.server.certificate.certManager.issuerRef.kind | string | `"ClusterIssuer"` | Issuer / ClusterIssuer. |
| nts.server.certificate.certManager.issuerRef.name | string | `""` | Issuer name. |
| nts.server.certificate.certManager.privateKey.algorithm | string | `"ECDSA"` | ECDSA / RSA / Ed25519. |
| nts.server.certificate.certManager.privateKey.rotationPolicy | string | `"Always"` | Generate a new key on every renewal. |
| nts.server.certificate.certManager.privateKey.size | int | `256` | Key size (256/384 for ECDSA, 2048+ for RSA). |
| nts.server.certificate.certManager.renewBefore | string | `"720h"` | Renew this long before expiry. |
| nts.server.certificate.existingSecret | string | `""` | Existing `kubernetes.io/tls` Secret (tls.crt / tls.key). Wins over cert-manager. |
| nts.server.certificate.reloaderAnnotation | bool | `false` | Add the stakater/Reloader annotation so the pods restart when the certificate Secret is renewed. chronyd only reads the certificate at startup; without a reloader, restart the pods before the old one expires. |
| nts.server.enabled | bool | `false` | Serve NTS-KE on `containerPorts.nts` (TCP). Needs a certificate. |
| nts.server.ntpServer | list | `[]` | `ntsntpserver`: the NTP endpoint announced to NTS-KE clients, when it differs from the address they used for NTS-KE. |
| nts.server.rotate | string | `""` | `ntsrotate` interval in seconds. Ignored with shared keys, which never rotate in chronyd (rotate them by replacing the Secret). |
| nts.server.sharedKeys.enabled | string | `"auto"` | auto = on whenever more than one pod can serve the same Service (Deployment / StatefulSet with replicaCount > 1). true / false forces. |
| nts.server.sharedKeys.existingSecret | string | `""` | Existing Secret with a chronyd `ntskeys` file (key `ntskeys`). No hook Job then. |
| nts.server.sharedKeys.job.image.digest | string | `""` | Digest; wins over the tag. |
| nts.server.sharedKeys.job.image.pullPolicy | string | `"IfNotPresent"` | Pull policy. |
| nts.server.sharedKeys.job.image.repository | string | `"alpine/kubectl"` | Image of the key creation Job: needs sh, od, tr, printf and kubectl. |
| nts.server.sharedKeys.job.image.tag | string | `"1.37.0"` | Tag. |
| nts.server.sharedKeys.job.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Job resources. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | PVC access modes. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | StatefulSet only: one PVC per replica instead of an emptyDir. |
| persistence.retentionPolicy | object | `{"whenDeleted":"Retain","whenScaled":"Retain"}` | StatefulSet PVC retention (Retain / Delete). |
| persistence.size | string | `"64Mi"` | PVC size. chronyd writes a few kilobytes. |
| persistence.storageClass | string | `""` | Storage class. Empty = the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podAntiAffinityPreset | string | `"soft"` | Spread replicas across nodes: "" / soft / hard. Ignored by DaemonSets. |
| podDisruptionBudget | object | `{"enabled":"auto","maxUnavailable":"","minAvailable":"","unhealthyPodEvictionPolicy":""}` | PodDisruptionBudget. auto = on for Deployment / StatefulSet with more than one replica. |
| podDisruptionBudget.minAvailable | string | `""` | If both are empty, `maxUnavailable: 1`. Set only one. |
| podDisruptionBudget.unhealthyPodEvictionPolicy | string | `""` | "" / AlwaysAllow / IfHealthyBudget. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. fsGroup 65532 makes the state volume writable by the image user and gives `state/` the group chronyd checks. |
| priorityClassName | string | `""` | Priority class. A node-clock DaemonSet usually wants `system-node-critical`. |
| probes.maxStratum | int | `15` | Both probes fail above this stratum. |
| probes.readyMaxRootDistance | int | `1` | `ready` fails while the root distance is above this (seconds). |
| probes.timeout | int | `3` | Timeout of one probe query (seconds). |
| progressDeadlineSeconds | int | `900` | Deployment progress deadline. A cold chronyd needs a few polls before its root distance drops under `probes.readyMaxRootDistance`, so leave headroom. |
| readinessProbe | object | `{"exec":{"command":["/chrony-entrypoint","ready"]},"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":10}` | Readiness: the server serves usable time (stratum, leap, root distance and the NTS-KE listener). |
| replicaCount | int | `2` | Replicas (Deployment / StatefulSet only). Two or more keeps time served while a node drains; NTS servers then need shared cookie keys, see `nts.server.sharedKeys`. |
| resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | chronyd resources. chronyd is tiny; the limit only guards a leak. |
| revisionHistoryLimit | int | `5` | Old ReplicaSets / ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true}` | chronyd container security context. With `clockControl.enabled` the chart overrides the user (root) and the capabilities, see above. |
| service.annotations | object | `{}` | Service annotations (e.g. MetalLB / cloud LB settings). |
| service.clusterIP | string | `""` | Fixed cluster IP. |
| service.enabled | bool | `true` | Create the Service. |
| service.externalTrafficPolicy | string | `""` | Cluster / Local, for NodePort / LoadBalancer. `Cluster` SNATs external clients to a node address: `allow` / `deny` then judge the node, not the client, and `rateLimit` / `ntsRateLimit` throttle every client behind a node as one - the chart refuses that combination. Use `Local`. |
| service.internalTrafficPolicy | string | `""` | Cluster / Local. Local with a DaemonSet = every pod asks the chronyd of its own node. |
| service.ipFamilies | list | `[]` | IPv4 / IPv6 order. |
| service.ipFamilyPolicy | string | `""` | SingleStack / PreferDualStack / RequireDualStack. |
| service.labels | object | `{}` | Extra Service labels. |
| service.loadBalancerClass | string | `""` | LoadBalancer implementation class. |
| service.loadBalancerIP | string | `""` | LoadBalancer IP (when the provider honours it). |
| service.loadBalancerSourceRanges | list | `[]` | Source ranges allowed through the LoadBalancer. |
| service.nodePorts | object | `{"ntp":"","nts":""}` | Fixed node ports (NodePort / LoadBalancer). |
| service.ntpPort | int | `123` | Service port for NTP (UDP). |
| service.ntsPort | int | `4460` | Service port for NTS-KE (TCP), only when `nts.server.enabled`. |
| service.preservesClientIP | bool | `false` | Set to true when the data path keeps client addresses even with `externalTrafficPolicy: Cluster` (e.g. Cilium in DSR mode), to lift the check above. |
| service.sessionAffinity | string | `""` | None / ClientIP. |
| service.type | string | `"ClusterIP"` | ClusterIP / NodePort / LoadBalancer. A LoadBalancer carrying both UDP (NTP) and TCP (NTS-KE) needs mixed-protocol support (GA in 1.26). |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automountServiceAccountToken | bool | `false` | Mount the API token. chrony never talks to the API server. |
| serviceAccount.create | bool | `true` | Create a dedicated ServiceAccount. |
| serviceAccount.name | string | `""` | Name. Empty = the full name. |
| sidecars | list | `[]` | Extra sidecar containers. |
| startupProbe | object | `{"exec":{"command":["/chrony-entrypoint","health"]},"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":10}` | Startup: same check as liveness, while chronyd binds its sockets. |
| terminationGracePeriodSeconds | int | `30` | Pod termination grace period. |
| tests.enabled | bool | `true` | Render the `helm test` pod: a one-shot `chronyd -Q` that must get a usable answer from the Service. |
| tests.timeout | int | `30` | Seconds the test client waits for a usable sample. |
| tolerations | list | `[]` | Tolerations. A node-clock DaemonSet usually wants `- operator: Exists`. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. The release selector labels are filled in when `labelSelector` is omitted. |
| unprivilegedPortSysctl | bool | `true` | Set the namespaced sysctl `net.ipv4.ip_unprivileged_port_start` to the lowest chrony port, so the non-root chronyd can bind 123. Safe sysctl since Kubernetes 1.22; skipped with hostNetwork and when chronyd runs as root. |
| updateStrategy | object | `{}` | Controller update strategy, verbatim. Empty = a per-kind default that never drops below the current serving capacity (Deployment: maxSurge 1 / maxUnavailable 0; StatefulSet / DaemonSet: RollingUpdate). |
| workload.kind | string | `"Deployment"` | Controller kind.   Deployment  - N interchangeable time servers behind a Service (default).   StatefulSet - same, but each replica keeps its drift file and NTS cookies                 on a PVC, so a restart is back in sync in seconds instead of                 minutes.   DaemonSet   - one chronyd per node. Pair it with `hostNetwork` to serve                 the node IPs, with `service.internalTrafficPolicy: Local` to                 give every pod a node-local time source, or with                 `clockControl.enabled` to discipline the node clocks. |
