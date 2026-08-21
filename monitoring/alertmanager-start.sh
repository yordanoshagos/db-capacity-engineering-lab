#!/bin/sh
# Substitute Slack webhook at start. Empty webhook → dummy URL so AM still boots.
set -eu
URL="${SLACK_WEBHOOK_URL:-https://example.invalid/slack-webhook-not-set}"
sed "s|PLACEHOLDER_SLACK_WEBHOOK|${URL}|g" /etc/alertmanager/alertmanager.yml > /tmp/alertmanager.yml
exec /bin/alertmanager --config.file=/tmp/alertmanager.yml --storage.path=/alertmanager
