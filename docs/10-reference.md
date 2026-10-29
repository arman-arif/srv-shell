# 10. Command reference

Everything on one page. `srv help` prints a shorter version on the server.

Global options, usable with any command: `-y`/`--yes` (accept defaults and
confirmations), `--plain` (plain text prompts). `srv version` prints the version.

## Server

| Command | What it does |
|---|---|
| `srv` | Interactive menu |
| `srv setup` | Setup wizard (interactive only) |
| `srv install [feature] [version]` | Install or reconfigure a feature; no name = checklist. Features: `upgrade timezone hostname swap sudo-user ssh firewall fail2ban auto-updates nginx php composer database postgres redis node python supervisor pm2 certbot backup rclone webhook dbadmin`. Aliases: `mysql`, `mariadb`, `pg`/`pgsql`/`postgresql`, `nodejs`, `redis-server`, `ufw`, `ssl`/`letsencrypt`, `adminer`, `phpmyadmin`, `tools` |
| `srv status` | Server, services, features, sites, apps and certificates |
| `srv dashboard [--interval N] [--once]` | Live view (`srv top` too); `q` quits |
| `srv check [--notify] [--quiet]` | Health checks; exit 0 ok, 1 warnings, 2 failures |
| `srv self-install` | Install/upgrade this script as `/usr/local/bin/srv` |
| `srv self-update [URL\|file] [--force]` | Update srv (default: GitHub) |

## Sites

