#!/bin/bash
# Set up NUT from scratch for a USB UPS, as a NUT server a Synology can use.
#
# Detects the attached USB UPS, writes a working NUT configuration, and starts
# the driver, upsd and upsmon. The result is a NUT server that Synology DSM can
# connect to with "UPS Type: Synology UPS Server".
#
# DSM's client is rigid about three things, which this script guarantees:
#   * the UPS must be named exactly "ups"
#   * it logs in as user "monuser" with password "secret"
#   * upsd must listen on an address DSM can reach
#
# Usage:
#   ./setup-nut-synology.sh [options]
#
# Options:
#   -n, --dry-run           Show what would be written, change nothing
#   -y, --yes               Do not prompt before overwriting an existing config
#       --listen ADDR       Address for upsd to listen on   (default: 0.0.0.0)
#       --admin-password P  Password for the local admin user
#                           (default: reuse existing, else generate)
#       --ups-name NAME     NUT device name                 (default: ups)
#       --device-index N    Pick the Nth UPS when more than one is detected
#       --etc-dir DIR       Write config to DIR instead of /etc/nut (for testing)
#   -h, --help              This text
#
# Example:
#   sudo ./setup-nut-synology.sh --listen 10.20.28.30

set -euo pipefail

ETC_DIR=/etc/nut
LISTEN_ADDR=0.0.0.0
UPS_NAME=ups
ADMIN_PASSWORD=""
DEVICE_INDEX=1
DRY_RUN=false
ASSUME_YES=false

# DSM hardcodes these; they are not configurable on the Synology side.
SYNOLOGY_USER=monuser
SYNOLOGY_PASSWORD=secret

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^#//' -e 's/^ //'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)       DRY_RUN=true; shift ;;
        -y|--yes)           ASSUME_YES=true; shift ;;
        --listen)           LISTEN_ADDR="${2:?--listen needs an address}"; shift 2 ;;
        --admin-password)   ADMIN_PASSWORD="${2:?--admin-password needs a value}"; shift 2 ;;
        --ups-name)         UPS_NAME="${2:?--ups-name needs a value}"; shift 2 ;;
        --device-index)     DEVICE_INDEX="${2:?--device-index needs a number}"; shift 2 ;;
        --etc-dir)          ETC_DIR="${2:?--etc-dir needs a path}"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    die "must run as root (try: sudo $0)"
fi

if [[ "$UPS_NAME" != "ups" ]]; then
    warn "Synology DSM only ever asks for a UPS named 'ups'. With --ups-name $UPS_NAME the DSM client will not find it."
fi

# --- 1. Packages ------------------------------------------------------------

need_pkgs=()
command -v upsd        >/dev/null || need_pkgs+=(nut-server)
command -v upsc        >/dev/null || need_pkgs+=(nut-client)
command -v nut-scanner >/dev/null || need_pkgs+=(nut-server)

