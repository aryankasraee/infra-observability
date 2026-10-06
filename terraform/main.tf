# Terraform talks to the Docker daemon on the server over SSH and creates
# every container, volume and network of the monitoring stack.
#
# Config files are not copied to the host. Each container gets its files
# "uploaded" at creation time (the `upload` blocks). When a file changes,
# `terraform apply` recreates only that container; data volumes stay.

provider "docker" {
  host     = "ssh://${var.ssh_user}@${var.ssh_host}:${var.ssh_port}"
  ssh_opts = ["-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=20"]
}

locals {
  cfg = "${path.module}/../config"

  # Small, rotated json-file logs for every container we own.
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  dashboards = fileset("${local.cfg}/grafana/dashboards", "*.json")
  rules      = fileset("${local.cfg}/prometheus/rules", "*.yml.tftpl")

  # Values the *.tftpl config templates are rendered with.
  tpl = {
    server_name    = var.server_name
    sites          = var.sites
    api_probe      = var.api_probe
    app_containers = var.app_containers
  }
}

# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------

resource "docker_network" "monitoring" {
  name   = "monitoring"
  driver = "bridge"
}

data "docker_network" "app" {
  name = var.app_network
}

resource "docker_volume" "prometheus" { name = "monitoring_prometheus" }
resource "docker_volume" "alertmanager" { name = "monitoring_alertmanager" }
resource "docker_volume" "grafana" { name = "monitoring_grafana" }
resource "docker_volume" "loki" { name = "monitoring_loki" }
resource "docker_volume" "alloy" { name = "monitoring_alloy" }

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# Pull each image once; containers reference the image id so a version bump
# in var.images replaces the right container.
resource "docker_image" "this" {
  for_each     = var.images
  name         = each.value
  keep_locally = true
}

# ---------------------------------------------------------------------------
# Prometheus: metrics database + alert rule evaluation
# ---------------------------------------------------------------------------

resource "docker_container" "prometheus" {
  name        = "prometheus"
  image       = docker_image.this["prometheus"].image_id
  restart     = "unless-stopped"
  memory      = 1024
  memory_swap = 1024 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=${var.prometheus_retention_time}",
    "--storage.tsdb.retention.size=${var.prometheus_retention_size}",
    "--web.enable-lifecycle",
    "--web.enable-remote-write-receiver", # k6 pushes its results here
  ]

  networks_advanced { name = docker_network.monitoring.name }

  ports {
    internal = 9090
    external = 9090
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.prometheus.name
    container_path = "/prometheus"
  }

  upload {
    file    = "/etc/prometheus/prometheus.yml"
    content = templatefile("${local.cfg}/prometheus/prometheus.yml.tftpl", local.tpl)
  }

  dynamic "upload" {
    for_each = local.rules
    content {
      file    = "/etc/prometheus/rules/${trimsuffix(upload.value, ".tftpl")}"
      content = templatefile("${local.cfg}/prometheus/rules/${upload.value}", local.tpl)
    }
  }
}

# ---------------------------------------------------------------------------
# Alertmanager + the webhook receiver that logs every notification
# ---------------------------------------------------------------------------

resource "docker_container" "alertmanager" {
  name        = "alertmanager"
  image       = docker_image.this["alertmanager"].image_id
  restart     = "unless-stopped"
  memory      = 128
  memory_swap = 128 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  command = [
    "--config.file=/etc/alertmanager/alertmanager.yml",
    "--storage.path=/alertmanager",
  ]

  networks_advanced { name = docker_network.monitoring.name }

  ports {
    internal = 9093
    external = 9093
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.alertmanager.name
    container_path = "/alertmanager"
  }

  upload {
    file    = "/etc/alertmanager/alertmanager.yml"
    content = file("${local.cfg}/alertmanager/alertmanager.yml")
  }
}

resource "docker_container" "alert_logger" {
  name        = "alert-logger"
  image       = docker_image.this["alert_logger"].image_id
  restart     = "unless-stopped"
  memory      = 64
  memory_swap = 64 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts
  command     = ["python", "-u", "/app/server.py"]

  networks_advanced { name = docker_network.monitoring.name }

  upload {
    file    = "/app/server.py"
    content = file("${local.cfg}/alert-logger/server.py")
  }
}

# ---------------------------------------------------------------------------
# Grafana: dashboards
# ---------------------------------------------------------------------------

