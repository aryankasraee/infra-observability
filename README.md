# infra-observability

Metrics, logs, dashboards and alerts for a production Docker host (a
multi-tenant school SaaS: public sites, admin console, APIs, MongoDB, plus
Git, project tracker and status page), deployed with Terraform. One `terraform apply` from a laptop builds the whole stack on a
remote Docker host over SSH.

```
             ┌──────────────── app host (Docker) ───────────────────────┐
 visitors ─▶ │ nginx ─▶ shell / website / console ─▶ backend-core/lms ─▶ mongo
             │   │ JSON access log            container stdout/stderr    │
             │   ▼                                   ▼                   │
             │ Alloy ── request metrics ──┐   Alloy ── log lines ──▶ Loki│
             │                            ▼                              │
             │ node-exporter, cAdvisor ─▶ Prometheus ◀─ blackbox (CDN)   │
             │ nginx-exporter, mongodb-exporter ─┘ │  ◀─ k6 (synthetic)  │
             │                                     ▼                     │
             │                    Alertmanager ─▶ alert-logger ─▶ Loki   │
             │                                     Grafana (dashboards)  │
             └───────────────────────────────────────────────────────────┘
```

| Piece | What it does |
|---|---|
| **Prometheus** | Stores numbers over time (CPU, requests/s, latency...) and checks 22 alert rules every 15 s |
| **Alertmanager** | Groups and de-duplicates alerts, sends notifications |
| **Grafana** | Dashboards. 6 provisioned: Platform Overview (home), Node Exporter Full, cAdvisor, Blackbox, NGINX, MongoDB |
| **Loki** | Stores log lines, 7 days |
| **Alloy** | Reads nginx's JSON log and every container's output, ships them to Loki, and turns nginx log lines into request/latency metrics |
| **node-exporter** | Host CPU, memory, disk, network |
| **cAdvisor** | CPU and memory per container |
| **blackbox-exporter** | Opens the public URLs through the CDN like a user would: up/down, response time, TLS expiry |
| **nginx-exporter / mongodb-exporter** | nginx connections, MongoDB operations and connections |
| **k6** | Synthetic users (website visitors, failed logins, bots, git readers) so dashboards have traffic |
| **alert-logger** | 40-line Python webhook: prints each notification as JSON so it lands in Loki |

## What you need

- A Linux server with Docker, reachable over SSH with a key (no password prompt).
- On your laptop: [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6 and `make`.
- The nginx changes in [`nginx/`](nginx/) installed on the server (see step 2).

## Step by step

### 1. Describe your server and sites

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`. Everything specific to one installation
lives there (the file is git-ignored); the repo only holds templates.

| Variable | What it is |
|---|---|
| `ssh_host`, `ssh_user`, `ssh_port` | How Terraform reaches Docker on the server |
| `server_name` | Short label for the host on dashboards |
| `sites` | Public sites: Host header, probe URL, and a short `name` shown on dashboards instead of the real hostname |
| `api_probe` | Optional deep check: one API call through proxy → app → database |
| `app_containers` | Containers that must always run (alert if one disappears) |
| `app_network` | Docker network of the app, so the MongoDB exporter can reach the database |
| `loadgen` | Hostnames and tenant for the synthetic traffic |

Config files with `.tftpl` are rendered from these values with Terraform's
`templatefile()`. To see the rendered result: `make render` (writes `build/`).

Check that SSH works without a password: `ssh -p 22 root@YOUR_SERVER docker ps`.

### 2. Give nginx a JSON log and a status page

Copy [`nginx/observability.conf`](nginx/observability.conf) to the server's nginx
`conf.d/` and reload nginx. It adds:

- `access_json.log`: one JSON object per request (vhost, status, latency, upstream).
  The old `access.log` is untouched.
- `stub_status` on `172.17.0.1:8089`: reachable from containers only.

```bash
scp -P 2222 nginx/observability.conf root@SERVER:/root/nginx/conf/conf.d/
ssh -p 2222 root@SERVER 'docker exec nginx nginx -t && docker exec nginx nginx -s reload'
```

Also install [`nginx/logrotate-nginx-docker`](nginx/logrotate-nginx-docker) as
`/etc/logrotate.d/nginx-docker` so the logs don't fill the disk.

### 3. Create the stack

```bash
make init     # downloads the Docker provider
make plan     # shows what will be created; nothing changes yet
make apply    # type "yes"
```

Terraform creates 1 network, 5 volumes, 12 images and 12 containers. Running
`make plan` again must say **No changes**: that proves the code and the server match.

### 4. Open Grafana

Nothing is exposed to the internet. Open an SSH tunnel:

```bash
make tunnel      # leave it running
make password    # Grafana admin password
```

Then browse to <http://localhost:3005> (user `admin`). Prometheus is on
<http://localhost:9090>, Alertmanager on <http://localhost:9093>.

### 5. Change something

Edit a file under `config/`, run `make apply`. Only the container that uses the
file is recreated; its data volume stays.

## Alerts

All rules are in [`config/prometheus/rules/alerts.yml`](config/prometheus/rules/alerts.yml):
host down, CPU/memory/swap/disk, OOM kills, an app container missing or
restarting, site or API down through the CDN, slow responses, TLS expiry,
5xx ratio, p95 latency, MongoDB down, error-log bursts, scrape targets down.

Notifications currently go to `alert-logger`, which writes them to Loki. In
Grafana: Explore → Loki → `{container="alert-logger"}`. To get them on a phone
or by email, see [docs/ALERTS.md](docs/ALERTS.md).

Test the whole path by hand:

```bash
curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"PipelineTest","severity":"info"}}]'
```

## Synthetic traffic

[`loadgen/scenarios.js`](loadgen/scenarios.js) is a k6 script. It sends about
1 to 12 requests per second for `loadgen_hours` (default 9), following a
day-like curve with one 10-minute spike, then exits. Results go to Prometheus
(`k6_*` metrics) and show in the "Synthetic traffic" row of the overview dashboard.

Start another run: `make loadgen-restart`. Turn it off: `loadgen_enabled = false`
in `terraform.tfvars`, then `make apply`.

## Sizing

On a 4-core / 8 GB host the stack uses about 1 GB RAM. Every container has a
memory limit with swap disabled, so a runaway exporter restarts instead of
pushing the host into swap. Prometheus keeps 15 days or 3 GB, whichever comes first;
Loki keeps 7 days.

## Layout

```
terraform/   providers, variables, every container (main.tf), outputs
config/      prometheus, alertmanager, loki, alloy, blackbox, grafana, alert-logger
             (*.tftpl = templates filled from terraform.tfvars)
loadgen/     k6 script
nginx/       nginx snippets + logrotate installed on the host
scripts/     dashboard generator (dashboards as code), template renderer
docs/        alerts how-to, troubleshooting
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
