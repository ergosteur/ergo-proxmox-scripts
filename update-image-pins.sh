#!/bin/bash
# Refresh the cloud image version pins in build-cloudinit-template.sh.
#
# Usage:
#   ./update-image-pins.sh [--write] [--distro <name>] [--script <path>]
#
# Queries each distribution's upstream for its current stable release, builds
# the image URL exactly as the template script would, and only accepts a new
# pin once that URL has been confirmed to serve a real qcow2. Reports what
# would change and exits without touching anything unless --write is given.
#
# Options:
#   --write           Apply the changes (default is a dry run)
#   --distro <name>   Check only one distro, repeatable
#   --script <path>   Template script to update
#                     (default: build-cloudinit-template.sh beside this one)
#
# Exit status is 0 when everything is already current or was updated cleanly,
# 1 on a usage error, 2 when a distro could not be checked, and 3 when pins are
# out of date during a dry run, so CI can use it as a staleness check.
#
# Arch is rolling and Debian's URL already tracks "latest" within a release, so
# neither needs a lookup here beyond confirming the image still resolves.

set -euo pipefail

# Print the header comment block: everything from line 2 up to the first blank line.
usage() {
    sed -n '2,/^$/p' "$0" | sed -e 's/^#//' -e 's/^ //'
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET="$SCRIPT_DIR/build-cloudinit-template.sh"
WRITE=false
ONLY=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --write)   WRITE=true; shift ;;
        --distro)  [[ -n "${2:-}" ]] || { echo "Error: --distro needs a value." >&2; exit 1; }
                   ONLY+=("$2"); shift 2 ;;
        --script)  [[ -n "${2:-}" ]] || { echo "Error: --script needs a value." >&2; exit 1; }
                   TARGET="$2"; shift 2 ;;
        *) echo "Error: unknown option '$1'." >&2; usage >&2; exit 1 ;;
    esac
done

for bin in curl sed grep sort; do
    command -v "$bin" >/dev/null || { echo "Required command '$bin' not found." >&2; exit 1; }
done

[[ -f "$TARGET" ]] || { echo "Error: template script not found at $TARGET" >&2; exit 1; }
[[ -w "$TARGET" ]] || [[ "$WRITE" == false ]] || { echo "Error: $TARGET is not writable." >&2; exit 1; }

