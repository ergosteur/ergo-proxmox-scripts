#!/bin/bash
#
# WatchDog script for Proxmox VMs
# v2.0
#
# Install using `crontab -e` like this: * * * * * /root/watchdog.sh
#
# Configurable Settings
declare -A VMs=(
    ["pfsense"]="2801 10.20.28.1"
)

logFile="/var/log/proxmox_watchdog.log"
email="alerts@example.com"

# Log function
log () {
    output="[WatchDog] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$output" >> "$logFile"
    logger "$output"
}

# Send email alert
sendAlert () {
    subject="[Proxmox WatchDog] $1"
    body="$2"
    echo -e "$body" | mail -s "$subject" "$email"
}

# Check VM function
checkVM () {
    local vmName=$1
    local vmId=$2
    local vmIp=$3

    if /usr/bin/ping -c 1 "$vmIp" &> /dev/null; then
        local vmUptime
        vmUptime=$(/usr/sbin/qm status "$vmId" -verbose | grep uptime | cut -f2 -d' ')
        log "$vmName ($vmIp) is alive. Uptime: $vmUptime seconds."
    else
        log "$vmName ($vmIp) is down. Attempting restart..."
        if /usr/sbin/qm stop "$vmId" && /usr/sbin/qm start "$vmId"; then
            log "$vmName restarted successfully."
            sendAlert "$vmName Restarted" "The VM '$vmName' was restarted by the watchdog script."
        else
            log "Failed to restart $vmName. Manual intervention required."
            sendAlert "$vmName Restart Failed" "The VM '$vmName' failed to restart. Please check Proxmox immediately."
        fi
    fi
}

# Main Logic
for vmName in "${!VMs[@]}"; do
    read -r vmId vmIp <<< "${VMs[$vmName]}"
    checkVM "$vmName" "$vmId" "$vmIp" &
done

# Wait for all background checks to complete
wait
