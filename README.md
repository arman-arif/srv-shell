# srv

A single-file shell script that sets up an Ubuntu or Debian server and deploys
web applications behind Nginx. You can drive it from interactive menus or
script it from the command line, CI or cron.

- **Server setup**: an interactive wizard for system updates, timezone,
  hostname, swap, a sudo user, SSH hardening, the UFW firewall, fail2ban and
  automatic security updates.
- **Stack**: Nginx, PHP-FPM with any number of versions, Composer,
  MariaDB/MySQL, PostgreSQL, Redis, Node.js with any number of versions,
  Python, Supervisor, PM2, Let's Encrypt and rclone. Anything you skip during
  setup can be installed later.
- **Sites**: static, single-page apps, PHP (WordPress etc.), Laravel, Node.js
  (Next.js, Nuxt, NestJS, Express …), Python (Django, Flask, FastAPI) and
  reverse proxies. Each site gets its own Linux user, an optional database and
  Redis, and HTTPS.
- **Apps**: run under systemd, PM2 or Supervisor, all managed with the same
  `srv app` commands. Laravel queue workers, Horizon and Reverb are included.
- **Git deploys**: each deploy builds a new release, switches to it in one
  atomic step, and rolls back automatically if the site fails its health
  check. Webhooks for GitHub, GitLab and Bitbucket, plus maintenance mode.
- **Backups**: databases and site files with rotation, one-command restore
  (also onto a new server), and remote copies to S3, R2, B2 or Google Drive.
- **Admin**: Adminer/phpMyAdmin behind a secret URL, a password and an
  optional IP allowlist; health checks with Telegram, Slack, Discord or
  webhook alerts; a live dashboard; per-site cron jobs; and self-update.

## Requirements

- Ubuntu 22.04 or newer (LTS recommended), or Debian 12 or newer
- Root access (run with `sudo`)
- For HTTPS: the domain's DNS must point at the server, and port 80 must be open

## Install

```bash
curl -fsSL -o srv.sh https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh
sudo bash srv.sh setup        # first run: the setup wizard, and installs the `srv` command
```

After the first run, use `sudo srv` for the interactive menu or `sudo srv help`
for all commands.

> Keep your SSH session open while the wizard changes SSH settings. Before you
> log out, test a **new** login (on the new port, if you changed it).

## Quick start

```bash
# A Laravel site with PostgreSQL, Redis and HTTPS, deployed from git
sudo srv site add shop.example.com --type laravel --pg --redis --ssl \
     --repo git@github.com:you/shop.git --branch main

# A Next.js app on Node 22, kept running by systemd
sudo srv site add app.example.com --type node --node 22 --preset next --ssl

# A FastAPI app
sudo srv site add api.example.com --type python --framework fastapi --module main:app

# Forward a domain to a container or another server
sudo srv site add grafana.example.com --type proxy --upstream 127.0.0.1:3000 --websocket

sudo srv status               # services, sites, apps, certificates
sudo srv dashboard            # live view (press q to quit)
```

Each `site add` asks about anything you didn't pass as a flag; add `--yes` to
accept the defaults. For apps without a git repository, upload the code into
`/var/www/<domain>/app` and run `srv app build <domain>`.

## Git deploys

```bash
sudo srv deploy setup example.com --repo git@github.com:you/app.git --branch main
sudo srv deploy example.com                 # deploy the branch
sudo srv deploy example.com --ref v1.4.2    # or a specific tag or commit
sudo srv deploy releases example.com        # history (* = live)
sudo srv deploy rollback example.com        # switch back to the previous release
sudo srv deploy webhook example.com on      # auto-deploy on push; prints the URL and secret
```

For SSH repository URLs, srv creates a deploy key (`srv deploy key <domain>`).
Add it to the repository as a read-only deploy key.

**How a deploy runs:**

1. Fetch the repository and export the commit into a new release folder.
2. Link the shared files. Laravel shares `.env` and `storage/`; Django shares
   `media/`. Change this with `srv site set <domain> DEPLOY_SHARED_DIRS "…"`.
3. Build:
   - **PHP / Laravel**: `composer install`, front-end assets with npm, and
     `artisan optimize`
   - **Node.js**: install dependencies, then run the build command
   - **Python**: a new virtualenv for the release, then `collectstatic`

   Your own build command can be added with `DEPLOY_BUILD`.
4. Run migrations (Laravel, Django). Add `--maintenance` to show the
   maintenance page while they run.
5. Switch `current` to the new release in one atomic step, then reload PHP-FPM
   or restart the app and the queue workers.
6. Health check: if the site returns 5xx or doesn't answer, srv switches back
   to the previous release automatically.
7. Delete old releases (5 are kept by default).

