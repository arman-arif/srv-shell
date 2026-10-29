# 1. Getting started

## Requirements

- A fresh server running **Ubuntu 22.04 or newer** (an LTS release is best) or
  **Debian 12 or newer**. Any provider works: DigitalOcean, Hetzner, AWS,
  Linode, a local VM.
- Root access through `sudo`.
- For HTTPS: a domain whose DNS points at the server, and ports 80 and 443 open,
  including in your provider's cloud firewall if you use one.
- At least 1 GB of RAM. Add swap during setup on small servers, especially when
  you build Node.js apps on the server.

## Install

```bash
curl -fsSL -o srv.sh https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh
sudo bash srv.sh setup
```

The first run installs srv as `/usr/local/bin/srv` and starts the setup wizard.
After that, use the `srv` command from anywhere; you can delete the downloaded
`srv.sh`.

To install only the command, without running the wizard:

```bash
sudo bash srv.sh self-install
```

Check the version with `srv version`, and list all commands with `srv help`.

## The setup wizard

```bash
sudo srv setup
```

The wizard runs in three steps:

1. **Pick features.** A checklist shows everything srv can install (see the
   table below). Common choices are ticked already; features that are installed
   are marked `[installed]`.
2. **Answer questions.** Only the selected features ask anything, for example
   the PHP version, MariaDB or MySQL, the SSH port, the swap size, the admin
   e-mail for Let's Encrypt.
3. **Install.** Everything then installs without further prompts. Progress is
   shown on screen, and the full command output goes to `/var/log/srv.log`.

You can run `srv setup` again at any time. Installed features are left unticked
so you can pick new ones.

> **SSH safety.** If you change the SSH port, turn off password logins or
> disable root login, keep your current SSH session open. Open a **new**
> terminal and check that you can still log in (on the new port) before you
> close the old one. The firewall opens the new SSH port automatically.

### Features

| Feature | What it installs or changes |
|---|---|
| `upgrade` | Upgrades all system packages |
| `timezone` | Sets the server timezone |
| `hostname` | Sets the server hostname |
| `swap` | Creates a swap file |
| `sudo-user` | Creates an admin user with sudo rights (and copies root's SSH keys) |
| `ssh` | Hardens SSH: root login, password logins, port |
| `firewall` | UFW, allowing only SSH, HTTP and HTTPS |
| `fail2ban` | Bans IPs after repeated failed logins |
| `auto-updates` | Automatic security updates (unattended-upgrades) |
| `nginx` | Nginx with srv's security, TLS and proxy snippets, plus a catch-all server that blocks the bare IP (see `srv ip`) |
| `php` | PHP-FPM in the version you choose, with common extensions. Run it again to add more versions |
| `composer` | Composer |
| `database` | MariaDB or MySQL server (`srv install mysql` / `srv install mariadb`) |
| `postgres` | PostgreSQL in the version you choose (`srv install postgres 17`) |
| `redis` | Redis with a password, listening on localhost only |
| `node` | Node.js in the version you choose, with npm, pnpm and yarn. Run it again to add more versions |
| `python` | Python 3 with venv, pip and uv for gunicorn/uvicorn apps |
| `supervisor` | Supervisor (Laravel queues, Horizon, Reverb and apps) |
| `pm2` | PM2 process manager (needs Node.js) |
| `certbot` | Certbot for free Let's Encrypt certificates, with automatic renewal |
| `backup` | Daily backups of databases and site files at 02:30, with rotation |
| `rclone` | rclone for copying backups to S3, R2, B2, Google Drive and others |
| `webhook` | The webhook receiver for auto-deploys on git push |
| `dbadmin` | Adminer, phpMyAdmin and/or pgweb behind a secret URL and a password |

## Adding features later

Anything you skipped can be added at any time:

```bash
sudo srv install                 # pick from a checklist
sudo srv install redis           # one feature
sudo srv install php 8.3         # with a version
sudo srv install node 22         # or: node lts, node latest
sudo srv install postgres 17
sudo srv install mysql           # or: mariadb
sudo srv install phpmyadmin      # or: adminer, tools
```

Some names have aliases: `nodejs`, `pgsql`/`pg`/`postgresql`, `ufw`,
`ssl`/`letsencrypt`, `redis-server`.

`srv install <feature> --yes` uses the defaults for every question, which is
handy for automating server builds:

```bash
for f in upgrade swap firewall fail2ban auto-updates nginx php composer database redis certbot backup; do
  sudo srv install "$f" --yes
done
```

Running `install` on a feature that is already installed reconfigures it (for
example, to change the swap size or the backup retention).

## The interactive menu

```bash
sudo srv
```

The menu groups everything into sections: sites, apps, deploy, SSL, databases,
backups, runtimes, tools, alerts, status and install. Each item asks for what it
needs and shows the equivalent command's result. Use the arrow keys and Enter;
Esc goes back.

## Global options

These work with any command:

| Option | Effect |
|---|---|
| `-y`, `--yes` | Accept defaults and confirmations without asking. Destructive actions (removing a site, dropping a database) also go ahead, so use it with care |
| `--plain` | Plain text prompts instead of dialog boxes (useful on terminals where dialogs render badly). The environment variable `SRV_PLAIN=1` does the same |

When srv runs without a terminal (from cron, CI or a pipe), it never asks
anything: missing required values are errors, and everything else uses its
default.

## How srv works, briefly

- **One lock.** Commands that change things take a lock (`/run/srv.lock`), so
  two srv commands never change the server at the same time. Read-only commands
  (`list`, `info`, `logs`, `status`) don't need it.
- **Generated config.** srv writes Nginx, PHP-FPM, systemd, Supervisor and cron
  configuration from each site's settings. Don't edit those files; change the
  setting with `srv site set` (or put extra Nginx directives in the custom
  folder) and srv regenerates them.
- **State.** Installed features are recorded in `/etc/srv/installed.conf`,
  server settings in `/etc/srv/srv.conf`, and each site's settings in
  `/etc/srv/sites/<domain>.conf`.
- **Log.** Everything srv does, including the output of every command it runs,
  is appended to `/var/log/srv.log`. When something fails, look there first.

Next: [Sites](02-sites.md)
