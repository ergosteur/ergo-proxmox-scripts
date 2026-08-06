#!/bin/bash

STATE_FILE="/var/tmp/proxmox-autostart-backup.txt"
DRY_RUN=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --enable) ACTION="enable" ;;
        --disable) ACTION="disable" ;;
        --status) ACTION="status" ;;
        --dry-run) DRY_RUN=1 ;;
        *)
            echo "Usage: $0 [--enable|--disable|--status] [--dry-run]"
            exit 1
            ;;
    esac
done

if [ -z "$ACTION" ]; then
    echo "Error: must specify one of: --enable, --disable, --status"
    exit 1
fi

log() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] $1"
    else
        echo "$1"
    fi
}

enable_mode() {
    if [ -f "$STATE_FILE" ]; then
        echo "Refusing to enable maintenance mode: autostart backup already exists at $STATE_FILE"
        echo "Run with --disable first to restore original settings."
        exit 1
    fi

    echo "# Saving autostart and startup priority to $STATE_FILE"
    > "$STATE_FILE"

    # VMs
    for cfg in /etc/pve/qemu-server/*.conf; do
        vmid=$(basename "$cfg" .conf)
        if grep -q '^onboot: 1' "$cfg"; then
            startup=$(grep '^startup:' "$cfg" | awk -F': ' '{print $2}')
            echo "vm:$vmid:onboot:1:startup:$startup" >> "$STATE_FILE"
            log "Disable autostart on VM $vmid"
            [ "$DRY_RUN" -eq 0 ] && qm set "$vmid" -onboot 0
        fi
    done

    # CTs
    for cfg in /etc/pve/lxc/*.conf; do
        ctid=$(basename "$cfg" .conf)
        if grep -q '^onboot: 1' "$cfg"; then
            startup=$(grep '^startup:' "$cfg" | awk -F': ' '{print $2}')
            echo "ct:$ctid:onboot:1:startup:$startup" >> "$STATE_FILE"
            log "Disable autostart on CT $ctid"
            [ "$DRY_RUN" -eq 0 ] && pct set "$ctid" -onboot 0
        fi
    done

    echo $([ "$DRY_RUN" -eq 1 ] && echo "Dry run complete." || echo "Maintenance mode enabled.")
}

disable_mode() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "No saved autostart state found at $STATE_FILE"
        exit 1
    fi

    while IFS= read -r line; do
        type=$(echo "$line" | cut -d: -f1)
        id=$(echo "$line" | cut -d: -f2)
        onboot=$(echo "$line" | cut -d: -f4)

        case "$type" in
            vm)
                startup=$(echo "$line" | grep -o 'startup:.*' | cut -d: -f2-)
                log "Restore autostart on VM $id (onboot=$onboot${startup:+, startup=$startup})"
                if [ "$DRY_RUN" -eq 0 ]; then
                    qm set "$id" -onboot "$onboot"
                    [ -n "$startup" ] && qm set "$id" -startup "$startup"
                fi
                ;;
            ct)
                startup=$(echo "$line" | grep -o 'startup:.*' | cut -d: -f2-)
                log "Restore autostart on CT $id (onboot=$onboot${startup:+, startup=$startup})"
                if [ "$DRY_RUN" -eq 0 ]; then
                    pct set "$id" -onboot "$onboot"
                    [ -n "$startup" ] && pct set "$id" -startup "$startup"
                fi
                ;;
        esac
    done < "$STATE_FILE"

    echo $([ "$DRY_RUN" -eq 1 ] && echo "Dry run complete." || echo "Maintenance mode disabled.")
}

status_mode() {
    echo "Current autostart status:"
    echo ""

    declare -A saved_vm
    declare -A saved_ct

    if [ -f "$STATE_FILE" ]; then
        while IFS= read -r line; do
            type=$(echo "$line" | cut -d: -f1)
            id=$(echo "$line" | cut -d: -f2)
            case "$type" in
                vm) saved_vm["$id"]="$line" ;;
                ct) saved_ct["$id"]="$line" ;;
            esac
        done < "$STATE_FILE"
    fi

    echo "=== Virtual Machines ==="
    for cfg in /etc/pve/qemu-server/*.conf; do
        vmid=$(basename "$cfg" .conf)
        name=$(qm config "$vmid" | grep '^name:' | awk '{print $2}')
        onboot=$(grep -E '^onboot:' "$cfg" | awk '{print $2}')
        startup=$(grep '^startup:' "$cfg" | cut -d' ' -f2)

        status="(onboot=${onboot:-0}${startup:+, startup=$startup})"

        if [ -n "${saved_vm[$vmid]}" ]; then
            saved_onboot=$(echo "${saved_vm[$vmid]}" | cut -d: -f4)
            saved_startup=$(echo "${saved_vm[$vmid]}" | grep -o 'startup:.*' | cut -d: -f2-)
            if [[ "$onboot" == "$saved_onboot" && "$startup" == "$saved_startup" ]]; then
                match="✔ matches saved"
            else
                match="❌ differs (saved onboot=$saved_onboot${saved_startup:+, startup=$saved_startup})"
            fi
        else
            match="— not in saved state"
        fi

        echo "VM $vmid (${name:-unnamed}) $status → $match"
    done

    echo ""
    echo "=== Containers ==="
    for cfg in /etc/pve/lxc/*.conf; do
        ctid=$(basename "$cfg" .conf)
        hostname=$(pct config "$ctid" | grep '^hostname:' | awk '{print $2}')
        onboot=$(grep -E '^onboot:' "$cfg" | awk '{print $2}')
        startup=$(grep '^startup:' "$cfg" | cut -d' ' -f2)

        status="(onboot=${onboot:-0}${startup:+, startup=$startup})"

        if [ -n "${saved_ct[$ctid]}" ]; then
            saved_onboot=$(echo "${saved_ct[$ctid]}" | cut -d: -f4)
            saved_startup=$(echo "${saved_ct[$ctid]}" | grep -o 'startup:.*' | cut -d: -f2-)
            if [[ "$onboot" == "$saved_onboot" && "$startup" == "$saved_startup" ]]; then
                match="✔ matches saved"
            else
                match="❌ differs (saved onboot=$saved_onboot${saved_startup:+, startup=$saved_startup})"
            fi
        else
            match="— not in saved state"
        fi

        echo "CT $ctid (${hostname:-unnamed}) $status → $match"
    done

    echo ""
    if [ -f "$STATE_FILE" ]; then
        echo "💾 Maintenance mode appears ENABLED"
    else
        echo "✅ Maintenance mode appears DISABLED"
    fi
}

# Dispatch
case "$ACTION" in
    enable)  enable_mode ;;
    disable) disable_mode ;;
    status)  status_mode ;;
esac
