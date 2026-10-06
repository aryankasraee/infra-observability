#!/usr/bin/env python3
"""Generate config/grafana/dashboards/overview.json.

Writing dashboards as code keeps them reviewable in git. Run:
    python3 scripts/gen_overview_dashboard.py
"""
import json
from pathlib import Path

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

panels = []
_next_id = 1
_y = 0


def _id():
    global _next_id
    _next_id += 1
    return _next_id


def row(title):
    global _y
    panels.append({"type": "row", "title": title, "id": _id(), "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y}, "panels": []})
    _y += 1


def stat(title, expr, x, w=3, unit="none", thresholds=None, decimals=None, desc=""):
    steps = thresholds or [{"color": "green", "value": None}]
    p = {
        "type": "stat", "title": title, "id": _id(), "datasource": PROM, "description": desc,
        "gridPos": {"h": 4, "w": w, "x": x, "y": _y},
        "targets": [{"refId": "A", "expr": expr, "datasource": PROM, "instant": True}],
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps},
                                     "color": {"mode": "thresholds"}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background",
                    "graphMode": "area", "textMode": "value"},
    }
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    panels.append(p)


def ts(title, targets, x, w=12, h=8, unit="none", stack=False, desc=""):
    p = {
        "type": "timeseries", "title": title, "id": _id(), "datasource": PROM, "description": desc,
        "gridPos": {"h": h, "w": w, "x": x, "y": _y},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": PROM}
                    for i, (e, l) in enumerate(targets)],
        "fieldConfig": {"defaults": {"unit": unit, "custom": {
            "drawStyle": "line", "lineWidth": 1, "fillOpacity": 15 if stack else 5,
            "showPoints": "never",
            "stacking": {"mode": "normal" if stack else "none", "group": "A"}}}, "overrides": []},
        "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["mean", "max"]},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }
    panels.append(p)


def logs(title, expr, x, w=24, h=10, desc=""):
    panels.append({
        "type": "logs", "title": title, "id": _id(), "datasource": LOKI, "description": desc,
        "gridPos": {"h": h, "w": w, "x": x, "y": _y},
        "targets": [{"refId": "A", "expr": expr, "datasource": LOKI}],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                    "enableLogDetails": True, "dedupStrategy": "none"},
    })


def advance(h):
    global _y
    _y += h


RED = [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]

row("Health at a glance")
stat("Public probes up", 'sum(probe_success{probe=~"public|api"}) / count(probe_success{probe=~"public|api"})',
     0, unit="percentunit", decimals=0,
     thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 0.8}, {"color": "green", "value": 1}],
     desc="Share of black-box checks (through the CDN) that succeed right now.")
stat("Requests / s", 'sum(rate(nginx_log_http_requests_total[5m]))', 3, unit="reqps", decimals=1,
     desc="All requests nginx served, every vhost.")
stat("5xx ratio", '(sum(rate(nginx_log_http_requests_total{status_class="5"}[5m])) or vector(0)) / sum(rate(nginx_log_http_requests_total[5m]))',
     6, unit="percentunit", decimals=2,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}])
stat("p95 latency", 'histogram_quantile(0.95, sum by (le) (rate(nginx_log_http_request_duration_seconds_bucket[5m])))',
     9, unit="s", decimals=2,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.5}, {"color": "red", "value": 1.5}])
stat("Alerts firing", 'count(ALERTS{alertstate="firing",severity!="info"}) or vector(0)', 12,
     thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 3}])
stat("CPU", '100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))', 15, unit="percent", decimals=0, thresholds=RED)
stat("Memory", '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', 18, unit="percent", decimals=0, thresholds=RED)
stat("Disk /", '100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})',
     21, unit="percent", decimals=0, thresholds=RED)
advance(4)

row("Traffic (from the nginx access log)")
ts("Requests per second by site", [('sum by (vhost) (rate(nginx_log_http_requests_total[2m]))', "{{vhost}}")],
   0, unit="reqps", stack=True)
