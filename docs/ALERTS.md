# Getting alerts somewhere you will see them

Alertmanager sends every notification to `alert-logger` today. Add a real
receiver and route to it. Edit `config/alertmanager/alertmanager.yml`, then
`make apply` (only the alertmanager container is recreated).

## Telegram

1. In Telegram talk to `@BotFather`, send `/newbot`, keep the token.
2. Send any message to your new bot, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `chat.id`.
3. Add a receiver:

```yaml
receivers:
  - name: logger
    webhook_configs:
      - url: http://alert-logger:8080/alert
        send_resolved: true
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager/telegram_token
        chat_id: 123456789
        send_resolved: true
```

4. Route critical alerts to both:

```yaml
route:
  receiver: logger
  routes:
    - matchers: [severity="critical"]
      receiver: telegram
      continue: true
    - matchers: [severity="critical"]
      receiver: logger
```

Keep the token out of git: add an `upload` block for
`/etc/alertmanager/telegram_token` in `terraform/main.tf` whose content comes from
a `sensitive` variable set in `terraform.tfvars`.

Note: from servers in Iran `api.telegram.org` is usually blocked. Send through
a relay host or use email instead.

## Email (SMTP)

```yaml
global:
  smtp_smarthost: smtp.gmail.com:587
  smtp_from: you@gmail.com
  smtp_auth_username: you@gmail.com
  smtp_auth_password_file: /etc/alertmanager/smtp_password   # a Gmail app password
receivers:
  - name: email
    email_configs:
      - to: you@gmail.com
        send_resolved: true
```

## Silencing an alert during maintenance

Open <http://localhost:9093> (through `make tunnel`) → **New Silence** →
matcher `alertname="HostHighCpu"` → duration. Or from the CLI:

```bash
docker exec alertmanager amtool silence add alertname=HostHighCpu \
  --duration=2h --comment="planned load test" --alertmanager.url=http://localhost:9093
```
