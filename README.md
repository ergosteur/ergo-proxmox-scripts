# ergo-proxmox-scripts

Host-side tooling for a Proxmox VE node: cloud-init template building, IPMI fan
control, UPS/NUT setup, and a few odds and ends.

This repository mirrors `/opt/ergosteur` on the Proxmox host. Nothing here is
live until it is copied across — see [Deploying](#deploying).

## Cloud-init templates

`build-cloudinit-template.sh` builds a Proxmox VM template from an upstream
cloud image, for any of six distributions.

```sh
sudo ./build-cloudinit-template.sh <VMID> <alpine|ubuntu|debian|fedora|almalinux|arch> [--docker]
```

It downloads the cloud image (cached under `/var/tmp/pve-cloudinit-images`),
imports it, generates a cloud-init vendor snippet that installs the QEMU guest
agent and optionally Docker, then converts the VM to a template. Storage,
bridge, memory, cores, disk size, SSH keys and the cloud-init password are all
overridable by environment variable; run with `--help` for the full list.

The snippet storage must have the **Snippets** content type enabled, which is
off by default. The script checks this up front rather than failing later.

### Version pins

The distributions fall into two groups, which is the thing worth understanding
before touching this.

Some upstreams publish a stable "latest" pointer, so their URL keeps working
without intervention:

| Distro | What tracks itself |
| --- | --- |
| Ubuntu | `<codename>/current/` — newest build within the pinned release |
| Debian | `<codename>/latest/` — newest point release |
| AlmaLinux | `-latest.x86_64.qcow2` — newest minor within the pinned major |
| Arch | rolling; no pin at all |

The rest bake an exact version into the filename, so they go stale and
eventually 404 with no warning once the mirror rotates the file out:

| Distro | Pinned as |
| --- | --- |
| Alpine | branch, patch version **and filename prefix** |
| Fedora | release and compose number, e.g. `44-1.7` |

Even the self-tracking ones still pin a *release* (Ubuntu's codename, Debian's
codename, Alma's major), so all of them need an occasional bump.

Pins live in one block near the top of `build-cloudinit-template.sh`:

```sh
ALPINE_MAJOR="v3.24"
ALPINE_PATCH="3.24.1"
ALPINE_PREFIX="generic"
UBUNTU_CODENAME="resolute"   # 26.04 LTS
UBUNTU_VER="2604"
...
```

`ALPINE_PREFIX` exists because Alpine renamed its cloud images from
`nocloud_` to `generic_` in 3.24. Only 3.24 and newer carry `generic_`, so
rolling `ALPINE_MAJOR` back to 3.23 or older means reverting the prefix too.

### Refreshing the pins

`update-image-pins.sh` does the lookup and the checking:

```sh
./update-image-pins.sh              # dry run: report what is out of date
./update-image-pins.sh --write      # apply
./update-image-pins.sh --distro fedora --distro alpine
```

It queries each distribution for its current stable release, builds the
resulting image URL, and only accepts a pin once that URL has been confirmed to
serve a real image.

Where a distribution publishes machine-readable release data, it uses that in
preference to scraping a directory listing: Ubuntu comes from
`changelogs.ubuntu.com/meta-release` — the file `do-release-upgrade` reads —
filtered to supported LTS releases, and Debian from the stable suite's own
`Release` file, so it follows Debian's definition of stable rather than
guessing from directory names. Fedora, AlmaLinux and Alpine have no equivalent
feed and are read from mirror listings.

Alpine is fully automated despite the exact-version filename, because
`latest-stable` is a symlink to the current branch: one listing yields the
branch, the patch level and the prefix together. The prefix is *read* rather
than assumed, which is what would have caught the `nocloud_` rename.

Two properties are worth preserving if this is ever modified:

- **Candidate URLs are derived from `build-cloudinit-template.sh` itself**, by
  evaluating its pin block and its `case` statement, rather than repeating its
  URL templates. A second copy of those templates would eventually disagree
  with the builder and verify something it never downloads. The template is
  read by anchor, so a restructured pin block or `case` statement is detected
  and refused rather than silently producing URLs from unset variables.
- **Nothing is written until the image serves qcow2 magic**, not merely HTTP
  200. Mirrors commonly answer for a deleted image with an HTML error page
  under a 200, which would otherwise be pinned as good and fail at build time.

A distro that fails verification keeps its old pin and does not block the
others.

Exit status: `0` current or updated cleanly, `1` usage error, `2` a lookup or
verification failed, `3` pins are stale during a dry run. The distinct `3`
means it can run unattended as a staleness check:

```sh
./update-image-pins.sh || [ $? -ne 3 ] || echo "cloud image pins are out of date"
```

Run it in a clone, not on the Proxmox host. It edits
`build-cloudinit-template.sh` in place, and because `/opt/ergosteur` is not a
git checkout, running it there would silently drift the host from this
repository.

## Other tooling

| Path | What it does |
| --- | --- |
| `ipmi-fancontrol-daemon` | Temperature-aware fan control for Dell PowerEdge/iDRAC: holds a fixed low duty while cool, hands back to the BMC curve under load. Run by `ipmi-fancontrol.service`. |
| `ipmi-fancontrol-manual` | Ad-hoc override pinning the fans to a fixed speed. Does not ramp under load. |
| `ipmi-fancontrol-auto` | Hands fan control back to the BMC's automatic curve. Also the `ExecStopPost` backstop. |
| `setup-nut-synology.sh` | Sets up NUT for a USB UPS and serves it to a Synology. See [`nut/README.md`](nut/README.md). |
| `nut/` | Reference `/etc/nut` configuration for hand-configuring a host. |
| `pa-vm_api_stop.sh` | Graceful PA-VM firewall shutdown over the PAN-OS XML API, as `ExecStop`. |
| `prox-maintenance-mode.sh` | Disables `onboot` autostart on every VM and container before host maintenance and restores it afterwards, saving the previous state to `/var/tmp`. `--enable`/`--disable`/`--status`, plus `--dry-run`. |
| `download-virtio-win-progress.py` | Fetches the virtio-win driver ISO. |
| `systemd-system/` | Unit files, installed to `/etc/systemd/system`. |
| `conf/` | Configuration, kept beside the scripts rather than in `/etc`. Committed as `.example`; the real files are not in git. |
| `unused/` | Retired, kept for reference. Each carries a header explaining why it is no longer used. |

## Deploying

`/opt/ergosteur` on the host is a plain directory, not a git checkout, so
changes have to be copied over and will not appear from a `git pull`:

```sh
scp build-cloudinit-template.sh update-image-pins.sh root@pet630:/opt/ergosteur/
```

Unit files under `systemd-system/` are mirrored to `/opt/ergosteur` for
reference, but systemd reads them from `/etc/systemd/system`. Changing one
means updating both and running `systemctl daemon-reload`.

## Conventions

- Scripts print their own usage from the header comment block; run with
  `--help`.
- Configuration lives in `conf/` beside the script, never in `/etc`.
- Retired scripts move to `unused/` with a header explaining why, rather than
  being deleted.
- Shell scripts are expected to pass `shellcheck`. Not all of the older ones do
  yet; `build-cloudinit-template.sh`, `update-image-pins.sh` and
  `setup-nut-synology.sh` are clean.
