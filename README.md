# pve-vm-tune

Tuning scripts for VMs on Proxmox VE. They cut write load on the host's SSDs and send VM logs to a central VictoriaLogs server.

| Directory | Guest OS | Script |
|---|---|---|
| [`ubuntu-24-26/`](ubuntu-24-26/) | Ubuntu 24.04 / 26.04 LTS | [`optimize-for-ssd.sh`](ubuntu-24-26/optimize-for-ssd.sh) |

The log receiver (VictoriaLogs behind Caddy, as a Docker Compose stack) is in [`victoriametrics/`](victoriametrics/); see [Central logging with VictoriaLogs](#central-logging-with-victorialogs).

---

## optimize-for-ssd.sh

The script is interactive (whiptail). You pick items from a menu, answer a few questions and review the plan. Nothing changes on the system until you confirm the plan.

### Quick start

On the VM:

```bash
git clone https://github.com/SamWang8891/pve-vm-tune.git
cd pve-vm-tune/ubuntu-24-26
sudo ./optimize-for-ssd.sh --status   # see what is already applied, change nothing
sudo ./optimize-for-ssd.sh            # pick items, answer, review the plan, apply
```

To update later:

```bash
cd ~/pve-vm-tune && git pull
cd ubuntu-24-26 && sudo ./optimize-for-ssd.sh
```

The script saves your answers and offers them as defaults on the next run, so a re-run is mostly pressing Enter.

### Requirements

- Ubuntu 24.04 or 26.04 LTS. For anything else, `--force` runs the script anyway.
- Root (`sudo`).
- Outbound HTTP for apt. log2ram also needs `azlux.fr` and `packages.azlux.fr`.
- whiptail (installed automatically when missing), python3 and curl. All three ship with Ubuntu Server.

### Usage

```text
sudo ./optimize-for-ssd.sh              interactive: pick items, answer questions, review plan, apply
sudo ./optimize-for-ssd.sh --status     show what is applied, change nothing
sudo ./optimize-for-ssd.sh --dry-run    same flow, but only show what would change (with diffs)
sudo ./optimize-for-ssd.sh --yes --apply rsyslog,journal,ship --config ./optimize-for-ssd.conf
                                        non-interactive (answers from the config file)
```

| Option | Meaning |
|---|---|
| `--status` | Print the state table and exit. |
| `--dry-run` | Ask everything and show the plan, but only print the commands and file diffs. Nothing is written. |
| `-y`, `--yes` | Non-interactive. Needs `--apply`. Answers come from the config file or the built-in defaults. |
| `--apply a,b,c` | Items to apply with `--yes`. |
| `--config PATH` | Read and save answers here instead of `/etc/optimize-for-ssd.conf`. |
| `--force` | Run on an OS other than Ubuntu 24.04/26.04. |

### Items

| Item | What it does | Takes effect |
|---|---|---|
| `rsyslog` | Purges rsyslog, so logs aren't written twice (journal + `/var/log/syslog`). Can also delete the old `syslog`/`kern`/`auth`/`mail` logs. The script skips this if the purge would remove other packages, unless you say otherwise. | now |
| `journal` | Chooses where the systemd journal lives: **log2ram** (`/var/log` in RAM, synced to disk every N hours and at shutdown), **volatile** (RAM only) or **disk** (size-capped). | log2ram: after reboot; others: now |
| `ship` | Sends the journal to VictoriaLogs with `systemd-journal-upload`. It retries forever and resumes from its saved cursor, so nothing is lost while the receiver is down. | now |
| `docker` | Sets Docker's default log driver to `journald` or `local` instead of `json-file`. | new containers after the Docker restart; existing ones after a recreate |
| `weblog` | nginx/apache: buffers access-log writes and skips static assets (css, js, images, fonts). | now (config is tested, then reloaded) |
| `swap` | Replaces disk swap with **zram** (compressed swap in RAM) or keeps disk swap with lower swappiness. | now |
| `fstab` | Mounts `/` with `noatime`, plus a longer `commit=` interval on ext4. | now (live remount) |
| `trim` | Enables `fstrim.timer` and runs a test TRIM on `/`. | now, if the virtual disk has Discard on |
| `tmp` | Mounts `/tmp` as tmpfs with a size cap. | next reboot (resized live if it is already tmpfs) |

Items that don't apply to the machine (no Docker, no web server) are hidden from the menu.

#### What each item changes

<details>
<summary>Files and commands per item</summary>

| Item | Files / actions |
|---|---|
| `rsyslog` | `apt-get purge rsyslog`; optionally `rm /var/log/{syslog,kern.log,auth.log,mail.log,mail.err}*` |
| `journal` | `/etc/systemd/journald.conf.d/50-optimize-for-ssd.conf`. The log2ram mode also writes `/etc/apt/sources.list.d/azlux.list`, `/usr/share/keyrings/azlux-archive-keyring.gpg`, `/etc/log2ram.conf` and `/etc/systemd/system/log2ram-daily.timer.d/50-optimize-for-ssd.conf`. Switching away from log2ram purges it. |
| `ship` | Installs `systemd-journal-remote`. Writes `/etc/systemd/journal-upload.conf.d/50-optimize-for-ssd.conf` and `/etc/systemd/system/systemd-journal-upload.service.d/50-optimize-for-ssd.conf` (`Restart=always`, no start limit). |
| `docker` | `/etc/docker/daemon.json`: `log-driver`, plus `log-opts` (`tag={{.Name}}` for journald, `10m x 3` for local). It is validated with `dockerd --validate` when available. Optionally restarts Docker and recreates compose projects. |
| `weblog` | nginx: writes `/etc/nginx/conf.d/optimize-for-ssd-logs.conf` and changes the default `access_log` line in `nginx.conf` to `buffer=64k flush=5m if=$optimize_for_ssd_loggable`. apache: writes and enables `conf-available/optimize-for-ssd-logs.conf` (`BufferedLogs On`) and adds `env=!dontlog` to `CustomLog` lines. |
| `swap` | zram: installs `zram-tools` and writes `/etc/default/zramswap`. It then turns disk swap off, comments the swap lines out of `/etc/fstab` and deletes swap files. Both modes write `/etc/sysctl.d/99-optimize-for-ssd-swap.conf`. |
| `fstab` | `/etc/fstab` root options, then `mount -o remount /`. |
| `trim` | `systemctl enable --now fstrim.timer`, then `fstrim -v /`. |
| `tmp` | Adds a `tmpfs /tmp` line to `/etc/fstab` and unmasks `tmp.mount`. |

</details>

### Status

`--status` (and the item menu) shows the real state of each item:

| State | Meaning |
|---|---|
| `done` | Applied and in effect. |
| `part` | Applied, but not fully in effect. The detail says why. |
| `todo` | Not applied. |
| `n/a` | Doesn't apply to this machine. |

Example:

```text
ITEM     STATE DESCRIPTION                                      DETAIL
rsyslog  done  Remove rsyslog (stop duplicate logging)          rsyslog not installed
journal  part  Journal storage: log2ram / RAM-only / capped disk log2ram installed, /var/log not in RAM until reboot
ship     done  Ship journal to VictoriaLogs                     https://127.0.0.1:80/insert/journald
docker   part  Docker: default log driver journald/local        still json-file, recreate: app-web-1 app-db-1
weblog   n/a   nginx/apache: buffered access log, skip static   no nginx/apache
swap     done  Swap: zram instead of disk / lower swappiness    zram 4G, swappiness=100
fstab    done  Root fs: noatime + longer ext4 commit            defaults,noatime,commit=60
trim     part  TRIM: fstrim.timer + discard check               timer on, but virtual disk has no discard (PVE: Discard, then VM stop/start)
tmp      done  /tmp in RAM (tmpfs)                              tmpfs 1G
```

In the menu, ticking a `[DONE]` or `[PART]` item applies it again.

### Safety

- **Nothing changes before you confirm the plan.** Quit, Esc or Ctrl+C before that point exits without touching anything.
- **Backups.** Every file is copied, with its full path, to `/var/backups/optimize-for-ssd/<timestamp>/` before it is first changed in a run.
- **Validation before writing.**
  - A new `/etc/fstab` must pass `findmnt --verify`.
  - nginx (`nginx -t`) and apache (`apache2ctl configtest`) changes roll back on failure.
  - A failed remount of `/` restores fstab.
- **Swap safety.**
  - Disk swap is turned off only after zram is up.
  - A swap device holding more than the free RAM is left alone.
- **One run at a time.** A lock file (`/run/optimize-for-ssd.lock`) stops two runs from overlapping.

#### Undo

Restore a file from the backup directory:

```bash
ls /var/backups/optimize-for-ssd/
sudo cp -a /var/backups/optimize-for-ssd/<timestamp>/etc/fstab /etc/fstab
```

Files the script created have no backup; delete them (see [What each item changes](#what-each-item-changes)). Package changes are not in the backup; reverse them with apt, e.g. `apt install rsyslog` or `apt purge log2ram zram-tools`.

### Config file

The script saves your answers to `/etc/optimize-for-ssd.conf` (mode 600) and reads them back as defaults. With `--yes`, this file is the only source of answers.

| Variable | Default | Values |
|---|---|---|
| `JOURNAL_MODE` | `log2ram` | `log2ram`, `volatile`, `disk` |
| `L2R_SIZE_MB` | `256` | RAM disk size for `/var/log`, in MB. The journal is capped at 40% of it. |
| `L2R_SYNC_HOURS` | `6` | `1`-`24`. How often log2ram writes `/var/log` to disk. |
| `VOLATILE_MAX` | `64M` | Journal RAM cap in `volatile` mode. |
| `DISK_MAX` | `200M` | Journal disk cap in `disk` mode. |
| `VLOGS_URL` | (empty) | VictoriaLogs journald endpoint, e.g. `https://127.0.0.1:80/insert/journald`. The interactive prompt suggests that URL; replace `127.0.0.1` with the receiver's address. |
| `VLOGS_CA` | (empty) | Certificate check for https: `all` = encrypt but don't verify (self-signed on an IP); `/path/root.crt` = verify against this CA; empty = system CAs. |
| `DOCKER_DRIVER` | `journald` | `journald`, `local` |
| `DOCKER_RESTART` | `yes` | Restart Docker after changing `daemon.json`. |
| `DOCKER_RECREATE` | `no` | Recreate all compose projects. Asked on every interactive run; never done with `--yes`. |
| `SWAP_MODE` | `zram` | `zram`, `swappiness` |
| `ZRAM_SIZE` | `50%` | A share of RAM or a size: `50%`, `2G`, `2GiB`, `1536M`. Range 64 MiB to 2x RAM. |
| `ZRAM_ALGO` | `zstd` | `zstd`, `lz4`, `lzo-rle` |
| `SWAPPINESS_ZRAM` | `100` | `0`-`200` |
| `SWAPPINESS_DISK` | `10` | `0`-`100` |
| `COMMIT_SEC` | `60` | ext4 commit interval in seconds (kernel default 5). |
| `TMP_SIZE` | `1G` | Size cap for `/tmp`. |

A config file for non-interactive runs:

```bash
JOURNAL_MODE=log2ram
L2R_SIZE_MB=256
L2R_SYNC_HOURS=6
VLOGS_URL=https://127.0.0.1:80/insert/journald
VLOGS_CA=all
DOCKER_DRIVER=journald
DOCKER_RESTART=yes
SWAP_MODE=zram
ZRAM_SIZE=50%
ZRAM_ALGO=zstd
SWAPPINESS_ZRAM=100
COMMIT_SEC=60
TMP_SIZE=1G
```

```bash
sudo ./optimize-for-ssd.sh --yes --apply rsyslog,journal,ship,swap,fstab,trim,tmp --config ./my.conf
```

With `--yes`, yes/no questions take their default answers:

- rsyslog is skipped if purging it would remove other packages.
- Shipping is skipped if the receiver can't be reached or answers 403.

---

## Proxmox host side

TRIM only reaches the SSD if the virtual disk passes it through:

- **GUI:** VM → Hardware → Hard Disk → Edit → tick **Discard** (and **SSD emulation**).
- **CLI:** `qm set <vmid> --scsi0 <storage>:<disk>,discard=on,ssd=1`

Then fully **stop and start** the VM; a reboot inside the guest isn't enough. Afterwards, the `trim` item shows `done`.

---

## Central logging with VictoriaLogs

The `ship` item points `systemd-journal-upload` at VictoriaLogs' journald endpoint. journal-upload posts to `<URL>/upload`, so the URL is the `/insert/journald` path:

```text
VM journald ──systemd-journal-upload──▶ https://<receiver>:<port>/insert/journald/upload ──▶ Caddy ──▶ VictoriaLogs
```

The examples use `127.0.0.1` and port `80`. Replace them with your receiver's address and the port you publish. The receiver speaks HTTPS on port 80, so write the port out in URLs: `https://127.0.0.1:80/...`. Without it, `https://` means port 443.

Tested with VictoriaLogs v1.53.0 behind Caddy 2 (`tls internal`, self-signed). If the VMs use `VLOGS_CA=all`, the traffic is encrypted but the certificate isn't verified.

### Receiver (Docker: Caddy in front of VictoriaLogs)

The receiver is in [`victoriametrics/`](victoriametrics/):

| File | What it is |
|---|---|
| [`docker-compose.yaml`](victoriametrics/docker-compose.yaml) | VictoriaLogs v1.53.0 (180 days or 150 GiB, whichever comes first; syslog on 5514) and Caddy as `victorialogs-proxy`. |
| [`Caddyfile`](victoriametrics/Caddyfile) | TLS (self-signed via `tls internal`) and IP allow-lists. |

Access rules:

| Path | Who | Purpose |
|---|---|---|
| `/insert/*` | `@insert_allowed` IPs (the VMs) | Write logs. |
| `/select/*` | `@read_allowed` IPs (your workstation, Grafana) | Read logs, including the vmui web UI. |
| `/health` | anyone | Health checks. |
| anything else | nobody | 403. |

Caddy speaks **HTTP/1.1 only** (see [Troubleshooting](#buffer-space-is-too-small-to-write-entry)). VictoriaLogs' own HTTP port (9428) isn't published; only Caddy reaches it, over the compose network.

**Ports:** Caddy always listens on port 80 inside its container, and speaks HTTPS there. To publish a different port, change only the left side of the proxy's `ports:` mapping (`"80:80"` → e.g. `"9443:80"`) and use that port in `VLOGS_URL` on the VMs. The Caddyfile stays the same. On Synology, DSM itself holds 80 and 443, so pick another outside port there.

Setup:

1. Copy `victoriametrics/` to the Docker host (on Synology, a Container Manager project folder) and create the data folders:

   ```bash
   mkdir victorialogs data
   ```

2. In `Caddyfile`, replace both `<IP or Subnet>` placeholders with the allowed IPs or subnets, e.g. `192.168.1.0/24`. Separate several with spaces.

3. If the VMs will verify the certificate (`VLOGS_CA=/path/to/root.crt` rather than `all`), replace `127.0.0.1` in the Caddyfile with the address the VMs connect to. The CA to hand them is `data/caddy/pki/authorities/local/root.crt`.

4. Optionally, change the outside port in `docker-compose.yaml`.

5. Start the stack:

   ```bash
   docker compose up -d
   ```

   After editing the Caddyfile, run `docker restart victorialogs-proxy`.

6. On each VM, run the script's `ship` item with `https://<host>:<outside port>/insert/journald`.

The allow-lists check the source IP *as it arrives at Caddy*, which can differ from the client's real IP:

- **Docker on Linux:** connections from other machines keep their IP. Connections to the published port from the Docker host itself arrive from the Docker gateway. On Docker Desktop, every client arrives from the gateway.
- **VPN or routed, NAT'ed link:** the source can be the router's IP.

To see which IP Caddy gets, temporarily change the Caddyfile's fallback to `respond "forbidden: {remote_host}" 403` and request a blocked path. If that shows the Docker gateway (e.g. `172.17.0.1`) for every client, port mapping hides the real IPs on that host. In that case, run the proxy with `network_mode: host` and no `ports:` mapping. This takes three changes:

- Caddy now binds the host's own port, so change each `80` in the Caddyfile (`https_port`, `servers :80` and the site's `:80`) to a free port.
- Point `reverse_proxy` at `127.0.0.1:9428`.
- Publish VictoriaLogs to the host only, with `"127.0.0.1:9428:9428"`.

### Test that shipping works

On the VM:

```bash
logger -t shiptest "hello from $(hostname)"
journalctl -u systemd-journal-upload -n 20 --no-pager
```

Then, from a machine in the read allow-list:

```bash
curl -sk https://127.0.0.1:80/select/logsql/query \
  --data-urlencode 'query=_time:5m SYSLOG_IDENTIFIER:=shiptest'
```

### Viewing logs

Open vmui at `https://127.0.0.1:80/select/vmui/`. Useful LogsQL queries:

| Query | Shows |
|---|---|
| `_time:15m` | everything from the last 15 minutes |
| `_time:1h _HOSTNAME:=web1` | one machine |
| `_time:1h _SYSTEMD_UNIT:=nginx.service error` | one unit, lines containing the word `error` |
| `_time:1h CONTAINER_NAME:=app-web-1` | one Docker container (journald driver) |
| `_time:7d \| stats by (_HOSTNAME) count()` | which machines sent logs in the last 7 days |

VictoriaLogs has no list of known hosts; it only shows what falls inside the selected time range. A machine that hasn't logged in the last hour won't appear in a `_time:1h` view. Widen the range to find it.

---

## Troubleshooting

#### `ship` shows `part | upload failing`

```bash
journalctl -u systemd-journal-upload -n 50 --no-pager
```

#### Buffer space is too small to write entry

journal-upload fails with `Buffer space is too small to write entry` and `operation aborted by callback`.

This is a systemd bug, [systemd#39166](https://github.com/systemd/systemd/issues/39166). Over HTTP/2, curl asks for data in chunks too small to hold one journal header line, and journal-upload gives up. Make the receiver's proxy speak HTTP/1.1 only (`protocols h1` in the Caddy example above), then check:

```bash
curl -skI https://127.0.0.1:80/insert/journald   # should answer HTTP/1.1, not HTTP/2
```

Batches that failed part-way may already have stored some entries, so a few lines can show up twice.

#### TLS errors mentioning `journal-upload.pem` or `TrustedCertificateFile`

The upload config came from a version of this script older than 1.4. Run the script and tick `ship` to re-apply it.

#### 403 from the receiver

The VM's IP, as the proxy sees it, isn't in the `/insert` allow-list. When you configure `ship`, the script tests the endpoint first and warns about a 403.

#### `docker` shows `part | still json-file, recreate: ...`

Running containers keep the log driver they were created with. Recreate them:

```bash
cd /path/to/compose/project && docker compose up -d --force-recreate
```

Containers not managed by Compose have to be removed and started again with their original `docker run` options.

#### zram: "Kernel ... has no zram module"

Some cloud and minimal kernels ship without zram. Install the module with `sudo apt install linux-modules-extra-$(uname -r)`, or use the `generic` kernel. Alternatively, choose `swappiness` mode.

#### Nextcloud and `/tmp` on tmpfs

Large uploads can pass through `/tmp`. If they don't fit in `TMP_SIZE`, point Nextcloud's `tempdirectory` (or PHP's `upload_tmp_dir`) at a directory on disk.

---

## FAQ

**zram or no swap at all?**
Without swap, memory that programs have allocated can't be moved out of RAM. Under pressure the kernel drops file cache instead, and the OOM killer starts sooner. zram gives the kernel somewhere to put cold pages: it compresses them in RAM (typically 2-3x with zstd) and never writes to disk.

**How big should zram be? Do I need more RAM for it?**
`ZRAM_SIZE` is the maximum amount of *uncompressed* data zram will hold. It reserves no RAM; memory is used only as pages are swapped in. `50%` of RAM is a sensible default (4G on an 8 GiB VM), and you don't need to add RAM for it.

**I changed the VM's RAM. Does zram follow?**
No. The size is converted to a fixed number of MiB when you apply it. Re-run the script and tick `swap`; it recomputes a `%` value against the new RAM.

**Do I need to re-run the script after changing the hostname?**
No. journald picks up the new hostname live, so new log entries carry it straight away; older entries keep the old one. On cloud-init VMs, set the hostname in Proxmox (or set `preserve_hostname: true`) so cloud-init doesn't reset it at boot.

**Why does log2ram need a reboot?**
log2ram mounts `/var/log` in RAM at boot. Until the reboot, `journal` shows `part`.
