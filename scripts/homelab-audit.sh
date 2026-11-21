#!/bin/bash
# homelab-audit.sh - READ-ONLY health + tidiness check for a Proxmox node.
# Run as root on EACH node (pve1, pve2). Changes nothing; only reports.
# A copy of the report is saved to /root/homelab-audit-<node>-<date>.txt
set -u
export LC_ALL=C
N=$(hostname); NOW=$(date +%s)
LOG="/root/homelab-audit-$N-$(date +%F-%H%M).txt"
if [ -t 1 ]; then R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; B=$'\e[36m'; Z=$'\e[0m'; else R=; Y=; G=; B=; Z=; fi
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$LOG")) 2>&1

SUM=(); INFO=0
ok()   { echo "  ${G}[ OK ]${Z} $*"; }
warn() { echo "  ${Y}[WARN]${Z} $*"; SUM+=("$*"); }
bad()  { echo "  ${R}[FAIL]${Z} $*"; SUM+=("FAIL: $*"); }
info() { echo "  ${B}[INFO]${Z} $*"; INFO=$((INFO+1)); }
hint() { echo "           -> $*"; }
sec()  { echo; echo "${B}== $* ==${Z}"; }
T()    { timeout -k 3 "$@"; }                       # T <secs> cmd ...  (never hang)
gt()   { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }
days() { echo $(( (NOW - $1) / 86400 )); }
hsize(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
main_cfg() { awk '/^\[/{exit} {print}' "$1"; }      # guest config without snapshot sections
CONFS=$(ls /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf 2>/dev/null)
used_in_configs() { [ -n "$CONFS" ] && grep -qF -- "$1" $CONFS; }
HAVE_JQ=1; command -v jq >/dev/null || HAVE_JQ=0

echo "Homelab audit - node $N - $(date '+%Y-%m-%d %H:%M')   (read-only, nothing is changed)"

# ------------------------------------------------------------------ 1. system
sec "1. System"
CPUS=$(nproc); read -r L1 L5 L15 _ < /proc/loadavg
PCPU=$(awk -F'avg60=' '/^some/{split($2,a," ");print a[1]}' /proc/pressure/cpu 2>/dev/null)
PIO=$(awk -F'avg60=' '/^some/{split($2,a," ");print a[1]}' /proc/pressure/io 2>/dev/null)
if gt "$L15" "$CPUS"; then warn "Load $L15 (15 min) is above CPU count $CPUS"
elif gt "$L15" 2 && ! gt "${PCPU:-0}" 5 && ! gt "${PIO:-0}" 5; then
  warn "Load $L15 but CPU/disk pressure is ~0 - processes are stuck, not busy"; hint "see 'stuck processes' below"
else ok "Load $L1 / $L5 / $L15 on $CPUS CPUs (pressure: cpu ${PCPU:-?}%, io ${PIO:-?}%)"; fi

DS=$(ps -eo state,pid,etime,comm | awk '$1=="D"{print $2" ("$4", stuck "$3")"}')
if [ -n "$DS" ]; then warn "Stuck processes (state D):"; echo "$DS" | sed 's/^/             /'
  hint "usually a dead network mount - check section 3"; else ok "No stuck processes"; fi

MT=$(awk '/^MemTotal/{print $2}' /proc/meminfo); MA=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
ST=$(awk '/^SwapTotal/{print $2}' /proc/meminfo); SF=$(awk '/^SwapFree/{print $2}' /proc/meminfo)
AP=$(( MA * 100 / MT ))
if [ "$AP" -lt 10 ]; then warn "Only ${AP}% RAM available ($(hsize $((MA*1024))) of $(hsize $((MT*1024))))"
else ok "RAM available: $(hsize $((MA*1024))) of $(hsize $((MT*1024))) (${AP}%)"; fi
[ "${ST:-0}" -gt 0 ] && [ $(( (ST-SF) * 100 / ST )) -gt 50 ] && warn "Swap more than half used ($(hsize $(((ST-SF)*1024))))"
if [ -r /proc/spl/kstat/zfs/arcstats ]; then
  ARC=$(awk '/^size/{print $3}' /proc/spl/kstat/zfs/arcstats); CMAX=$(awk '/^c_max/{print $3}' /proc/spl/kstat/zfs/arcstats)
  info "ZFS cache (ARC): using $(hsize "$ARC"), max $(hsize "$CMAX")"
  [ "$CMAX" -gt $(( MT * 1024 / 2 )) ] && hint "max is over half of RAM - capping it (e.g. 4-6 GB) leaves more for guests"
fi

RUNK=$(uname -r); NEWK=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -1)
if [ -n "$NEWK" ] && [ "$RUNK" != "$NEWK" ]; then warn "Running kernel $RUNK, newer $NEWK installed"; hint "reboot this node when convenient"
else ok "Kernel $RUNK (newest installed)"; fi
info "Uptime: $(uptime -p)"

