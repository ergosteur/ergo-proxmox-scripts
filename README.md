# ergo-proxmox-scripts

Host-side tooling for a Proxmox VE node: cloud-init template building, IPMI fan
control, UPS/NUT setup, and a few odds and ends.

`/opt/ergosteur` on the Proxmox host is a checkout of this repository. Nothing
here is live until the host pulls — see [Deploying](#deploying).

## Cloud-init templates

`build-cloudinit-template.sh` builds a Proxmox VM template from an upstream
cloud image, for any of six distributions.

```sh
sudo ./build-cloudinit-template.sh <VMID> <alpine|ubuntu|debian|fedora|almalinux|arch> [--docker]
```

It downloads the cloud image (cached under `/var/tmp/pve-cloudinit-images`),
imports it, generates a cloud-init vendor snippet that installs the QEMU guest
agent, then converts the VM to a template. Storage, bridge, memory, cores, disk
size, SSH keys and the cloud-init password are all overridable by environment
variable; run with `--help` for the full list.

The snippet storage must have the **Snippets** content type enabled, which is
off by default. The script checks this up front rather than failing later.

`--docker`, which must be the third argument, adds a Docker install to the
snippet, suffixes the template name with `-docker` and tags it `docker`. Alpine
and Arch use their own packages; the others use the convenience script from
`get.docker.com`, so they get Docker CE rather than the distro build. The
cloud-init user is added to the `docker` group, which is root-equivalent on
that guest.

Note that the install happens on first boot of each *clone*, not during the
build — the snippet is a `runcmd` and the template itself is never booted. Each
clone therefore fetches Docker itself and reboots once. Nothing is baked into
the template image.

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

## Fan control

`ipmi-fancontrol-daemon` (run by `ipmi-fancontrol.service`) holds the fans at the
duty set in `conf/ipmi-fancontrol.conf` while the CPUs are cool, re-sending it every
poll because the BMC has been seen to drop manual mode on its own, and hands back to
the BMC's curve at `CPU_TEMP_THRESHOLD`.

`ipmi-fancontrol-tui` is a terminal dashboard for it: live temperatures and fan RPMs,
and controls laid out like a car's climate panel.

```
 Mode: MANUAL at 30%    Service: active (standing down)    Hold: 21%    CPU max: 58°C / 70°C
 ...temperatures and fans...
 ┌─ AUTO ─────────────────────┐                      ┌─ FAN CONTROL DAEMON ──────────────┐
 │ [Daemon control][BMC control] [Manual]             │ [STOP] [RESTART] [Set hold 30%]   │
 └────────────────────────────┘                      └───────────────────────────────────┘
 duty slider, then -5 / +5 / presets
```

```sh
ssh -t root@pet630 /opt/ergosteur/ipmi-fancontrol-tui     # the dashboard
/opt/ergosteur/ipmi-fancontrol-tui --check                # print one reading, change nothing
```

It needs [uv](https://docs.astral.sh/uv/): the script declares its own dependency
(Textual), which uv fetches on first run. It also needs root for the local `open`
interface. The top bar shows the mode, the systemd service state, the daemon's hold speed
(`FAN_SPEED`) and the hottest CPU.

- **Daemon control** (the default) only reads. Nothing is sent and the daemon stays
  in charge. **BMC control** forces the iDRAC's own curve, and **Manual** pins all fans
  to the slider's duty. Moving the slider or pressing any duty button (`+`, `-`, the
  presets) switches to Manual by itself, subject to the checks below. The last two write the TUI's PID to
  `/run/ipmi-fancontrol.override` (`OVERRIDE_FILE` in the config), and the daemon
  stands down for as long as that PID is alive. If the TUI crashes or loses its SSH
  session the PID goes stale and the daemon resumes by itself within one poll.
  Daemon control is refused while the service is stopped.
- **Manual has no thermal response**, so it drops back to BMC control if a CPU reaches
  `CPU_TEMP_THRESHOLD`, if the temperatures cannot be read for three polls, and when
  you quit. It will not enter manual mode while the CPU temperature is unknown or
  already at the threshold. The slider floor is 5 %. An exit handler also hands the
  fans to the BMC if the TUI crashes while in manual, which matters when the daemon
  is stopped and so cannot resume. Only SIGKILL gets past it.
- **START / STOP** and **RESTART**, in the FAN CONTROL DAEMON box, drive the systemd service. The daemon's stop path
  hands the fans to the BMC, so if you are in Manual the TUI puts the manual speed
  straight back. START switches to Daemon control first, otherwise the daemon would
  start and immediately stand down. There are no key bindings for these, to avoid
  stopping it by accident.
- **Set hold** saves the slider's value as the daemon's hold speed: it rewrites just the
  `FAN_SPEED=` line in `conf/ipmi-fancontrol.conf` (atomically, keeping the file's mode
  and every other setting) and then reminds you to restart the service, which you do
  with RESTART. It never restarts the daemon itself. A hold speed edited by hand is
  picked up too, and shown as unapplied until the service has restarted. Because moving
  the slider puts the fans on that speed, you can hear a candidate hold speed before
  saving it. Going back to Daemon control puts the slider back on the saved hold speed.
- The BMC's fan mode cannot be read back, so while in manual the TUI re-sends the
  speed every 15 s.
- Keys: `d` daemon control, `b` BMC control, `m` manual, `+`/`-` change the duty by 5,
  `q` quits, `c` compacts. The slider takes `←`/`→` (1), `Shift+←`/`Shift+→` (5) or the mouse.
- `c` (or a click on either box) collapses the temperatures and fans to one colour-coded
  line each: green, yellow or red temperatures against the threshold, cyan RPMs, and any
  unhealthy fan or lost redundancy in red. It saves about 8 rows on a six-fan machine.
- The layout fits 80 columns. It is taller than a 24-row terminal, so the screen scrolls:
  `↑`/`↓` by a line, `PgUp`/`PgDn` by a page, `Home`/`End` to the top or bottom, or the
  mouse wheel; `Tab` also scrolls whatever it focuses into view. These keys never touch
  the slider, so scrolling cannot change the fan speed.

## Other tooling

| Path | What it does |
| --- | --- |
| `ipmi-fancontrol-daemon` | Temperature-aware fan control for Dell PowerEdge/iDRAC: holds a fixed low duty while cool, hands back to the BMC curve under load. Run by `ipmi-fancontrol.service`. |
| `ipmi-fancontrol-tui` | Terminal dashboard: live temps and RPMs, daemon/BMC/manual modes, duty slider, and start/stop/restart of the daemon service. See [Fan control](#fan-control). |
| `ipmi-fancontrol-manual` | Ad-hoc override pinning the fans to a fixed speed. Does not ramp under load. |
| `ipmi-fancontrol-auto` | Hands fan control back to the BMC's automatic curve. Also the `ExecStopPost` backstop. |
| `setup-nut-synology.sh` | Sets up NUT for a USB UPS and serves it to a Synology. See [`nut/README.md`](nut/README.md). |
| `nut/` | Reference `/etc/nut` configuration for hand-configuring a host. |
| `pa-vm_api_stop.sh` | Graceful PA-VM firewall shutdown over the PAN-OS XML API, as `ExecStop`. |
| `prox-maintenance-mode.sh` | Disables `onboot` autostart on every VM and container before host maintenance and restores it afterwards, saving the previous state to `/var/tmp`. `--enable`/`--disable`/`--status`, plus `--dry-run`. |
| `start-passthrough-vm.sh` | Starts a VM with PCIe passthrough at boot only once each device has been found by ID or by its MAC-pinned interface rather than by PCI address, repointing its resource mapping if a new card has renumbered the buses. Run by `passthrough-vm-start.service`; configured in `conf/passthrough-vm.conf`. `--check` to verify without starting. |
| `start-dependents.sh` | Starts the guests that need that VM, in order, once a port on it answers. Run by `dependents-start.service`; configured in `conf/dependents.conf`. Both scripts stand down while `prox-maintenance-mode.sh` has autostart disabled. |
| `download-virtio-win-progress.py` | Fetches the virtio-win driver ISO. |
| `systemd-system/` | Unit files, installed to `/etc/systemd/system`. |
| `conf/` | Configuration, kept beside the scripts rather than in `/etc`. Committed as `.example`; the real files are not in git. |
| `unused/` | Retired, kept for reference. Each carries a header explaining why it is no longer used. |

## Deploying

`/opt/ergosteur` is a checkout of this repository, so deploying is a pull:

```sh
ssh root@pet630 'git -C /opt/ergosteur pull'
```

The remote is the HTTPS URL, not SSH. The repository is public, so the host
needs no credentials and no deploy key; the trade-off is that it cannot push,
which is what you want of a deploy target. Commit here, pull there.

Local configuration under `conf/` is gitignored and survives a pull untouched.

Two things to keep in mind:

Unit files under `systemd-system/` are in the checkout, but systemd reads them
from `/etc/systemd/system`. Changing one means copying it across and running
`systemctl daemon-reload`; a pull alone changes nothing.

The executable bit is carried by git, so a script committed without it will be
non-executable on the host and any unit with it as `ExecStart` will fail to
start. `git update-index --chmod=+x <file>` fixes a file already committed
without it.

## Conventions

- Scripts print their own usage from the header comment block; run with
  `--help`.
- Configuration lives in `conf/` beside the script, never in `/etc`.
- Retired scripts move to `unused/` with a header explaining why, rather than
  being deleted.
- Shell scripts are expected to pass `shellcheck`. Not all of the older ones do
  yet; `build-cloudinit-template.sh`, `update-image-pins.sh` and
  `setup-nut-synology.sh` are clean.
