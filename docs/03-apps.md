# 3. Apps and processes

Node.js and Python sites run a long-lived server process: the *app*. Laravel
sites can have *workers* (queues, Horizon, Reverb), and any site can have extra
*services* (a socket server, a worker, a bot) running from its code. This guide
covers all three.

## How an app runs

```
browser ──HTTPS──▶ Nginx ──http://127.0.0.1:$PORT──▶ your app (as user example_com)
```

- Each app listens on its own local port (allocated from 3001 upwards, shown by
  `srv site info`). It is never exposed directly; only Nginx is.
- srv generates a launcher, `/opt/srv/run/<domain>.sh`, which loads the
  environment, changes into the app folder and starts your start command. The
  process manager runs this launcher as the site user, and restarts it when it
  crashes or the server reboots.
- The app gets these environment variables:

| Variable | Value |
|---|---|
| `PORT` | the app's port. **Your server must listen on it** |
| `HOST` | `127.0.0.1` |
| `NODE_ENV` | `production` (Node.js) |
| `PYTHONUNBUFFERED` | `1` (Python, so logs appear immediately) |
| `DATABASE_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | when the site has a database |
| `REDIS_URL` | when the site uses Redis |
| anything in `app.env` | your own variables |

### Your own environment variables

Put them in `/var/www/<domain>/app.env`, one `KEY=value` per line (shell
syntax, so quote values containing spaces):

```bash
sudo nano /var/www/app.example.com/app.env
# API_KEY=abc123
# CORS_ORIGIN="https://example.com"
sudo srv app restart app.example.com
```

The file belongs to the site user and is readable only by it. srv manages the
`DATABASE_URL`, `DB_*` and `REDIS_URL` lines; everything else you add is kept.

## Building and running apps without git

Upload the code into `/var/www/<domain>/app/`, then:

```bash
sudo srv app build app.example.com
```

`app build` does the following:

1. Fixes the file permissions.
2. Installs dependencies:
   - **Node.js:** `pnpm install --frozen-lockfile` if there's a
     `pnpm-lock.yaml`, `yarn install` for `yarn.lock`, `npm ci` for
     `package-lock.json`, otherwise `npm install`. Override this with
     `srv site set <domain> INSTALL_CMD "<cmd>"`.
   - **Python:** creates or updates the virtualenv in `/var/www/<domain>/venv`
     and installs `requirements.txt` or `pyproject.toml`.
3. Runs the build command (`BUILD_CMD`), and `collectstatic` for Django.
4. Starts the app, or restarts it if it was running.

Sites that deploy from git use `srv deploy <domain>` instead (see
[Git deploys](04-deploys.md)).

## Controlling apps

```bash
sudo srv app list                      # every app and Laravel worker group, with state
sudo srv app status app.example.com
sudo srv app start   app.example.com
sudo srv app stop    app.example.com
sudo srv app restart app.example.com
sudo srv app logs    app.example.com   # follows the app's output (Ctrl+C to stop)
```

For Laravel sites, `start`, `stop`, `restart` and `status` act on its workers,
and `app logs` shows the Horizon, queue or Reverb log.

### Running commands as the app

```bash
sudo srv app exec app.example.com 'npm run seed'
sudo srv app exec cms.example.com 'python manage.py migrate'
sudo srv app exec cms.example.com 'python manage.py createsuperuser'
sudo srv app exec shop.example.com 'php artisan tinker'
```

The command runs as the site user, in the app folder (the live release for git
sites), with `app.env` loaded and the right Node.js version or virtualenv first
on the `PATH`. Always use this instead of running commands as root, so new
files get the right owner.

## Process managers

Each app runs under one of three process managers. They behave the same from
srv's point of view; pick the one you like using for inspection.

| Manager | Runs as | Inspect it directly with |
|---|---|---|
| `systemd` (default) | unit `srv-<user>.service` | `systemctl status srv-example_com`, `journalctl -u srv-example_com -f` |
| `pm2` | a PM2 daemon per site user, started at boot by `pm2-<user>.service` | `sudo -u example_com pm2 status`, `pm2 logs`, `pm2 monit` |
| `supervisor` | program `srv-<user>` | `supervisorctl status srv-example_com:*` |

Choose it when creating the site (`--pm pm2`) or switch at any time:

```bash
sudo srv app manager app.example.com pm2
sudo srv app manager app.example.com          # ask
```

Switching stops the app under the old manager and starts it under the new one.
PM2 and Supervisor are installed on first use if they're missing.

> Use srv's commands to start and stop apps rather than `pm2 start`/`pm2 delete`
> directly. If you change something with PM2 by hand, `srv site rebuild <domain>`
> brings it back in line.

## App settings worth knowing

| Setting | What it does |
|---|---|
| `START_CMD` | How the app starts (Node.js), e.g. `node server.js`, `npm start`, `node dist/main` |
| `BUILD_CMD` | Build step after installing dependencies; empty for none |
| `INSTALL_CMD` | Overrides the detected dependency install command |
| `NODE` | Node.js major version for this app |
| `PY_APP`, `PY_SERVER`, `WORKERS` | Python module (`main:app`), `gunicorn`/`uvicorn`, worker count |
| `PY_VERSION` | Python version for the virtualenv (`system` for the OS Python) |
| `PORT` | The local port (must be free and not used by another site) |
| `TIMEOUT` | Proxy read timeout in seconds (default 60; at least 3600 when `WEBSOCKET=yes`); raise it for long requests |
| `WEBSOCKET` | `yes` passes WebSocket upgrades through Nginx |
| `MAX_BODY` | Request size limit, e.g. `100m` |

```bash
sudo srv site set app.example.com START_CMD "node dist/server.js"
sudo srv site set app.example.com WEBSOCKET yes
```

The change regenerates the launcher, the process config and Nginx, and restarts
the app.

## Laravel workers, Horizon and Reverb

Laravel's long-running processes run under Supervisor, as the site user, in the
group `srv-<user>-laravel`.

```bash
sudo srv site workers shop.example.com                    # show and ask
sudo srv site workers shop.example.com --queue 3          # 3 × queue:work
sudo srv site workers shop.example.com --horizon          # Horizon instead of queue:work
sudo srv site workers shop.example.com --reverb           # add Reverb (WebSockets)
sudo srv site workers shop.example.com --queue 0 --no-horizon --no-reverb   # none
```

| Process | Command | Notes |
|---|---|---|
| queue | `php artisan queue:work --sleep=3 --tries=3 --max-time=3600` | 0–32 processes. Each restarts at least hourly, so memory leaks don't build up |
| horizon | `php artisan horizon` | Needs Redis and the `laravel/horizon` package. Replaces the plain queue workers |
| reverb | `php artisan reverb:start` on its own local port (127.0.0.1) | Nginx forwards `/app/*` and `/apps/*` to it, so clients connect to `wss://<domain>` |

The **scheduler** is always on for Laravel sites: a cron entry runs
`php artisan schedule:run` every minute as the site user.

After enabling Reverb, update `.env` (`srv site apply-env <domain>`) so
`REVERB_HOST`, `REVERB_PORT` and `REVERB_SCHEME` point at the public domain, then
rebuild your front-end assets.

Deploys restart the workers automatically after switching to the new release. Logs: `srv site logs <domain> queue|horizon|reverb`.

## Redis for apps

```bash
sudo srv site redis app.example.com on
sudo srv app restart app.example.com
```

The app then finds `REDIS_URL` (with password and its own database number) in its
environment. See [Sites → Redis per site](02-sites.md#redis-per-site).

## Services: extra processes inside a site

A site's main app is one process. **Services** are any number of extra
long-running processes that live inside a site's code: a socket.io server in a
`socket/` folder of a Laravel or PHP site, a queue consumer, a Telegram bot, a
small API next to a static site. They work for every site type except `proxy`.

```bash
# A socket.io server in /var/www/example.com/app/socket, at https://example.com/socket.io/
sudo srv service add example.com socket --start "node server.js" --path /socket.io/

# The same folder on its own domain, under PM2
sudo srv service add example.com socket --start "node server.js" \
     --domain socket.example.com --pm pm2 --ssl

# A background worker with no web address
sudo srv service add example.com mailer --dir workers --start "python mailer.py" --internal
```

### What srv does for a service

- **Runs it from its folder**: `--dir` inside the site's code (by default the
  service's name), so `socket` runs from `app/socket`, or `current/socket` for
  git sites. Nothing is copied.
- **Runs it as the site's user**, under systemd (default), PM2 or Supervisor,
  restarting it if it crashes and at boot.
- **Installs its dependencies** (`srv service build`): Node.js uses the
  detected package manager; Python gets its own virtualenv in `<folder>/.venv`
  and installs `requirements.txt` or `pyproject.toml`.
- **Gives it a port** in `$PORT` (and `HOST=127.0.0.1`) when it's reachable
  from the web. **The service must listen on `$PORT`.**
- **Loads the environment**: the site's `app.env`, then the service's own
  `/var/www/<domain>/svc-<name>.env`. Laravel and other apps can of course also
  read their own `.env` from the site folder.
- **Puts it behind Nginx** (see below), with WebSocket support on by default.
- **Keeps it in step with deploys**: each deploy installs the service's
  dependencies inside the new release, before the switch, and restarts the
  service after the switch. A rollback restarts it on the old release, so the
  site and its services always run the same version of your code.
- **Watches it**: `srv check` (and alerts) report a service that isn't running
  or not listening on its port, and `srv status`, backups and restores include
  services. Removing the site removes its services.

### How a service is reached

| Option | Address | Notes |
|---|---|---|
| `--path /socket.io/` | `https://example.com/socket.io/` | Same domain as the site, so no CORS and no extra certificate. The full path is passed on (socket.io expects that). Add `--strip` to remove the prefix instead (`/api/users` → `/users`) |
| `--domain socket.example.com` | `https://socket.example.com/` | Its own server block. Point DNS at the server first; `--ssl` (or later `srv service ssl <domain> <name>`) gets the certificate |
| `--internal` | none | Workers, bots, queue consumers. No port is assigned unless you pass `--port` |

Without any of them, srv asks (or uses `--internal` with `--yes`).

### All options for `service add`

| Option | Meaning |
|---|---|
| `--dir <folder>` | Folder inside the site's code (default: the service's name; blank = the app folder itself) |
| `--start "<cmd>"` | Start command, run in that folder. Default for Node.js with a `start` script: `npm start` |
| `--runtime node\|python\|command` | Detected from `package.json` / `requirements.txt` / `pyproject.toml`; `command` runs anything (a binary, `php artisan …`) |
| `--node 22` / `--python 3.12` | Version for this service (default: the server's default Node.js / the system Python) |
| `--install "<cmd>"` / `--build "<cmd>"` | Override the dependency install, add a build step |
| `--pm systemd\|pm2\|supervisor` | Process manager (default systemd) |
| `--port <n>` | Fixed port instead of the next free one |
| `--websocket` / `--no-websocket` | WebSocket pass-through (default on; idle connections stay open for an hour) |
| `--timeout <s>` | Proxy timeout (default 60, at least 3600 with WebSockets) |
| `--no-build` / `--no-start` | Only register it |

### Managing services

```bash
sudo srv service list                          # all sites' services
sudo srv service list example.com
sudo srv service info example.com socket       # folder, runtime, port, address, log, env files
sudo srv service restart example.com socket    # also: start, stop, status
sudo srv service logs example.com socket       # follow the output (Ctrl+C to stop)
sudo srv service build example.com socket      # reinstall dependencies, rebuild, restart
sudo srv service exec example.com socket 'npm ls'
sudo srv service set example.com socket START_CMD "node dist/server.js"
sudo srv service manager example.com socket pm2
sudo srv service remove example.com socket     # the code and its log stay
```

Keys for `service set`: `DIR`, `START_CMD`, `INSTALL_CMD`, `BUILD_CMD`,
`NODE`, `PY_VERSION`, `PORT`, `ROUTE` (the path), `STRIP`, `WEBSOCKET`,
`TIMEOUT`, `MAX_BODY`. To change how a service is reached (path, domain,
internal), remove it and add it again.

For sites **without** git deploys, run `srv service build` after uploading new
code for the service. Git sites do it automatically on every deploy.

Each service shows up in its process manager as:

| Manager | Name |
|---|---|
| systemd | `srv-<user>-svc-<name>.service` |
| PM2 | `<domain>--<name>` in the site user's PM2 (`sudo -u <user> pm2 status`) |
| Supervisor | `srv-<user>-svc-<name>` |

See the [socket.io recipe](09-recipes.md#socketio-server-for-a-site) for a
complete example.

Next: [Git deploys](04-deploys.md)