ts("Responses by status class", [('sum by (status_class) (rate(nginx_log_http_requests_total[2m]))', "{{status_class}}xx")],
   12, unit="reqps", stack=True, desc="2xx ok, 3xx redirect, 4xx client mistake, 5xx server failure.")
advance(8)
ts("Latency percentiles (all sites)", [
    ('histogram_quantile(0.50, sum by (le) (rate(nginx_log_http_request_duration_seconds_bucket[5m])))', "p50"),
    ('histogram_quantile(0.95, sum by (le) (rate(nginx_log_http_request_duration_seconds_bucket[5m])))', "p95"),
    ('histogram_quantile(0.99, sum by (le) (rate(nginx_log_http_request_duration_seconds_bucket[5m])))', "p99"),
], 0, unit="s")
ts("p95 latency by site", [
    ('histogram_quantile(0.95, sum by (vhost, le) (rate(nginx_log_http_request_duration_seconds_bucket[5m])))', "{{vhost}}")],
   12, unit="s")
advance(8)
ts("5xx per second by site", [('sum by (vhost) (rate(nginx_log_http_requests_total{status_class="5"}[5m]))', "{{vhost}}")],
   0, unit="reqps")
ts("nginx connections", [('nginx_connections_active', "active"), ('nginx_connections_waiting', "waiting"),
                         ('rate(nginx_http_requests_total{job="nginx"}[2m])', "req/s (stub_status)")], 12)
advance(8)

row("Black-box probes (through the CDN)")
ts("Probe duration", [('probe_duration_seconds{site!=""}', "{{site}}")], 0, unit="s")
ts("Probe success (1 = up)", [('probe_success{site!=""}', "{{site}}")], 12)
advance(8)

row("Containers")
ts("CPU by container (cores)", [('topk(10, sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])))', "{{name}}")],
   0)
ts("Memory by container", [('topk(10, sum by (name) (container_memory_working_set_bytes{name!=""}))', "{{name}}")],
   12, unit="bytes")
advance(8)
ts("Error log lines per minute", [('sum by (container) (rate(container_log_lines_total{level="error"}[5m])) * 60', "{{container}}")],
   0, desc="Lines containing error/fatal/panic, per container. Counted by Alloy.")
ts("Container restarts (last 1h)", [('sum by (name) (changes(container_start_time_seconds{name!=""}[1h]))', "{{name}}")], 12)
advance(8)

row("Synthetic traffic (k6)")
ts("k6 requests per second by scenario", [('sum by (scenario) (rate(k6_http_reqs_total[2m]))', "{{scenario}}")], 0, unit="reqps")
ts("k6 p95 response time by scenario", [('max by (scenario) (k6_http_req_duration_p95)', "{{scenario}}")], 12, unit="ms")
advance(8)
ts("k6 failed request rate", [('avg by (scenario) (k6_http_req_failed_rate)', "{{scenario}}")], 0, unit="percentunit")
ts("k6 checks passing", [('avg by (check) (k6_checks_rate)', "{{check}}")], 12, unit="percentunit")
advance(8)

row("MongoDB")
ts("Operations per second", [('sum by (legacy_op_type) (rate(mongodb_ss_opcounters[2m]))', "{{legacy_op_type}}")], 0, unit="ops")
ts("Connections", [('mongodb_ss_connections{conn_type=~"current|available"}', "{{conn_type}}")], 12)
advance(8)

row("Logs")
logs("Errors from all containers", '{level="error"}', 0, h=10)
advance(10)
logs("Alert notifications (Alertmanager -> alert-logger)", '{container="alert-logger"}', 0, h=8)
advance(8)

dashboard = {
    "uid": "obs-overview",
    "title": "Platform Overview",
    "tags": ["overview"],
    "timezone": "browser",
    "schemaVersion": 39,
    "editable": True,
    "refresh": "30s",
    "time": {"from": "now-6h", "to": "now"},
    "panels": panels,
    "templating": {"list": []},
    "annotations": {"list": [{
        "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
        "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
}

out = Path(__file__).resolve().parent.parent / "config/grafana/dashboards/overview.json"
out.write_text(json.dumps(dashboard, indent=1, ensure_ascii=False))
print("wrote", out, len(panels), "panels")
