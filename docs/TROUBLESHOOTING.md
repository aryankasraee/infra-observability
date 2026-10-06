# Troubleshooting

Problems hit while building this, and how they were fixed.

### `Error pinging Docker server ... ssh://...` during apply
The server's sshd limits concurrent unauthenticated connections
(`MaxStartups 10:30:100`). Terraform opens one SSH session per resource, up to
10 at a time, and some get dropped. Use `-parallelism=3` (the Makefile does).

### Host load jumped to 12 right after the first apply
Two causes at once:
- cAdvisor hit its 256 MB limit. With swap allowed, the kernel swapped it
  instead of killing it and disk I/O went to 100 %. Fixed by raising the limit
  and setting `memory_swap = memory` on every container (no swap: a container
  over its limit restarts, the host stays healthy).
- cAdvisor's `disk` metric runs `du` over every container layer. Disabled
  (`--disable_metrics=disk,...`); disk I/O metrics are still collected.

### Loki: `timestamp too old` errors on the first start
Alloy reads each container's log from the beginning the first time it sees it.
Loki refuses lines older than 7 days. Harmless and one-off: Alloy stores its
read positions in the `monitoring_alloy` volume and continues from there.

### Two different metrics named `nginx_http_requests_total`
nginx-prometheus-exporter already exports that name. The metrics Alloy builds
from the access log are prefixed `nginx_log_` to keep them apart.

### Grafana: `Cannot read directory /var/lib/grafana/dashboards`
`/var/lib/grafana` is a volume; files uploaded there at container creation are
not reliable. Dashboards are uploaded to `/etc/grafana/dashboards` instead.

### `terraform plan` always shows `memory_swap = 128 -> null`
Docker fills `memory_swap` with 2× `memory` when you don't set it. Setting it
explicitly removes the permanent diff.

### Useful commands on the server

```bash
docker ps --filter network=monitoring          # the stack
docker logs --tail 50 alloy                    # log shipper problems
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | {state, name: .labels.alertname}'
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

### Every Grafana panel: "Plugin not registered" / "No data"
Grafana 13 runs a background installer at start-up that updates core plugins
(prometheus, loki...) from the plugin CDN. From an Iranian IP the download
returns `403 AccessDenied`, and the failed update leaves the bundled plugin
unregistered. Prometheus itself is fine (query it on :9090), only Grafana is
blind. Fixed with `GF_PLUGINS_PREINSTALL_DISABLED=true` and
`GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`. Lesson: verify dashboards through
Grafana's own query API (`/api/ds/query`), not only against Prometheus.
