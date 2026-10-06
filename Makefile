# Shortcuts. Run `make help` to list them.
#
# -parallelism=3: the server's sshd drops connections when Terraform opens
# ten SSH sessions at once (MaxStartups). Three at a time is reliable.

TF = terraform -chdir=terraform
TF_FLAGS = -parallelism=3

.PHONY: help init plan apply destroy tunnel password dashboard render check loadgen-restart

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-16s %s\n", $$1, $$2}'

init: ## Download the Terraform providers
	$(TF) init

plan: dashboard ## Show what would change on the server
	$(TF) plan $(TF_FLAGS)

apply: dashboard ## Create or update the monitoring stack
	$(TF) apply $(TF_FLAGS)

destroy: ## Remove every container, volume and network this project created
	$(TF) destroy $(TF_FLAGS)

dashboard: ## Regenerate the overview dashboard JSON
	python3 scripts/gen_overview_dashboard.py

tunnel: ## Forward Grafana/Prometheus/Alertmanager to localhost (Ctrl+C to stop)
	$$($(TF) output -raw ssh_tunnel_command)

password: ## Print the Grafana admin password
	@$(TF) output -raw grafana_admin_password; echo

render: ## Render config templates to build/ with the example variables
	scripts/render-configs.sh

check: render ## Validate everything offline (needs Docker)
	$(TF) fmt -check
	$(TF) validate
	docker run --rm -v $(PWD)/build/prometheus/rules:/r --entrypoint promtool prom/prometheus:v3.15.0 check rules /r/alerts.yml
	docker run --rm -v $(PWD)/build/blackbox:/b prom/blackbox-exporter:v0.28.0 --config.file=/b/blackbox.yml --config.check
	docker run --rm -v $(PWD)/config/alertmanager:/a --entrypoint amtool prom/alertmanager:v0.34.1 check-config /a/alertmanager.yml

loadgen-restart: ## Start another k6 run (after the previous one finished)
	$(TF) apply $(TF_FLAGS) -replace='docker_container.loadgen[0]'
