#!/bin/bash
# Gracefully shut down the PA-VM firewall through the PAN-OS XML API.
# Invoked as ExecStop by stop-pa-vm.service so the firewall goes down cleanly on host shutdown.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${PA_VM_CONFIG:-$SCRIPT_DIR/conf/pa-vm.conf}

if [[ ! -r "$CONFIG" ]]; then
    echo "Error: cannot read $CONFIG" >&2
    echo "Copy conf/pa-vm.conf.example there and fill in the API key." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONFIG"

: "${PA_VM_HOST:?not set in $CONFIG}"
: "${PA_VM_API_KEY:?not set in $CONFIG}"

wall "Shutting down PA-VM via XML API"

# --config - takes the request on stdin so the API key never reaches the process
# table. --insecure is deliberate: the firewall serves a self-signed certificate.
/usr/bin/curl --config - <<EOF
url = "https://${PA_VM_HOST}/api/?type=op&cmd=<request><shutdown><system></system></shutdown></request>"
header = "X-PAN-KEY: ${PA_VM_API_KEY}"
insecure
silent
show-error
fail
EOF
