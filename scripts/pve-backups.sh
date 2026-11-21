#!/bin/bash
# Installs a small exporter that writes the newest backup time of every VM/CT as a Prometheus metric
# (node-exporter textfile collector), so Grafana can show "backup age" and alert on stale backups.
# Run as root on ONE Proxmox node. Reads backups from the PBS storage named below.
#
#   pve_backup_last_timestamp_seconds{vmid="102",guest="zabbix",type="lxc"} 1795000000   (0 = never)
set -euo pipefail
STORAGE=${STORAGE:-pbs}            # Proxmox storage ID of your Proxmox Backup Server
SKIP_IDS=${SKIP_IDS:-}             # e.g. "100,101" - lab guests you don't want to alert on
command -v jq >/dev/null || apt-get install -y -qq jq

cat > /usr/local/bin/pve-backups.sh <<SH
#!/bin/bash
OUT=/var/lib/prometheus/node-exporter/pve_backups.prom
NODE=\$(hostname)
G=\$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo '[]')
B=\$(pvesh get /nodes/\$NODE/storage/$STORAGE/content --content backup --output-format json 2>/dev/null || echo '[]')
jq -rn --argjson g "\$G" --argjson b "\$B" --arg skip "$SKIP_IDS" '
  (\$skip | split(",") | map(select(length>0) | tonumber)) as \$skipids |
  "# TYPE pve_backup_last_timestamp_seconds gauge",
  (\$g[] | select(.template != 1) | select((.vmid as \$id | \$skipids | index(\$id)) == null) | . as \$vm
    | ([\$b[] | select(.vmid == \$vm.vmid) | .ctime] | max // 0) as \$t
    | "pve_backup_last_timestamp_seconds{vmid=\"\(\$vm.vmid)\",guest=\"\(\$vm.name // ("ID " + (\$vm.vmid|tostring)))\",type=\"\(\$vm.type)\"} \(\$t)")
' > \$OUT.tmp && mv \$OUT.tmp \$OUT
SH
chmod +x /usr/local/bin/pve-backups.sh
mkdir -p /var/lib/prometheus/node-exporter
echo '*/15 * * * * root /usr/local/bin/pve-backups.sh' > /etc/cron.d/pve-backups
/usr/local/bin/pve-backups.sh && cat /var/lib/prometheus/node-exporter/pve_backups.prom