The live site isn't touched until step 5, so a failed build or migration never
affects visitors. PHP and static sites switch with zero downtime; Node.js and
Python apps restart, which takes about a second.

## Backups

```bash
sudo srv install backup            # daily at 02:30: databases + site files
sudo srv backup remote setup       # copy them to S3 / R2 / B2 / Google Drive …
sudo srv backup run                # back up everything now
sudo srv backup restore example.com        # files + database; a safety dump is taken first
sudo srv backup restore-db shop --pg       # restore one database
```

**Moving to a new server:**

1. Install srv.
2. Create the site with the same domain and type.
3. Run `srv backup remote setup`, then `srv backup remote pull`.
4. Run `srv backup restore <domain>`.

The git settings and webhook secret are carried over, and `.env`/`app.env` are
updated to use the new server's database. The next push deploys as before.

## Alerts and health checks

```bash
sudo srv check                     # all checks; exit code 0 ok, 1 warnings, 2 failures
sudo srv notify setup              # Telegram, Slack, Discord or any webhook
```

Once alerts are set up, checks run every 5 minutes. You get a message only
when something breaks or recovers. The checks cover services, every site's
HTTP response, certificate expiry, app processes, Laravel workers, disk,
memory, load and backup age. Failed deploys and failed backups also send a
message.

## Command overview

| Area | Commands |
|---|---|
| Server | `setup`, `install [feature] [version]`, `status`, `dashboard`, `check`, `self-update` |
| Sites | `site add\|list\|info\|set\|enable\|disable\|rebuild\|fix-perms\|apply-env\|workers\|redis\|maintenance\|rollback\|logs\|remove` |
| Apps | `app list\|build\|start\|stop\|restart\|status\|logs\|exec\|manager` |
| Deploy | `deploy <domain>`, `deploy setup\|releases\|rollback\|webhook\|key\|log` |
| Databases | `db create\|list\|drop\|password` (`--mysql` / `--pg`) |
| Backups | `backup run\|db\|site\|list\|restore\|restore-db\|remote …` |
| Runtimes | `php list\|install\|default\|remove\|ext`, `node list\|install\|default\|upgrade\|remove`, `python list\|install\|remove` |
| Admin | `tools …` (Adminer/phpMyAdmin), `notify …`, `cron <domain> …`, `ssl add\|list\|renew-test` |

Run `srv help` for the full reference with all options. `-y`/`--yes` accepts
defaults and confirmations; `--plain` uses plain-text prompts instead of dialog
boxes.

## Where things live

| Path | What |
|---|---|
| `/etc/srv/` | srv's state, settings and one `sites/<domain>.conf` per site (root only) |
| `/var/www/<domain>/` | the site: `app/` or `releases/` + `shared/` + `current`, plus `logs/` and `app.env` |
| `/etc/nginx/sites-available/<domain>.conf` | generated config. Don't edit it; put your own directives in `/etc/nginx/srv-custom/<domain>/*.conf` |
| `/opt/srv/` | Node.js and Python versions, app launchers, PM2, uv, the database tools |
| `/var/backups/srv/` | `db/`, `pgsql/` and `files/` backups |
| `/var/log/srv.log` | everything srv did, including command output |

## Security notes

- Each site runs as its own Linux user. Nginx can read site files but can't
  write them, and other sites can't read them.
- Databases, Redis and apps listen on localhost only; the firewall opens SSH,
  80 and 443.
- Database passwords never appear on command lines or in logs.
- The database tools run in their own PHP pool as a separate user, restricted
  by `open_basedir`. They sit behind a secret path and a password; add an IP
  allowlist with `srv tools allow "<your IP>"`.
- The webhook receiver runs as an unprivileged user. It only verifies
  signatures and queues a deploy; it can't run commands.

## Limitations

- Ubuntu/Debian only (no RHEL family).
- Git submodules aren't included in releases.
- Rolling back a release doesn't undo database migrations.
- One PostgreSQL version and one MySQL/MariaDB server per machine.
- Node.js and Python apps restart on deploy, so there's a brief blip
  (no blue-green deploys).

## Upgrading srv

```bash
sudo srv self-update               # latest version from this repository
sudo srv site rebuild --all        # apply the new config templates
```

- **Checks first:** the update is syntax-checked before it replaces anything,
  and the previous version is kept as `/usr/local/bin/srv.bak-<version>`.
- **Older versions are refused** unless you add `--force`.
- **Another source:** pass it as an argument, e.g. `sudo srv self-update
  https://example.com/srv.sh` or `sudo srv self-update ./srv.sh`. A URL is
  remembered for later plain `srv self-update` runs.

Servers running srv 4.0.0 need the URL once, because that version has no
default: `sudo srv self-update https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh`
