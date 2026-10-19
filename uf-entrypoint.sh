#!/bin/sh
set -eu

: "${LAB_NODE:?}"
: "${PEER_SUBNET:?}"
: "${PEER_GATEWAY:?}"
: "${SPLUNK_RECEIVER:?}"
: "${UF_ADMIN_PASSWORD:?}"

# Keep the original endpoint-to-endpoint path through gw.
ip route replace "$PEER_SUBNET" via "$PEER_GATEWAY"

mkdir -p /opt/splunkforwarder/etc/system/local /var/log/lab
cat > /opt/splunkforwarder/etc/system/local/outputs.conf <<CONF
[tcpout]
defaultGroup = lab
[tcpout:lab]
server = $SPLUNK_RECEIVER
CONF

cat > /opt/splunkforwarder/etc/system/local/inputs.conf <<CONF
[monitor:///var/log/lab]
disabled = 0
index = main
sourcetype = lab:endpoint
host = $LAB_NODE
CONF

touch /var/log/lab/activity.log
/opt/splunkforwarder/bin/splunk start \
  --accept-license --answer-yes --no-prompt \
  --seed-passwd "$UF_ADMIN_PASSWORD"
printf '%s host=%s event=endpoint_started\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LAB_NODE" >> /var/log/lab/activity.log

# Exit on splunkd failure so Compose restarts the endpoint.
while /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q 'splunkd is running'; do
  sleep 15
done
echo 'splunkd stopped unexpectedly' >&2
exit 1
