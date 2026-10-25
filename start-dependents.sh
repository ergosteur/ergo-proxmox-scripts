#!/bin/bash
# Start the guests that depend on the passthrough VM, once it is serving.
#
# Usage:
#   ./start-dependents.sh [--check]
#
# Run at boot by dependents-start.service, after passthrough-vm-start.service
# has started the VM they need (a NAS, typically). The guests to start, in
# order, are listed in conf/dependents.conf; give each of them onboot: 0 so that
# only this starts them. VM and container IDs both work.
#
# Before starting anything it waits for WAIT_FOR (host:port) to accept a TCP
# connection, for up to WAIT_SECS seconds, because a VM that has started is not
# yet one that is serving. If it never answers the guests are started anyway,
# with a warning, which is no worse than not waiting at all.
#
# A guest that fails to start does not stop the others; the script exits
# non-zero at the end so the unit shows as failed. Guests already running are
# left alone. Nothing is started while prox-maintenance-mode.sh has autostart
# disabled.
#
# Options:
#   --check   Show what would be started and test WAIT_FOR once; start nothing
#
# The config is looked for relative to this script, so this works both in a
# checkout and deployed at /opt/ergosteur. Override with DEPENDENTS_CONFIG.

set -uo pipefail

# Print the header comment block: everything from line 2 up to the first blank line.
usage() {
    sed -n '2,/^$/p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${DEPENDENTS_CONFIG:-$SCRIPT_DIR/conf/dependents.conf}
MAINT_STATE=/var/tmp/proxmox-autostart-backup.txt  # written by prox-maintenance-mode.sh --enable
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --check)   CHECK_ONLY=true; shift ;;
        *) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

[[ -r $CONFIG ]] || { echo "Error: cannot read $CONFIG" >&2; exit 1; }
GUESTS=()
WAIT_FOR=""
WAIT_SECS=300
# shellcheck source=conf/dependents.conf.example
source "$CONFIG"

if [[ -e $MAINT_STATE ]]; then
    echo "maintenance mode is on ($MAINT_STATE exists); not starting anything"
    exit 0
fi
if [[ ${#GUESTS[@]} -eq 0 ]]; then
    echo "no GUESTS listed in $CONFIG; nothing to do"
    exit 0
fi

# True once host:port accepts a TCP connection.
answers() {
    timeout 3 bash -c "exec 3<>/dev/tcp/${1%:*}/${1##*:}" 2>/dev/null
}

if [[ -n $WAIT_FOR ]]; then
    if $CHECK_ONLY; then
        if answers "$WAIT_FOR"; then
            echo "$WAIT_FOR answers"
        else
            echo "$WAIT_FOR is not answering right now"
        fi
    else
        echo "waiting up to ${WAIT_SECS}s for $WAIT_FOR"
        deadline=$((SECONDS + WAIT_SECS))
        until answers "$WAIT_FOR"; do
            if (( SECONDS >= deadline )); then
                echo "WARNING: $WAIT_FOR still not answering after ${WAIT_SECS}s; starting the guests anyway"
                break
            fi
            sleep 5
        done
        answers "$WAIT_FOR" && echo "$WAIT_FOR answers"
    fi
fi

failed=0
for id in "${GUESTS[@]}"; do
    if [[ -e /etc/pve/qemu-server/$id.conf ]]; then
        tool=qm conf=/etc/pve/qemu-server/$id.conf
    elif [[ -e /etc/pve/lxc/$id.conf ]]; then
        tool=pct conf=/etc/pve/lxc/$id.conf
    else
        echo "ERROR: no VM or container $id on this node" >&2
        failed=1
        continue
    fi
    if grep -q '^onboot: 1' "$conf"; then
        echo "WARNING: $id has onboot: 1, so Proxmox starts it before the VM it needs; set onboot: 0"
    fi
    if [[ $($tool status "$id" 2>/dev/null) == "status: running" ]]; then
        echo "$id is already running"
        continue
    fi
    if $CHECK_ONLY; then
        echo "would start $id ($tool)"
    elif $tool start "$id"; then
        echo "started $id ($tool)"
    else
        echo "ERROR: $tool start $id failed" >&2
        failed=1
    fi
done
exit "$failed"