if [[ ${#need_pkgs[@]} -gt 0 ]]; then
    if $DRY_RUN; then
        say "[dry-run] would install: ${need_pkgs[*]}"
    else
        command -v apt-get >/dev/null || die "missing ${need_pkgs[*]} and apt-get is not available; install NUT manually"
        say "Installing ${need_pkgs[*]}..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need_pkgs[@]}"
    fi
fi

# --- 2. Detect the UPS ------------------------------------------------------

say "Scanning for a USB UPS..."
if ! command -v nut-scanner >/dev/null; then
    die "nut-scanner not available, cannot detect the UPS"
fi

SCAN=$(nut-scanner -U -q 2>/dev/null || true)
SECTIONS=$(grep -c '^\[' <<<"$SCAN" || true)

if [[ -z "$SCAN" || "$SECTIONS" -eq 0 ]]; then
    say ""
    say "No USB UPS detected. Things worth checking:"
    say "  * is the UPS actually connected over USB, and powered on?"
    say "  * lsusb  -- does the UPS appear at all?"
    say "  * is another process holding the device? On a hypervisor a USB"
    say "    passthrough to a guest claims it exclusively and NUT can never"
    say "    attach. On Proxmox, look for a 'usb0: host=VVVV:PPPP' line in"
    say "    the guest config and remove it."
    die "nothing to configure"
fi

if [[ "$SECTIONS" -gt 1 ]]; then
    say "Detected $SECTIONS UPS devices:"
    awk '/^\[/ {n++; name=$0} /product =/ {if (n) printf "  %d) %s %s\n", n, name, $0}' <<<"$SCAN"
    if [[ "$DEVICE_INDEX" -gt "$SECTIONS" ]]; then
        die "--device-index $DEVICE_INDEX is out of range (1-$SECTIONS)"
    fi
    say "Using device $DEVICE_INDEX (override with --device-index)."
fi

# Pull the Nth section's settings, dropping keys that should not be pinned:
# "bus" changes across replug, and the section header is renamed to $UPS_NAME.
DEVICE_CONF=$(awk -v want="$DEVICE_INDEX" '
    /^\[/ { n++; next }
    n == want && /=/ {
        # nut-scanner indents its own output; normalise before re-indenting.
        sub(/^[[:space:]]+/, "")
        key = $1
        # Skip its ###NOTMATCHED-YET### markers for attributes it could not map.
        if (key ~ /^#/) next
        if (key == "bus" || key == "busport" || key == "device") next
        print "\t" $0
    }
' <<<"$SCAN")

[[ -n "$DEVICE_CONF" ]] || die "could not parse nut-scanner output for device $DEVICE_INDEX"

# A friendly description for DSM to display.
UPS_VENDOR=$(sed -n 's/.*vendor = "\(.*\)".*/\1/p' <<<"$DEVICE_CONF" | head -1)
UPS_PRODUCT=$(sed -n 's/.*product = "\(.*\)".*/\1/p' <<<"$DEVICE_CONF" | head -1)
UPS_DESC="${UPS_VENDOR:-USB} ${UPS_PRODUCT:-UPS}"

say "Found: $UPS_DESC"

# --- 3. Is anything else holding the device? --------------------------------

VID=$(sed -n 's/.*vendorid = "\(.*\)".*/\1/p' <<<"$DEVICE_CONF" | head -1)
PID=$(sed -n 's/.*productid = "\(.*\)".*/\1/p' <<<"$DEVICE_CONF" | head -1)

if [[ -n "$VID" && -n "$PID" ]] && command -v fuser >/dev/null; then
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" ]] || continue
        [[ "$(cat "$dev/idVendor" 2>/dev/null)" == "$VID" ]] || continue
        [[ "$(cat "$dev/idProduct" 2>/dev/null)" == "$PID" ]] || continue
        node=$(printf '/dev/bus/usb/%03d/%03d' \
            "$(cat "$dev/busnum" 2>/dev/null || echo 0)" \
            "$(cat "$dev/devnum" 2>/dev/null || echo 0)")
        [[ -e "$node" ]] || continue
        # fuser can report several PIDs; handle each one separately rather than
        # letting them run together into a single meaningless number.
        for holder in $(fuser "$node" 2>/dev/null || true); do
            holder=${holder//[^0-9]/}
            [[ -n "$holder" ]] || continue
            hname=$(ps -o comm= -p "$holder" 2>/dev/null || echo unknown)
            case "$hname" in
                usbhid-ups|*nut*|blazer*|snmp-ups|*-ups)
                    continue ;;  # our own driver from a previous run, fine
            esac
            warn "$node is held by PID $holder ($hname)."
            if [[ "$hname" == "kvm" || "$hname" == "qemu"* ]]; then
                warn "That is a VM holding the UPS via USB passthrough. NUT cannot attach until it is released."
                warn "On Proxmox: find the guest with 'usb0: host=$VID:$PID' and remove that line."
            fi
        done
    done
fi

# --- 4. Preserve the admin password across re-runs --------------------------

if [[ -z "$ADMIN_PASSWORD" && -r "$ETC_DIR/upsd.users" ]]; then
    ADMIN_PASSWORD=$(awk '
        /^\[admin\]/ { inblock = 1; next }
        /^\[/        { inblock = 0 }
        inblock && /password/ { sub(/.*=[[:space:]]*/, ""); print; exit }
    ' "$ETC_DIR/upsd.users")
    [[ -n "$ADMIN_PASSWORD" ]] && say "Reusing the existing admin password."
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20)
    [[ -n "$ADMIN_PASSWORD" ]] || die "could not generate an admin password; pass --admin-password"
    say "Generated a new admin password."
fi

# --- 5. Confirm before touching an existing config --------------------------

EXISTING=()
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
    [[ -f "$ETC_DIR/$f" ]] && EXISTING+=("$f")
done

if [[ ${#EXISTING[@]} -gt 0 ]] && ! $DRY_RUN && ! $ASSUME_YES; then
    say ""
    say "About to overwrite in $ETC_DIR: ${EXISTING[*]}"
    say "Each will be backed up alongside with a .bak-<timestamp> suffix."
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" == [yY]* ]] || die "aborted"
fi

STAMP=$(date +%Y%m%d-%H%M%S)

write_file() {
    local path="$1" mode="$2" group="$3" content="$4"
    if $DRY_RUN; then
        say ""
        say "===== [dry-run] $path (mode $mode, root:$group) ====="
        printf '%s\n' "$content"
        return
    fi
    mkdir -p "$(dirname "$path")"
    [[ -f "$path" ]] && cp -a "$path" "$path.bak-$STAMP"
    printf '%s\n' "$content" > "$path"
    chown "root:$group" "$path" 2>/dev/null || chown root:root "$path"
    chmod "$mode" "$path"
}

# --- 6. Write the configuration ---------------------------------------------

NUT_GROUP=nut
getent group nut >/dev/null || NUT_GROUP=root

write_file "$ETC_DIR/nut.conf" 0640 "$NUT_GROUP" \
"# Managed by setup-nut-synology.sh
# netserver: run a driver locally and serve it to other machines over the network.
MODE=netserver"

write_file "$ETC_DIR/ups.conf" 0640 "$NUT_GROUP" \
"# Managed by setup-nut-synology.sh
#
# The section name is what clients ask for. Synology DSM only ever requests
# \"ups\", so renaming this section will stop DSM from finding the UPS.
#
# The vendorid/productid/serial lines below pin this entry to the exact unit
# that was detected. Drop the serial and product lines if you want the config to
# survive swapping in a different UPS of the same model.

maxretry = 3

[$UPS_NAME]
	desc = \"$UPS_DESC\"
$DEVICE_CONF"

write_file "$ETC_DIR/upsd.conf" 0640 "$NUT_GROUP" \
"# Managed by setup-nut-synology.sh
# Must be reachable by the Synology. 0.0.0.0 listens on every interface.
LISTEN $LISTEN_ADDR 3493"

write_file "$ETC_DIR/upsd.users" 0640 "$NUT_GROUP" \
"# Managed by setup-nut-synology.sh
#
# admin: used by this machine's own upsmon, which owns the UPS.
[admin]
	password = $ADMIN_PASSWORD
	upsmon primary
	actions = SET
	instcmds = ALL

# monuser: for Synology DSM, which hardcodes both the username and the password
# and cannot be configured to use anything else. The secondary role only permits
# reading status and receiving shutdown notifications, not commanding the UPS.
[$SYNOLOGY_USER]
	password = $SYNOLOGY_PASSWORD
	upsmon secondary"

write_file "$ETC_DIR/upsmon.conf" 0640 "$NUT_GROUP" \
"# Managed by setup-nut-synology.sh
#
# This machine owns the UPS, so it is the primary: it shuts down last, after
# secondaries such as the Synology have been told to go.

RUN_AS_USER nut

MONITOR $UPS_NAME@localhost 1 admin $ADMIN_PASSWORD primary

MINSUPPLIES 1
SHUTDOWNCMD \"/sbin/shutdown -h +0\"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
FINALDELAY 5"

if $DRY_RUN; then
    say ""
    say "[dry-run] no services were started and nothing was written."
    exit 0
fi

# --- 7. Start everything ----------------------------------------------------

if [[ "$ETC_DIR" != "/etc/nut" ]]; then
    say ""
    say "Config written to $ETC_DIR; skipping service start because that is not /etc/nut."
    exit 0
fi

say ""
say "Starting services..."
# Regenerate the per-device nut-driver@ instances from the new ups.conf.
systemctl daemon-reload
if systemctl list-unit-files nut-driver-enumerator.service >/dev/null 2>&1; then
    systemctl restart nut-driver-enumerator.service || true
fi

systemctl enable --now nut-server  >/dev/null 2>&1 || true
systemctl enable --now nut-monitor >/dev/null 2>&1 || true
systemctl restart "nut-driver@$UPS_NAME.service" 2>/dev/null || systemctl restart nut-driver.target || true
systemctl restart nut-server
systemctl restart nut-monitor

# --- 8. Verify --------------------------------------------------------------

say ""
say "Verifying..."
ok=true
for i in $(seq 1 10); do
    if upsc "$UPS_NAME" >/dev/null 2>&1; then break; fi
    sleep 2
    [[ $i -eq 10 ]] && ok=false
done

if ! $ok; then
    say "Could not read the UPS after 20s. Check:"
    say "  journalctl -u nut-driver@$UPS_NAME -n 30"
    exit 1
fi

STATUS=$(upsc "$UPS_NAME" ups.status 2>/dev/null || echo "?")
CHARGE=$(upsc "$UPS_NAME" battery.charge 2>/dev/null || echo "?")

say "  UPS reachable: ups.status=$STATUS battery.charge=$CHARGE"

if command -v ss >/dev/null && ss -lnt 2>/dev/null | grep -q ':3493'; then
    say "  upsd listening on 3493"
else
    warn "upsd does not appear to be listening on 3493"
fi

say ""
say "Done. On the Synology: Control Panel > Hardware & Power > UPS,"
say "enable UPS support, set UPS Type to \"Synology UPS Server\", and point it"
say "at this host's IP. It will log in as $SYNOLOGY_USER automatically."
say ""
say "The local admin password is stored in $ETC_DIR/upsd.users (root-readable only)."
