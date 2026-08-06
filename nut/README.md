# NUT configuration

Reference copies of `/etc/nut` for a host that owns a USB UPS and serves it to
other machines — in particular to a Synology, whose DSM client connects with
"UPS Type: Synology UPS Server".

`setup-nut-synology.sh` in the repo root generates all of these automatically by
detecting the UPS with `nut-scanner`. **Prefer running that.** These files are
here to document the target state and to hand-configure a host where you would
rather not run the script.

Install by copying each file to `/etc/nut/` without the `.example` suffix, then:

    chown root:nut /etc/nut/*.conf /etc/nut/upsd.users
    chmod 0640     /etc/nut/*.conf /etc/nut/upsd.users
    systemctl enable --now nut-server nut-monitor
    systemctl restart nut-driver@ups.service

## What DSM requires

DSM's client cannot be configured, so three things are fixed:

- the UPS must be named exactly `ups` — the `[ups]` section name in `ups.conf`
- it logs in as `monuser` with the password `secret`, both hardcoded
- `upsd` must listen on an address the Synology can reach

`monuser` / `secret` are therefore published constants, not credentials. The
`upsmon secondary` role only permits reading status and receiving shutdown
notifications; it cannot command the UPS.

## What you must change

The `[admin]` password is a real secret and appears in two files that must
agree: `upsd.users` and the `MONITOR` line of `upsmon.conf`. Both ship here as
`CHANGEME`. Generate one with:

    openssl rand -base64 18 | tr -d '/+=' | cut -c1-20

`ups.conf` is pinned to a specific unit by `serial` and `product`. Re-run
`setup-nut-synology.sh` after swapping hardware, or drop those two lines to match
any UPS of the same model.