| Command | What it does |
|---|---|
| `srv site add [domain] [options]` | Create a site (options below) |
| `srv site list` | All sites |
| `srv site info <domain> [--secrets]` | Details; `--secrets` adds passwords |
| `srv site set <domain> <KEY> <value>` | Change a setting ([keys](#site-settings)) |
| `srv site enable\|disable <domain>` | Put online / take offline in Nginx |
| `srv site rebuild <domain>\|--all` | Regenerate Nginx, PHP-FPM, process and cron config |
| `srv site fix-perms <domain>` | Reset ownership and permissions |
| `srv site apply-env <domain>` | Write database/Redis/Reverb settings into `.env` or `app.env` |
| `srv site workers <domain> [--queue N] [--horizon\|--no-horizon] [--reverb\|--no-reverb]` | Laravel workers |
| `srv site redis <domain> [on\|off]` | Redis for the site |
| `srv site maintenance <domain> on\|off\|status [--allow "ips"]` | Maintenance mode |
| `srv site rollback <domain> [release]` | Same as `srv deploy rollback` |
| `srv site logs <domain> [kind]` | Follow a log: `error` (default), `access`, `php`, `laravel`, `app`, `queue`, `horizon`, `reverb`, `deploy` |
| `srv site remove <domain> [--purge]` | Remove; `--purge` also deletes files, user, database and certificate |

### `site add` options

| Option | Types | Meaning |
|---|---|---|
| `--type static\|spa\|php\|laravel\|node\|python\|proxy` | all | Site type |
| `--aliases "a b"` | all | Extra names (default `www.<domain>` for apex domains) |
| `--canonical` / `--no-canonical` | all | 301 aliases to the main domain |
| `--ssl` / `--no-ssl` | all | Let's Encrypt certificate now |
| `--db` / `--no-db` | php, laravel, node, python | Create a database |
| `--mysql` / `--pg` / `--engine mysql\|pgsql` | php, laravel, node, python | Database engine (implies `--db`) |
| `--redis` / `--no-redis` | php, laravel, node, python | Redis for the site |
| `--repo <url>` / `--branch <name>` | all but proxy | Git deploys |
| `--webroot <dir>` | static, spa, php, laravel | Folder Nginx serves |
| `--php <x.y>` | php, laravel | PHP version |
| `--node <major>` | node | Node.js version |
| `--preset next\|nuxt\|nest\|generic` | node | Start/build defaults |
| `--start "<cmd>"` / `--build "<cmd>"` | node | Start / build command |
| `--framework django\|flask\|fastapi\|other` | python | Framework defaults |
| `--server gunicorn\|uvicorn` | python | App server |
| `--module <mod:app>` | python | App object |
| `--workers <n>` | python | Worker processes |
| `--python <3.x>` | python | Python version |
| `--pm systemd\|pm2\|supervisor` | node, python | Process manager |
| `--port <n>` | node, python | Local port |
| `--websocket` / `--no-websocket` | node, python, proxy | WebSocket pass-through |
| `--upstream <host:port\|url>` | proxy | Where to forward |

## Apps

| Command | What it does |
|---|---|
| `srv app list` | Apps and Laravel worker groups |
| `srv app build <domain>` | Install deps, build, (re)start (non-git sites) |
| `srv app start\|stop\|restart\|status <domain>` | Control the app (Laravel: its workers) |
| `srv app logs <domain> [kind]` | Follow the app's log |
| `srv app exec <domain> '<cmd>'` | Run a command as the site user, with its environment |
| `srv app manager <domain> [systemd\|pm2\|supervisor]` | Switch process manager |

## Deploys

| Command | What it does |
|---|---|
| `srv deploy setup <domain> [--repo URL] [--branch B] [--keep N] [--no-deploy]` | Set up git deploys |
| `srv deploy <domain> [--ref REF] [--maintenance] [--no-migrate]` | Deploy |
| `srv deploy releases <domain>` | List releases (`*` = live) |
| `srv deploy rollback <domain> [release]` | Switch to an earlier release |
| `srv deploy webhook <domain> on\|off\|show\|rotate` | Auto-deploy on push |
| `srv deploy key <domain>` | Show/create the SSH deploy key |
| `srv deploy log <domain> [-f]` | Last deploy's log |

## SSL

| Command | What it does |
|---|---|
| `srv ssl add <domain> [--force]` | Issue or expand a certificate |
| `srv ssl list` | Certificates and expiry |
| `srv ssl renew-test` | Dry-run renewal |

## Databases

Add `--mysql` or `--pg` when both servers are installed.

| Command | What it does |
|---|---|
| `srv db create [name] [user]` | Create a database and user (prints the password) |
| `srv db list` | Databases, sizes, owning sites |
| `srv db drop <name>` | Drop a database (asks whether to drop its user too) |
| `srv db password <user>` | New random password |

## Backups

| Command | What it does |
|---|---|
| `srv backup run` | Everything + remote copy (the nightly job) |
| `srv backup db [name\|--all] [--mysql\|--pg]` | Database dumps |
| `srv backup site <domain>\|--all` | Site files |
| `srv backup list` | Local backups |
| `srv backup restore <domain> [--file F] [--db\|--no-db]` | Restore a site |
| `srv backup restore-db <name> [file] [--mysql\|--pg]` | Restore a database |
| `srv backup remote [setup\|test\|push\|pull [folder]\|list\|off]` | Remote copies |

## Runtimes

| Command | What it does |
|---|---|
| `srv php list\|install <v>\|default <v>\|remove <v>` | PHP versions |
| `srv php ext <name> [v\|all]` | Install an extension |
| `srv node list\|install <major\|lts\|latest>\|default <m>\|upgrade <m>\|remove <m>` | Node.js versions |
| `srv python list\|install <3.x>\|remove <3.x>` | Python versions |

## Admin

| Command | What it does |
|---|---|
| `srv tools [status]` | Database tools URL and settings |
| `srv tools install [adminer\|phpmyadmin\|both] [--host H] [--allow "ips"]` | Install |
| `srv tools password [user]` | New basic-auth password |
| `srv tools allow "ips"\|off` | IP allowlist |
| `srv tools host <domain>\|_` | Where the tools are served |
| `srv tools db-user [--mysql\|--pg]` | Create/reset the `srv_admin` database login |
| `srv tools update\|remove` | Update / remove |
| `srv notify [setup\|test\|off\|deploys on\|off]` | Alerts |
| `srv cron <domain> list\|add "<schedule>" "<cmd>"\|remove <n>\|run <n>` | Per-site cron jobs |

---

## Site settings

Stored in `/etc/srv/sites/<domain>.conf`. Change the editable ones with
`srv site set`; the others are managed by srv (shown here so `site info` makes
sense).

| Key | Types | Editable | Meaning |
|---|---|---|---|
| `TYPE` | all | — | Site type |
| `ALIASES` | all | — | Extra names |
| `CANONICAL` | all | yes | `yes` = 301 aliases to the main domain |
| `SSL` | all | — | `yes` once a certificate exists |
| `ENABLED` | all | — | via `site enable/disable` |
| `SITE_USER`, `HOME_DIR`, `APP_DIR` | all | — | Linux user, home, code folder (`current` for git sites) |
| `WEBROOT` | static, spa, php, laravel | yes | Folder Nginx serves, relative to the app |
| `PHP` | php, laravel | yes | PHP version |
| `NODE` | node | yes | Node.js major |
| `START_CMD` | node | yes | Start command |
| `BUILD_CMD` | node, python | yes | Build command |
| `INSTALL_CMD` | node | yes | Dependency install command (blank = detect) |
| `PY_FRAMEWORK` | python | — | django, flask, fastapi, other |
| `PY_APP` | python | yes | Module, e.g. `main:app` |
| `PY_SERVER` | python | yes | `gunicorn` or `uvicorn` |
| `PY_VERSION` | python | yes | Python version (`system` = OS Python) |
| `WORKERS` | python | yes | Worker processes (1–64) |
| `STATIC_DIR`, `MEDIA_DIR` | python | yes | Folders served at `/static/`, `/media/` (default `staticfiles`, `media`) |
| `PORT` | node, python | yes | Local port (1024–65535) |
| `PM` | node, python | via `app manager` | Process manager |
| `APP_ACTIVE` | node, python | — | Whether the app should be running |
| `WEBSOCKET` | node, python, proxy | yes | `yes` = pass WebSocket upgrades |
| `TIMEOUT` | node, python, proxy | yes | Proxy timeout in seconds (default 60) |
| `MAX_BODY` | node, python, proxy | yes | Request size limit, e.g. `100m` |
| `UPSTREAM` | proxy | yes | Target `host:port` or URL |
| `PRESERVE_HOST` | proxy | yes | `yes` = send the original Host header |
| `DB_ENGINE`, `DB_NAME`, `DB_USER`, `DB_PASS` | php, laravel, node, python | — | The site's database |
| `REDIS`, `REDIS_DB` | php, laravel, node, python | via `site redis` | Redis on/off and database number |
| `QUEUE_WORKERS`, `HORIZON`, `REVERB`, `REVERB_PORT` | laravel | via `site workers` | Workers |
| `MAINT_ALLOW` | all | via `site maintenance` | IPs that bypass maintenance mode |
| `DEPLOY`, `REPO` | all but proxy | via `deploy setup` | Git deploys on, repository |
| `BRANCH` | all but proxy | yes | Branch to deploy |
| `DEPLOY_KEEP` | all but proxy | yes | Releases kept (2–50, default 5) |
| `DEPLOY_SHARED_DIRS`, `DEPLOY_SHARED_FILES` | all but proxy | yes | Kept in `shared/` |
| `DEPLOY_BUILD` | all but proxy | yes | Extra build command |
| `DEPLOY_AFTER` | all but proxy | yes | Command after the switch |
| `DEPLOY_MIGRATE` | all but proxy | yes | Run migrations |
| `DEPLOY_COMPOSER`, `DEPLOY_NPM`, `DEPLOY_OPTIMIZE` | php, laravel | yes | Build steps on/off |
| `DEPLOY_HEALTH_PATH` | all but proxy | yes | Health check path (also used by `srv check`) |
| `DEPLOY_AUTO_ROLLBACK` | all but proxy | yes | Roll back on a failed health check |
| `DEPLOY_WEBHOOK`, `WEBHOOK_SECRET` | all but proxy | via `deploy webhook` | Auto-deploy |

## Server settings

Stored in `/etc/srv/srv.conf` (root only). Most are set by the wizard or the
commands; a few can be edited by hand, followed by the command in the last
column.

| Key | Meaning | Apply with |
|---|---|---|
| `ADMIN_EMAIL` | Let's Encrypt account e-mail | — (next certificate) |
| `PHP_DEFAULT` / `NODE_DEFAULT` | Default versions | `srv php default` / `srv node default` |
| `DB_ENGINE` | Default database engine | — |
| `PG_VERSION`, `PG_PORT` | PostgreSQL | — |
| `REDIS_PASSWORD` | Redis password | — |
| `APP_PORT_START` | First port for apps (3001) | — (new sites) |
| `BACKUP_KEEP_DAYS`, `BACKUP_FILES` | Local retention, include site files | `srv install backup` |
| `BACKUP_REMOTE`, `BACKUP_REMOTE_KEEP` | Remote target and retention | `srv backup remote setup` |
| `NOTIFY_TYPE`, `NOTIFY_TOKEN`, `NOTIFY_CHAT`, `NOTIFY_URL`, `NOTIFY_DEPLOYS` | Alerts | `srv notify setup` |
| `TOOLS_HOST`, `TOOLS_PATH`, `TOOLS_ALLOW`, `TOOLS_USER`, `TOOLS_PHP` | Database tools | `srv tools host <current host>` |
| `WEBHOOK_PORT` | Webhook receiver port (9000) | — |
| `UPDATE_URL` | Source for `srv self-update` | — |

## Where things live

| Path | What |
|---|---|
| `/usr/local/bin/srv` | The command (previous versions: `srv.bak-<version>`) |
| `/etc/srv/srv.conf` | Server settings |
| `/etc/srv/installed.conf` | Installed features |
| `/etc/srv/sites/<domain>.conf` | Site settings |
| `/etc/srv/releases/<domain>/` | Release metadata (commit, date, status) |
| `/etc/srv/cron/<domain>.jobs` | Cron jobs (rendered to `/etc/cron.d/srv-<user>-jobs`) |
| `/etc/srv/rclone.conf` | Remote storage credentials |
| `/var/www/<domain>/` | Site home: `app/` or `repo.git/` + `releases/` + `shared/` + `current`, `logs/`, `tmp/`, `app.env`, `venv/` |
| `/var/www/_srv/maintenance.html` | Maintenance page |
| `/etc/nginx/sites-available/<domain>.conf` | Generated Nginx config (don't edit) |
| `/etc/nginx/srv-custom/<domain>/*.conf` | Your Nginx additions |
| `/etc/nginx/snippets/srv-*.conf`, `/etc/nginx/conf.d/01-srv-maps.conf` | Shared Nginx snippets |
| `/var/log/nginx/<domain>.access.log`, `.error.log` | Nginx logs |
| `/opt/srv/run/<domain>.sh` | App launchers |
| `/opt/srv/node/<major>/` | Node.js versions |
| `/opt/srv/python/` | Extra Python versions (uv) |
| `/opt/srv/tools/`, `/opt/srv/tools-web/` | Adminer / phpMyAdmin |
| `/opt/srv/webhook.py` | Webhook receiver (`srv-webhook.service`) |
| `/var/lib/srv/` | Deploy queue, check state |
| `/var/backups/srv/` | `db/`, `pgsql/`, `files/` |
| `/var/log/srv.log` | srv's log |

### Service names

| What | Name |
|---|---|
| App under systemd | `srv-<user>.service` |
| App under PM2 | PM2 daemon of `<user>`, started by `pm2-<user>.service` |
| App under Supervisor | program `srv-<user>` |
| Laravel workers | Supervisor group `srv-<user>-laravel` |
| PHP-FPM pool | `/etc/php/<v>/fpm/pool.d/srv-<user>.conf` in `php<v>-fpm` |
| Webhook receiver | `srv-webhook.service`, queue runner `srv-deploy-queue.path` |
| Cron files | `/etc/cron.d/srv-check` (alerts), `srv-backup` (02:30), `srv-<user>` (Laravel scheduler), `srv-<user>-jobs` (your jobs) |

`<user>` is the site user, e.g. `example_com`.

Next: [Troubleshooting](11-troubleshooting.md)