wanted() {
    [[ ${#ONLY[@]} -eq 0 ]] && return 0
    local d
    for d in "${ONLY[@]}"; do [[ "$d" == "$1" ]] && return 0; done
    return 1
}

# Retry rather than fail on a single flaky mirror; a transient 503 should not
# look like "this release no longer exists".
fetch() {
    curl -sSL --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused "$1" 2>/dev/null
}

# A mirror that has lost an image often serves an HTML error page with a 200,
# so check the qcow2 magic ("QFI\xfb") rather than trusting the status code.
image_ok() {
    local url=$1 code magic
    code=$(curl -sIL --max-time 30 --retry 2 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
    [[ "$code" == 200 ]] || return 1
    magic=$(curl -sL --max-time 30 --retry 2 -r 0-3 "$url" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')
    [[ "$magic" == "514649fb" ]]
}

# Read a pin's current value out of the template script.
current_pin() {
    sed -nE "s/^$1=\"([^\"]*)\".*/\1/p" "$TARGET" | head -1
}

# Derive the image URLs from the template script itself rather than repeating
# its URL templates here. Keeping one copy means this script cannot silently
# drift from what the builder actually downloads.
image_urls_from() {
    local script=$1 pins cases out
    pins=$(sed -n '/^# --- Distribution version pins/,/^# Arch is rolling/p' "$script")
    cases=$(sed -n '/^case \$DISTRO_CHOICE in$/,/^esac$/p' "$script")
    # Both anchors must have matched something recognisable. Without this an
    # unmatched anchor yields an empty fragment that still runs, producing URLs
    # built from unset pins rather than an obvious failure.
    grep -qE '^[A-Z_]+="' <<<"$pins" || return 1
    grep -q '^esac$' <<<"$cases" || return 1
    out=$(
        {
            # set -u so a pin the case block references but the extracted block
            # does not define aborts here, instead of interpolating as empty.
            echo 'set -u'
            printf '%s\n' "$pins"
            echo 'for DISTRO_CHOICE in alpine ubuntu debian fedora almalinux arch; do'
            printf '%s\n' "$cases"
            echo 'printf "%s %s\n" "$DISTRO_CHOICE" "$IMAGE_URL"; done'
        } | bash 2>/dev/null
    ) || true
    # Six distros in, six URLs out; anything less means the template no longer
    # has the shape this script reads.
    [[ $(grep -c . <<<"$out") -eq 6 ]] || return 1
    printf '%s\n' "$out"
}

url_for() { grep "^$1 " <<<"$URLS" | cut -d' ' -f2-; }

# --- Upstream lookups -------------------------------------------------------
# Each prints "PIN_NAME=value" lines, or nothing when the lookup fails.

# meta-release is what do-release-upgrade reads, so it is the authoritative
# statement of which LTS is current and still supported.
discover_ubuntu() {
    local block codename version major minor
    block=$(fetch https://changelogs.ubuntu.com/meta-release) || return 1
    read -r codename version < <(
        awk '/^Dist:/{d=$2} /^Version:/{v=$2; lts=($3=="LTS")} /^Supported:/{if ($2==1 && lts) print d, v}' \
            <<<"$block" | sort -k2 -V | tail -1
    )
    [[ -n "$codename" && -n "$version" ]] || return 1
    # Version is "26.04" but "24.04.4" once point releases start, and the pin
    # wants just the release, so keep the first two components.
    IFS=. read -r major minor _ <<<"$version"
    [[ -n "$major" && -n "$minor" ]] || return 1
    printf 'UBUNTU_CODENAME=%s\nUBUNTU_VER=%s\n' "$codename" "$major$minor"
}

# The stable suite's own Release file, so this follows Debian's definition of
# stable and cannot be fooled by a testing directory appearing on the mirror.
discover_debian() {
    local release codename version
    release=$(fetch https://deb.debian.org/debian/dists/stable/Release) || return 1
    codename=$(sed -nE 's/^Codename: (.*)/\1/p' <<<"$release" | head -1)
    version=$(sed -nE 's/^Version: ([0-9]+).*/\1/p' <<<"$release" | head -1)
    [[ -n "$codename" && -n "$version" ]] || return 1
    printf 'DEBIAN_CODENAME=%s\nDEBIAN_VER=%s\n' "$codename" "$version"
}

# Fedora bakes an exact compose number into the filename, so the release has to
# be read off the mirror. Walk down from the newest: a branched release appears
# under releases/ shortly before its cloud images land, and the highest
# numbered directory is briefly not yet installable.
discover_fedora() {
    local base=https://dl.fedoraproject.org/pub/fedora/linux/releases majors ver img rel
    majors=$(fetch "$base/") || return 1
    majors=$(grep -oE 'href="[0-9]+/"' <<<"$majors" | tr -dc '0-9\n' | sort -un | tail -3 | tac)
    [[ -n "$majors" ]] || return 1
    for ver in $majors; do
        img=$(fetch "$base/$ver/Cloud/x86_64/images/") || continue
        rel=$(grep -oE "Fedora-Cloud-Base-Generic-$ver-[0-9]+\.[0-9]+\.x86_64\.qcow2" <<<"$img" |
              sed -E "s/.*-$ver-([0-9.]+)\.x86_64\.qcow2/\1/" | sort -uV | tail -1)
        [[ -n "$rel" ]] || continue
        printf 'FEDORA_VER=%s\nFEDORA_RELEASE=%s\n' "$ver" "$rel"
        return 0
    done
    return 1
}

# Only the major version is pinned; the URL's "-latest" suffix tracks minors.
# Integer directories only, so 10 is considered but 10.2 is not.
discover_almalinux() {
    local dirs ver
    dirs=$(fetch https://repo.almalinux.org/almalinux/) || return 1
    ver=$(grep -oE 'href="[0-9]+/"' <<<"$dirs" | tr -dc '0-9\n' | sort -un | tail -1)
    [[ -n "$ver" ]] || return 1
    printf 'ALMA_VER=%s\n' "$ver"
}

# latest-stable is a symlink to the current branch, so the filename there gives
# the patch level and the prefix at once. Reading the prefix rather than
# assuming it is what lets the nocloud_ -> generic_ rename be picked up.
discover_alpine() {
    local listing file prefix patch
    listing=$(fetch https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/) || return 1
    file=$(grep -oE '[a-z]+_alpine-[0-9]+\.[0-9]+\.[0-9]+-x86_64-uefi-cloudinit-r0\.qcow2' <<<"$listing" |
           sort -uV | tail -1)
    [[ -n "$file" ]] || return 1
    prefix=${file%%_alpine-*}
    patch=$(sed -E 's/.*_alpine-([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/' <<<"$file")
    [[ -n "$prefix" && -n "$patch" ]] || return 1
    # The branch directory is the first two components of the patch version.
    printf 'ALPINE_MAJOR=v%s\nALPINE_PATCH=%s\nALPINE_PREFIX=%s\n' "${patch%.*}" "$patch" "$prefix"
}

# --- Collect proposals ------------------------------------------------------

DISTROS=(alpine ubuntu debian fedora almalinux)
declare -A PROPOSED=()
CHANGED=()
FAILED=()

echo "Checking upstream for current stable releases..."
for distro in "${DISTROS[@]}"; do
    wanted "$distro" || continue
    if ! result=$("discover_$distro"); then
        echo "  $distro: lookup FAILED" >&2
        FAILED+=("$distro")
        continue
    fi
    distro_changed=false
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        PROPOSED["$key"]=$value
        [[ "$(current_pin "$key")" != "$value" ]] && distro_changed=true
    done <<<"$result"
    if [[ "$distro_changed" == true ]]; then
        CHANGED+=("$distro")
        echo "  $distro: update available"
    else
        echo "  $distro: current"
    fi
done

# --- Verify against a candidate copy before proposing anything --------------

CANDIDATE=$(mktemp)
trap 'rm -f "$CANDIDATE"' EXIT
cp "$TARGET" "$CANDIDATE"

for key in "${!PROPOSED[@]}"; do
    value=${PROPOSED[$key]}
    # Replace only the quoted value so trailing comments on the pin survive.
    sed -i -E "s|^($key=)\"[^\"]*\"|\1\"$value\"|" "$CANDIDATE"
done

# The Ubuntu comment names the release, so regenerate it rather than let it go
# stale against the codename beside it.
if [[ -n "${PROPOSED[UBUNTU_VER]:-}" ]]; then
    v=${PROPOSED[UBUNTU_VER]}
    sed -i -E "s|^(UBUNTU_CODENAME=\"[^\"]*\").*|\1   # ${v:0:2}.${v:2} LTS|" "$CANDIDATE"
fi

if ! URLS=$(image_urls_from "$CANDIDATE"); then
    echo "Error: could not derive image URLs from $TARGET." >&2
    echo "The pin block or the 'case \$DISTRO_CHOICE' block has probably been restructured;" >&2
    echo "this script reads both by anchor and needs them intact." >&2
    exit 2
fi

if [[ ${#CHANGED[@]} -eq 0 ]]; then
    echo
    echo "All pins are already current."
    [[ ${#FAILED[@]} -gt 0 ]] && exit 2
    exit 0
fi

echo
echo "Verifying candidate images..."
VERIFIED=()
for distro in "${CHANGED[@]}"; do
    url=$(url_for "$distro")
    if image_ok "$url"; then
        echo "  $distro: OK  $url"
        VERIFIED+=("$distro")
    else
        # Refuse the bump rather than write a pin that 404s at build time.
        echo "  $distro: UNVERIFIED, pin left alone  $url" >&2
        FAILED+=("$distro")
    fi
done

if [[ ${#VERIFIED[@]} -eq 0 ]]; then
    echo >&2
    echo "No candidate image could be verified. Nothing to do." >&2
    exit 2
fi

# Drop the pins of any distro that failed verification, so a bad lookup for one
# distro cannot block the others or sneak a broken URL in alongside them.
if [[ ${#VERIFIED[@]} -ne ${#CHANGED[@]} ]]; then
    cp "$TARGET" "$CANDIDATE"
    for key in "${!PROPOSED[@]}"; do
        keep=false
        for distro in "${VERIFIED[@]}"; do
            prefix=$(tr '[:lower:]' '[:upper:]' <<<"${distro/almalinux/alma}")
            [[ "$key" == "${prefix}_"* ]] && keep=true
        done
        [[ "$keep" == true ]] || continue
        sed -i -E "s|^($key=)\"[^\"]*\"|\1\"${PROPOSED[$key]}\"|" "$CANDIDATE"
    done
    if [[ -n "${PROPOSED[UBUNTU_VER]:-}" ]] && [[ " ${VERIFIED[*]} " == *" ubuntu "* ]]; then
        v=${PROPOSED[UBUNTU_VER]}
        sed -i -E "s|^(UBUNTU_CODENAME=\"[^\"]*\").*|\1   # ${v:0:2}.${v:2} LTS|" "$CANDIDATE"
    fi
fi

echo
echo "Proposed pin changes:"
diff -u "$TARGET" "$CANDIDATE" | sed -n '/^[-+][A-Z]/p' || true

if [[ "$WRITE" != true ]]; then
    echo
    echo "Dry run. Re-run with --write to apply."
    exit 3
fi

if ! bash -n "$CANDIDATE"; then
    echo "Error: the updated script does not parse. Refusing to write." >&2
    exit 2
fi

cp "$CANDIDATE" "$TARGET"
echo
echo "Updated $TARGET."
echo "Review with 'git diff' and remember the Proxmox host needs the new copy."
[[ ${#FAILED[@]} -gt 0 ]] && exit 2
exit 0