resource "docker_container" "grafana" {
  name        = "grafana"
  image       = docker_image.this["grafana"].image_id
  restart     = "unless-stopped"
  memory      = 768
  memory_swap = 768 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  env = [
    "GF_SECURITY_ADMIN_USER=admin",
    "GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}",
    "GF_USERS_ALLOW_SIGN_UP=false",
    "GF_ANALYTICS_REPORTING_ENABLED=false",
    "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
    "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false",
    "GF_NEWS_NEWS_FEED_ENABLED=false",
    "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/dashboards/overview.json",
    # Grafana 13 tries to download/update core plugins (prometheus, loki...) at
    # start-up. The plugin CDN answers 403 to Iranian IPs, and a failed update
    # leaves the bundled plugin unregistered: every panel says "Plugin not
    # registered". Use only the plugins shipped in the image.
    "GF_PLUGINS_PREINSTALL_DISABLED=true",
    "GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false",
  ]

  networks_advanced { name = docker_network.monitoring.name }

  ports {
    internal = 3000
    external = 3005
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.grafana.name
    container_path = "/var/lib/grafana"
  }

  upload {
    file    = "/etc/grafana/provisioning/datasources/datasources.yml"
    content = file("${local.cfg}/grafana/provisioning/datasources/datasources.yml")
  }

  upload {
    file    = "/etc/grafana/provisioning/dashboards/dashboards.yml"
    content = file("${local.cfg}/grafana/provisioning/dashboards/dashboards.yml")
  }

  dynamic "upload" {
    for_each = local.dashboards
    content {
      file    = "/etc/grafana/dashboards/${upload.value}"
      content = file("${local.cfg}/grafana/dashboards/${upload.value}")
    }
  }
}

# ---------------------------------------------------------------------------
# Loki (log database) + Alloy (log shipper)
# ---------------------------------------------------------------------------

resource "docker_container" "loki" {
  name        = "loki"
  image       = docker_image.this["loki"].image_id
  restart     = "unless-stopped"
  memory      = 768
  memory_swap = 768 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts
  command     = ["-config.file=/etc/loki/loki.yml"]

  networks_advanced { name = docker_network.monitoring.name }

  ports {
    internal = 3100
    external = 3100
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.loki.name
    container_path = "/loki"
  }

  upload {
    file    = "/etc/loki/loki.yml"
    content = file("${local.cfg}/loki/loki.yml")
  }
}

resource "docker_container" "alloy" {
  name        = "alloy"
  image       = docker_image.this["alloy"].image_id
  restart     = "unless-stopped"
  memory      = 512
  memory_swap = 512 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  command = [
    "run",
    "--server.http.listen-addr=0.0.0.0:12345",
    "--storage.path=/var/lib/alloy/data",
    "--disable-reporting",
    "/etc/alloy/config.alloy",
  ]

  networks_advanced { name = docker_network.monitoring.name }

  volumes {
    volume_name    = docker_volume.alloy.name
    container_path = "/var/lib/alloy/data"
  }
  volumes {
    host_path      = var.nginx_log_dir
    container_path = "/var/log/nginx"
    read_only      = true
  }
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
    read_only      = true
  }

  upload {
    file    = "/etc/alloy/config.alloy"
    content = templatefile("${local.cfg}/alloy/config.alloy.tftpl", local.tpl)
  }

  depends_on = [docker_container.loki]
}

# ---------------------------------------------------------------------------
# Exporters: turn "things" into Prometheus metrics
# ---------------------------------------------------------------------------

# Host CPU, memory, disk, network. Needs the host's network and process view.
resource "docker_container" "node_exporter" {
  name         = "node-exporter"
  image        = docker_image.this["node_exporter"].image_id
  restart      = "unless-stopped"
  memory       = 128
  memory_swap  = 128 # no swap: hit the limit -> restart, not thrash
  log_opts     = local.log_opts
  network_mode = "host"
  pid_mode     = "host"

  command = [
    "--path.rootfs=/host",
    "--web.listen-address=${var.docker_bridge_ip}:9100",
    "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containerd/.+)($|/)",
  ]

  volumes {
    host_path      = "/"
    container_path = "/host"
    read_only      = true
  }
}

