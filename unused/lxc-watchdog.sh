#!/bin/bash
#
# WatchDog script for Proxmox LXC Containers
# v2.0
#
# Install using `crontab -e` like this: * * * * * /root/lxc_watchdog.sh
#

# Configurable Settings
declare -A Containers=(
    ["AdGuardLXC"]="100 192.168.31.10"
    ["MainLXC"]="101 192.168.31.100"
)

logFile="/var/log/proxmox_lxc_watchdog.log"

# Alert address comes from conf/watchdog.conf (see conf/watchdog.conf.example),
# resolved relative to this script so it works from a checkout or /opt/ergosteur.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${WATCHDOG_CONFIG:-$SCRIPT_DIR/conf/watchdog.conf}
email=""
if [[ -r "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    . "$CONFIG"
    email="${WATCHDOG_EMAIL:-}"
fi

# Log function
log () {
    output="[LXC WatchDog] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$output" >> "$logFile"
    logger "$output"
}

# Send email alert
sendAlert () {
    subject="[Proxmox LXC WatchDog] $1"
    body="$2"
    if [[ -z "$email" ]]; then
        log "No WATCHDOG_EMAIL configured in $CONFIG; skipping alert: $subject"
        return
    fi
    echo -e "$body" | mail -s "$subject" "$email"
}

# Check LXC Container function
checkContainer () {
    local containerName=$1
    local containerId=$2
    local containerIp=$3

    if /usr/bin/ping -c 1 "$containerIp" &> /dev/null; then
        local containerStatus
        containerStatus=$(/usr/sbin/pct status "$containerId" | awk '{print $2}')
        if [[ "$containerStatus" == "running" ]]; then
            local containerUptime
            containerUptime=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
            log "$containerName ($containerIp) is alive. Uptime: $containerUptime seconds."
        else
            log "$containerName ($containerIp) is not running. Attempting to start..."
            if /usr/sbin/pct start "$containerId"; then
                log "$containerName started successfully."
                sendAlert "$containerName Started" "The LXC container '$containerName' was started by the watchdog script."
            else
                log "Failed to start $containerName. Manual intervention required."
                sendAlert "$containerName Start Failed" "The LXC container '$containerName' failed to start. Please check Proxmox immediately."
            fi
        fi
    else
        log "$containerName ($containerIp) is down (no ping). Attempting to restart..."
        if /usr/sbin/pct stop "$containerId" && /usr/sbin/pct start "$containerId"; then
            log "$containerName restarted successfully."
            sendAlert "$containerName Restarted" "The LXC container '$containerName' was restarted by the watchdog script."
        else
            log "Failed to restart $containerName. Manual intervention required."
            sendAlert "$containerName Restart Failed" "The LXC container '$containerName' failed to restart. Please check Proxmox immediately."
        fi
    fi
}

# Main Logic
for containerName in "${!Containers[@]}"; do
    read -r containerId containerIp <<< "${Containers[$containerName]}"
    checkContainer "$containerName" "$containerId" "$containerIp" &
done

# Wait for all background checks to complete
wait
