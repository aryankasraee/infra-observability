output "grafana_admin_password" {
  description = "Run `terraform output -raw grafana_admin_password` to see it."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "ssh_tunnel_command" {
  description = "Open Grafana, Prometheus and Alertmanager on your laptop through SSH."
  value       = "ssh -N -p ${var.ssh_port} -L 3005:127.0.0.1:3005 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 ${var.ssh_user}@${var.ssh_host}"
}

output "urls_after_tunnel" {
  value = {
    grafana      = "http://localhost:3005  (user: admin)"
    prometheus   = "http://localhost:9090"
    alertmanager = "http://localhost:9093"
  }
}