# Per-container CPU / memory / network.
resource "docker_container" "cadvisor" {
  name        = "cadvisor"
  image       = docker_image.this["cadvisor"].image_id
  restart     = "unless-stopped"
  memory      = 512
  memory_swap = 512 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts
  privileged  = true

  command = [
    "--docker_only=true",
    "--housekeeping_interval=30s",
    "--store_container_labels=false",
    "--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service",
    # "disk" runs du over every container layer, which is slow on this host.
    "--disable_metrics=disk,percpu,sched,tcp,udp,advtcp,referenced_memory,cpu_topology,resctrl,hugetlb,process",
  ]

  networks_advanced { name = docker_network.monitoring.name }

  devices {
    host_path      = "/dev/kmsg"
    container_path = "/dev/kmsg"
  }

  volumes {
    host_path      = "/"
    container_path = "/rootfs"
    read_only      = true
  }
  volumes {
    host_path      = "/var/run"
    container_path = "/var/run"
    read_only      = true
  }
  volumes {
    host_path      = "/sys"
    container_path = "/sys"
    read_only      = true
  }
  volumes {
    host_path      = "/var/lib/docker"
    container_path = "/var/lib/docker"
    read_only      = true
  }
  volumes {
    host_path      = "/dev/disk"
    container_path = "/dev/disk"
    read_only      = true
  }
}

resource "docker_container" "blackbox" {
  name        = "blackbox"
  image       = docker_image.this["blackbox"].image_id
  restart     = "unless-stopped"
  memory      = 64
  memory_swap = 64 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts
  command     = ["--config.file=/etc/blackbox/blackbox.yml"]

  networks_advanced { name = docker_network.monitoring.name }

  upload {
    file    = "/etc/blackbox/blackbox.yml"
    content = templatefile("${local.cfg}/blackbox/blackbox.yml.tftpl", local.tpl)
  }
}

resource "docker_container" "nginx_exporter" {
  name        = "nginx-exporter"
  image       = docker_image.this["nginx_exporter"].image_id
  restart     = "unless-stopped"
  memory      = 32
  memory_swap = 32 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts
  command     = ["--nginx.scrape-uri=http://${var.docker_bridge_ip}:8089/stub_status"]

  networks_advanced { name = docker_network.monitoring.name }
}

# Joins the application network so it can reach `mongo:27017`; the database
# itself stays unpublished.
resource "docker_container" "mongodb_exporter" {
  name        = "mongodb-exporter"
  image       = docker_image.this["mongo_exporter"].image_id
  restart     = "unless-stopped"
  memory      = 128
  memory_swap = 128 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  env = ["MONGODB_URI=${var.mongo_uri}"]
  command = [
    "--collect-all",
    "--compatible-mode",
    "--discovering-mode",
  ]

  networks_advanced { name = docker_network.monitoring.name }
  networks_advanced { name = data.docker_network.app.name }
}

# ---------------------------------------------------------------------------
# Synthetic traffic (k6). Runs for var.loadgen_hours, then exits.
# ---------------------------------------------------------------------------

resource "docker_container" "loadgen" {
  count = var.loadgen_enabled ? 1 : 0

  name        = "loadgen-k6"
  image       = docker_image.this["k6"].image_id
  restart     = "no"
  must_run    = false
  memory      = 512
  memory_swap = 512 # no swap: hit the limit -> restart, not thrash
  log_opts    = local.log_opts

  command = ["run", "--quiet", "-o", "experimental-prometheus-rw", "/scripts/scenarios.js"]

  env = [
    "BASE_URL=http://${var.docker_bridge_ip}",
    "HOURS=${var.loadgen_hours}",
    "K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write",
    "K6_PROMETHEUS_RW_TREND_STATS=p(95),p(99),avg,max",
    "K6_PROMETHEUS_RW_PUSH_INTERVAL=15s",
    "K6_NO_USAGE_REPORT=true",
    "SITE_HOST=${var.loadgen.site_host}",
    "ADMIN_HOST=${var.loadgen.admin_host}",
    "GIT_HOST=${var.loadgen.git_host}",
    "TENANT=${var.loadgen.tenant}",
  ]

  networks_advanced { name = docker_network.monitoring.name }

  upload {
    file    = "/scripts/scenarios.js"
    content = file("${path.module}/../loadgen/scenarios.js")
  }

  depends_on = [docker_container.prometheus]
}
