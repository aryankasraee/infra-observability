variable "server_name" {
  description = "Short name for the monitored host. Used as the `server` / `instance` label."
  type        = string
  default     = "app-server"
}

variable "sites" {
  description = <<-EOT
    Public sites to watch. `host` is the Host header nginx sees, `url` is what
    the black-box probe opens (through the CDN), `name` is the short alias shown
    on dashboards instead of the real hostname.
  EOT
  type = list(object({
    name   = string
    host   = string
    url    = string
    module = optional(string, "http_2xx") # or "http_any_answer" for 404-on-/ services
  }))
  default = [
    { name = "website", host = "www.example.com", url = "https://www.example.com/" },
  ]
}

variable "api_probe" {
  description = "Optional deep health check: an API URL, headers to send, and a regex the body must match."
  type = object({
    name    = string
    url     = string
    headers = optional(map(string), {})
    expect  = optional(string, "")
  })
  default = null
}

variable "app_containers" {
  description = "Container names that must always be running (AppContainerMissing alert)."
  type        = list(string)
  default     = ["nginx"]
}

variable "loadgen" {
  description = "Hosts and tenant for the k6 scenarios (see loadgen/scenarios.js)."
  type = object({
    site_host  = string
    admin_host = string
    git_host   = string
    tenant     = string
  })
  default = {
    site_host  = "school.example.com"
    admin_host = "console.example.com"
    git_host   = "git.example.com"
    tenant     = "demo-tenant"
  }
}

variable "ssh_host" {
  description = "Public IP or hostname of the server that runs Docker."
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the server. Needs permission to use Docker."
  type        = string
  default     = "root"
}

variable "ssh_port" {
  description = "SSH port on the server."
  type        = number
  default     = 22
}

variable "docker_bridge_ip" {
  description = "Address of the docker0 bridge on the host. node-exporter and nginx stub_status listen here so only containers can reach them."
  type        = string
  default     = "172.17.0.1"
}

variable "nginx_log_dir" {
  description = "Host directory that holds nginx's access_json.log."
  type        = string
  default     = "/root/nginx/logs"
}

variable "app_network" {
  description = "Existing Docker network of the application stack (mongo lives there)."
  type        = string
  default     = "app_default"
}

variable "mongo_uri" {
  description = "MongoDB connection string as seen from inside app_network."
  type        = string
  default     = "mongodb://mongo:27017"
  sensitive   = true
}

variable "prometheus_retention_time" {
  description = "How long Prometheus keeps metrics."
  type        = string
  default     = "15d"
}

variable "prometheus_retention_size" {
  description = "Upper bound for Prometheus disk usage; oldest data is dropped first."
  type        = string
  default     = "3GB"
}

variable "loadgen_enabled" {
  description = "Run the k6 synthetic-traffic container."
  type        = bool
  default     = true
}

variable "loadgen_hours" {
  description = "How many hours the k6 run lasts. The container then exits."
  type        = number
  default     = 9
}

variable "images" {
  description = "Container image per component. Pin exact versions; bump on purpose."
  type        = map(string)
  default = {
    prometheus     = "prom/prometheus:v3.15.0"
    alertmanager   = "prom/alertmanager:v0.34.1"
    grafana        = "grafana/grafana:13.2.3"
    loki           = "grafana/loki:3.7.8"
    alloy          = "grafana/alloy:v1.20.1"
    node_exporter  = "prom/node-exporter:v1.12.1"
    cadvisor       = "ghcr.io/google/cadvisor:v0.60.6"
    blackbox       = "prom/blackbox-exporter:v0.28.0"
    nginx_exporter = "nginx/nginx-prometheus-exporter:1.5.3"
    mongo_exporter = "percona/mongodb_exporter:0.53.0"
    alert_logger   = "python:3.13-alpine"
    k6             = "grafana/k6:2.3.0"
  }
}