FU=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -n "$FU" ]; then for u in $FU; do warn "Failed service: $u"; done; hint "systemctl status <name>  /  systemctl reset-failed if it no longer matters"
else ok "No failed services"; fi

[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && ok "Clock synchronised (NTP)" || warn "Clock NOT synchronised (NTP)"

UPD=$(T 60 apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst')
[ "${UPD:-0}" -gt 0 ] && info "$UPD package updates pending (Updates tab / apt dist-upgrade)" || ok "No pending updates (as of last apt refresh)"

SUB=$(pvesubscription get 2>/dev/null | awk -F': ' '/^status/{print $2}'); ENT=""
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
  [ -f "$f" ] && grep -q 'enterprise.proxmox.com' "$f" || continue
  case "$f" in *.sources) grep -qi '^Enabled: *no' "$f" || ENT="$ENT $(basename "$f")";;
               *) grep -q '^[^#]*enterprise.proxmox.com' "$f" && ENT="$ENT $(basename "$f")";; esac
done
if [ -n "$ENT" ] && [ "${SUB,,}" != active ]; then warn "Enterprise repo enabled without subscription:$ENT"; hint "disable it in node > Updates > Repositories (updates fail otherwise)"
else ok "APT repositories OK"; fi

for c in /etc/pve/local/pveproxy-ssl.pem /etc/pve/local/pve-ssl.pem; do
  [ -f "$c" ] || continue
  END=$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2); LEFT=$(( ($(date -d "$END" +%s) - NOW) / 86400 ))
  [ "$LEFT" -lt 30 ] && warn "Web certificate expires in $LEFT days" || ok "Web certificate valid for $LEFT more days"; break
done

# ------------------------------------------------------------------ 2. cluster + network
sec "2. Cluster & network"
PS=$(T 10 pvecm status 2>/dev/null)
if [ -z "$PS" ]; then info "Not in a cluster (or pvecm not answering)"
else
  TV=$(awk '/Total votes/{print $3}' <<< "$PS"); EV=$(awk '/Expected votes/{print $3}' <<< "$PS")
  grep -q 'Quorate: *Yes' <<< "$PS" && ok "Cluster quorate ($TV of $EV votes)" || bad "Cluster NOT quorate ($TV of $EV votes)"
  if grep -q 'Qdevice' <<< "$PS"; then ok "QDevice (tie-breaker) present"; else warn "No QDevice vote - cluster can't survive losing a node"; fi
fi
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  case $ns in 8.8.8.8|8.8.4.4|1.1.1.1|1.0.0.1|9.9.9.9|149.112.112.112)
    warn "DNS $ns in /etc/resolv.conf bypasses Pi-hole (Chrome switches to encrypted DNS with it)"
    hint "node > System > DNS: keep only 10.0.0.2 and 10.0.0.20"; continue;; esac
  if command -v dig >/dev/null; then
    A=$(T 6 dig +short +time=2 +tries=1 @"$ns" proxmox.com A 2>/dev/null | head -1)
    [ -n "$A" ] && ok "DNS server $ns answers" || bad "DNS server $ns does not answer"
  fi
done
for h in "10.0.0.2|Pi-hole 1" "10.0.0.20|PBS + Pi-hole 2" "10.0.0.30|Zabbix" \
         "10.0.0.11|pve1" "10.0.0.12|pve2" "10.0.0.50|NAS" "10.0.0.21|PDM"; do
  ip=${h%%|*}; nm=${h#*|}
  ping -c1 -W1 "$ip" >/dev/null 2>&1 && ok "Reachable: $nm ($ip)" || warn "Not reachable: $nm ($ip)"
done

# ------------------------------------------------------------------ 3. storage + mounts
sec "3. Storage & mounts"
while read -r src mp; do
  [ -n "$mp" ] || continue
  if T 4 stat -t "$mp" >/dev/null 2>&1; then info "Network mount $mp <- $src (responding) - still needed?"
  else bad "Network mount $mp <- $src is NOT responding (causes stuck processes / high load)"
       hint "umount -l -c $mp   and remove it from Datacenter > Storage and /etc/fstab"; fi
done < <(awk '$3 ~ /^(nfs|nfs4|cifs|smb3|fuse\.sshfs)$/ {print $1" "$2}' /proc/mounts)

while read -r dev mp fs opts _; do
  case "$dev" in ''|\#*) continue;; esac
  [ "$fs" = swap ] || [ "$mp" = none ] || [[ "$opts" == *noauto* ]] && continue
  awk -v m="$mp" '$2==m{f=1} END{exit !f}' /proc/mounts || { warn "fstab entry not mounted: $dev -> $mp ($fs)"; hint "if it's no longer used, comment the line out in /etc/fstab"; }
done < /etc/fstab

STOK=1
while read -r name type st _ _ _ pct; do
  [ -n "$name" ] && [ "$name" != Name ] || continue
  case $st in
    active) p=${pct%\%}; if gt "$p" 85; then warn "Storage $name is $pct full"; STOK=0; fi;;
    disabled) ;;   # storage that belongs to the other node - normal
    *) warn "Storage $name ($type) is $st"; STOK=0;;
  esac
done < <(T 30 pvesm status 2>/dev/null)
[ "$STOK" = 1 ] && ok "All storages active and below 85%"
for s in $(awk '/^(nfs|cifs): /{print $2}' /etc/pve/storage.cfg 2>/dev/null); do info "Storage '$s' is a network share - still needed?"; done

if command -v zpool >/dev/null; then
  while read -r pn ph pc; do
    [ "$ph" = ONLINE ] && ok "ZFS pool $pn ONLINE, ${pc} used" || bad "ZFS pool $pn is $ph"
    gt "${pc%\%}" 80 && warn "ZFS pool $pn is ${pc} full (keep under 80%)"
    SL=$(zpool status "$pn" | grep 'scan:')
    if [[ "$SL" == *"in progress"* ]]; then info "ZFS scrub running on $pn"
    elif [[ "$SL" == *" on "* ]]; then SD=$(date -d "$(sed 's/.* on //' <<< "$SL")" +%s 2>/dev/null || echo 0)
      [ "$(days "$SD")" -gt 35 ] && warn "ZFS pool $pn last scrubbed $(days "$SD") days ago" || ok "ZFS pool $pn scrubbed $(days "$SD") days ago, $(grep -o '[0-9]* errors\|with [0-9]* errors' <<< "$SL" | head -1)"
    else warn "ZFS pool $pn has never been scrubbed"; fi
  done < <(zpool list -H -o name,health,capacity 2>/dev/null)
fi
RP=$(df -P / | awk 'NR==2{print $5}'); gt "${RP%\%}" 80 && warn "Root disk is $RP full" || ok "Root disk $RP used"
info "System logs (journal): $(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]*[KMGT]B*' | head -1)"

# ------------------------------------------------------------------ 4. leftovers worth reviewing
sec "4. Leftovers (candidates for clean-up)"
LO=0
DUMPS=$(find /var/lib/vz/dump -maxdepth 1 -type f -name 'vzdump-*' 2>/dev/null)
if [ -n "$DUMPS" ]; then LO=1; SZ=$(du -cb $DUMPS | tail -1 | cut -f1)
  info "$(wc -l <<< "$DUMPS") old local backup file(s) in /var/lib/vz/dump ($(hsize "$SZ")) - backups now go to PBS"; hint "delete via node > local > Backups if not needed"; fi
for f in /var/lib/vz/template/iso/*; do
  [ -f "$f" ] || continue; b=$(basename "$f")
  used_in_configs "iso/$b" || { LO=1; info "ISO not attached to any guest: $b ($(hsize "$(stat -c%s "$f")"))"; }
done
for f in /var/lib/vz/template/cache/*; do [ -f "$f" ] && { LO=1; info "Container template: $(basename "$f") ($(hsize "$(stat -c%s "$f")"))"; }; done
while read -r f; do [ -n "$f" ] && { LO=1; info "Old file in /root: $(basename "$f") ($(date -r "$f" +%F))"; }; done < <(
  find /root -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.deb' -o -name '*.tgz' -o -name '*.tar*' -o -name '*.json' -o -name '*.iso' \) -mtime +2 2>/dev/null)
while read -r f; do [ -n "$f" ] && { LO=1; info "Backup copy older than 7 days: $f"; }; done < <(
  find /etc /usr/local/bin /root -maxdepth 3 -path /etc/pve -prune -o -type f \( -name '*.bak' -o -name '*.bak[-.]*' -o -name '*.orig' \) -mtime +7 -print 2>/dev/null)
for d in /mnt/* /mnt/pve/*; do
  [ -d "$d" ] && [ "$d" != /mnt/pve ] || continue
  awk -v m="$d" '$2==m{f=1} END{exit !f}' /proc/mounts && continue
  if [[ "$d" == /mnt/pve/* ]] && ! grep -q "^[a-z]*: $(basename "$d")$" /etc/pve/storage.cfg; then LO=1; info "Folder for a storage that no longer exists: $d"
  elif [ -z "$(T 3 ls -A "$d" 2>/dev/null)" ]; then LO=1; info "Empty folder: $d"; fi
done
[ "$LO" = 0 ] && ok "Nothing obvious left over"

# ------------------------------------------------------------------ 5. services + scheduled jobs
sec "5. Services & scheduled jobs"
for s in pve-cluster pvedaemon pveproxy pvestatd corosync corosync-qdevice zabbix-agent2 prometheus-node-exporter; do
  systemctl list-unit-files "$s.service" --no-legend 2>/dev/null | grep -q . || continue
  systemctl is-active --quiet "$s" && ok "$s running" || bad "$s NOT running"
done
if systemctl is-active --quiet nfs-server 2>/dev/null; then
  grep -qv '^\s*\(#\|$\)' /etc/exports 2>/dev/null && info "NFS server running and sharing: $(grep -v '^\s*#' /etc/exports | awk 'NF{print $1}' | tr '\n' ' ')" \
    || warn "NFS server running but shares nothing"; fi
for u in /etc/systemd/system/*.service; do
  [ -f "$u" ] && [ ! -L "$u" ] || continue; n=$(basename "$u")
  info "Custom service $n: $(systemctl is-enabled "$n" 2>/dev/null), $(systemctl is-active "$n" 2>/dev/null) - $(grep -m1 '^Description=' "$u" | cut -d= -f2)"
done
for f in /etc/cron.d/*; do
  [ -f "$f" ] || continue
  case $(basename "$f") in e2scrub_all|zfsutils-linux|mdadm|sysstat|.placeholder|php|pve-*|prometheus*) continue;; esac
  info "Scheduled job $(basename "$f"): $(grep -v '^\s*#' "$f" | grep -v '=' | awk 'NF' | head -1 | cut -c1-80)"
  for p in $(grep -v '^\s*#' "$f" | grep -oE '/[A-Za-z0-9_./-]+\.(sh|py)|/usr/local/bin/[A-Za-z0-9_.-]+' | sort -u); do
    [ -e "$p" ] || warn "Scheduled job $(basename "$f") runs $p which does not exist"; done
done
CR=$(crontab -l 2>/dev/null | grep -v '^\s*#' | awk 'NF')
[ -n "$CR" ] && while read -r l; do info "root crontab: ${l:0:90}"; done <<< "$CR"

# ------------------------------------------------------------------ 6. guests on this node
sec "6. VMs & containers on $N"
declare -A LASTBK
if [ "$HAVE_JQ" = 1 ]; then
  for s in $(awk '/^pbs: /{print $2}' /etc/pve/storage.cfg 2>/dev/null); do
    while read -r id ct; do [ -n "$id" ] || continue; [ "${LASTBK[$id]:-0}" -lt "$ct" ] && LASTBK[$id]=$ct
    done < <(T 90 pvesh get "/nodes/$N/storage/$s/content" --content backup --output-format json 2>/dev/null | jq -r '.[] | "\(.vmid) \(.ctime)"')
  done
  NOTBK=$(T 30 pvesh get /cluster/backup-info/not-backed-up --output-format json 2>/dev/null | jq -r '.[].vmid' | tr '\n' ' ')
else info "jq not installed - skipping backup checks (apt install jq)"; NOTBK=""; fi

check_guest() {   # $1 kind(vm|ct) $2 id $3 conf
  local k=$1 id=$2 f=$3 c name st tag
  c=$(main_cfg "$f")
  name=$(awk -F': ' '/^(name|hostname):/{print $2; exit}' <<< "$c")
  tag="$([ "$k" = vm ] && echo VM || echo CT) $id ($name)"
  grep -q '^template: 1' <<< "$c" && { info "$tag is a template"; return; }
  if [ "$k" = vm ]; then st=$(T 10 qm status "$id" 2>/dev/null | awk '{print $2}'); else st=$(T 10 pct status "$id" 2>/dev/null | awk '{print $2}'); fi
  echo "  --- $tag: ${st:-unknown}"
  if [ "$st" = running ]; then grep -q '^onboot: 1' <<< "$c" || info "$tag runs but won't start by itself after a node reboot (Options > Start at boot)"
  else info "$tag is stopped - still needed?"; fi
  grep -q '^lock:' <<< "$c" && warn "$tag is locked ($(awk '/^lock:/{print $2}' <<< "$c"))" && hint "qm unlock $id / pct unlock $id if no task is running"
  grep -q '^\[PENDING\]' "$f" && warn "$tag has pending changes - they apply after a full stop/start"
  while read -r l; do [ -n "$l" ] && warn "$tag has an unused disk: ${l#*: }" && hint "Hardware > Unused Disk > Remove (deletes it) if not needed"; done < <(grep -E '^unused[0-9]+:' <<< "$c")
  if [ "$k" = vm ]; then
    while read -r l; do [ -n "$l" ] && warn "$tag still has an ISO in its CD drive: ${l%%,*}" && hint "qm set $id --${l%%:*} none,media=cdrom"
    done < <(grep -E '^(ide|sata|scsi)[0-9]+: [^,]*iso/.*media=cdrom' <<< "$c")
    if grep -qE '^agent: *(1|enabled=1)' <<< "$c"; then
      [ "$st" = running ] && { T 6 qm agent "$id" ping >/dev/null 2>&1 && ok "$tag guest agent answering" || warn "$tag guest agent enabled but not answering"; }
    else info "$tag has no guest agent enabled"; fi
  fi
  while read -r sn stime; do [ -n "$sn" ] || continue
    [ "$(days "$stime")" -gt 14 ] && warn "$tag snapshot '$sn' is $(days "$stime") days old (slows the disk, uses space)" || info "$tag snapshot '$sn' ($(days "$stime") days old)"
  done < <(awk '/^\[/{s=$0; gsub(/[\[\]]/,"",s)} /^snaptime:/{print s, $2}' "$f" | grep -v '^PENDING')
  if [ "$HAVE_JQ" = 1 ]; then
    if [[ " $NOTBK " == *" $id "* ]]; then warn "$tag is NOT in any backup job"
    elif [ -n "${LASTBK[$id]:-}" ]; then
      d=$(days "${LASTBK[$id]}"); lim=$([ "$st" = running ] && echo 2 || echo 8)
      [ "$d" -gt "$lim" ] && warn "$tag last backup $d days ago" || ok "$tag backed up $([ "$d" = 0 ] && echo today || echo "$d day(s) ago")"
    else warn "$tag has no backup on PBS yet"; fi
  fi
}
for f in /etc/pve/qemu-server/*.conf; do [ -f "$f" ] && check_guest vm "$(basename "$f" .conf)" "$f"; done
for f in /etc/pve/lxc/*.conf; do [ -f "$f" ] && check_guest ct "$(basename "$f" .conf)" "$f"; done

# ------------------------------------------------------------------ 7. orphan disks
sec "7. Disks not used by any VM/CT"
ORPH=0
for s in $( { T 30 pvesm status --content images 2>/dev/null; T 30 pvesm status --content rootdir 2>/dev/null; } | awk '$3=="active"{print $1}' | sort -u); do
  while read -r vol _ type size vmid; do
    [ "$vol" != Volid ] && [ -n "$vol" ] || continue
    case $type in images|rootdir) ;; *) continue;; esac
    used_in_configs "$vol" && continue
    ORPH=1; owner=$(ls /etc/pve/nodes/*/{qemu-server,lxc}/"$vmid".conf 2>/dev/null | head -1)
    warn "Orphan disk $vol ($(hsize "$size")) - $([ -n "$owner" ] && echo "guest $vmid exists but doesn't use it" || echo "guest $vmid no longer exists")"
    hint "pvesm free $vol   (permanently deletes it - only if you're sure)"
  done < <(T 60 pvesm list "$s" 2>/dev/null)
done
[ "$ORPH" = 0 ] && ok "Every disk on this node belongs to a VM/CT"

# ------------------------------------------------------------------ summary
sec "Summary for $N"
if [ ${#SUM[@]} -eq 0 ]; then echo "  ${G}Nothing needs attention.${Z} ($INFO info items above to glance at)"
else echo "  ${Y}${#SUM[@]} item(s) to look at${Z} (plus $INFO info items above):"; for s in "${SUM[@]}"; do echo "   - $s"; done; fi
echo; echo "  Report saved: $LOG"
sleep 0.5
