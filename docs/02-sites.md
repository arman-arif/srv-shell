# 2. Sites

A *site* is one domain (plus optional aliases) served by Nginx. Every site gets:

- its own Linux user (`example.com` → `example_com`), so sites can't read each
  other's files;
- a home folder `/var/www/example.com/` with `app/` (the code), `logs/` and
  `tmp/`;
- a generated Nginx config, plus PHP-FPM, process or worker config depending on
  the type;
- optionally a database, a Redis database number and a Let's Encrypt
  certificate.

## Site types

| Type | For | How it's served |
|---|---|---|
| `static` | Plain HTML/CSS/JS | Nginx serves files; unknown paths give 404 |
| `spa` | Single-page apps (React, Vue, Svelte, Angular builds) | Nginx serves files; unknown paths fall back to `index.html` |
| `php` | Any PHP app: WordPress, plain PHP, other frameworks | Nginx + a PHP-FPM pool that runs as the site's user |
| `laravel` | Laravel | Like `php`, web root `public/`, plus `.env` wiring, scheduler, queue workers, Horizon, Reverb |
| `node` | Next.js, Nuxt, NestJS, Express, socket.io, anything with a server | The app listens on a local port; Nginx proxies to it |
| `python` | Django, Flask, FastAPI, any WSGI/ASGI app | gunicorn or uvicorn on a local port; Nginx proxies to it and serves static files |
| `proxy` | A Docker container, another server, any HTTP service | Nginx forwards everything to an upstream address |

## Adding a site

```bash
sudo srv site add example.com --type laravel
```

Anything you don't pass as an option is asked for. With `--yes`, the defaults are
used instead. A summary is shown before anything is created.

### Options for every type

| Option | Meaning |
|---|---|
| `--type <type>` | One of the types above |
| `--aliases "a.com b.com"` | Extra domains for the same site. For an apex domain like `example.com` the default is `www.example.com`; pass `--aliases ""` for none |
| `--canonical` / `--no-canonical` | Redirect the aliases to the main domain with a 301 (recommended, and the default answer), or serve the site on all of them |
| `--ssl` / `--no-ssl` | Issue a Let's Encrypt certificate right away. DNS for the domain *and every alias* must already point at the server |
| `--db` / `--no-db` | Create a database and user for the site |
| `--mysql` / `--pg` | Which database server to use when both are installed (implies `--db`). `--engine mysql\|pgsql` does the same |
| `--redis` / `--no-redis` | Give the site its own Redis database number |
| `--repo <url>` | Deploy from git right away (see [Git deploys](04-deploys.md)) |
| `--branch <name>` | Branch to deploy (default `main`) |

### PHP and Laravel

| Option | Meaning |
|---|---|
| `--php 8.3` | PHP version (must be installed; default: the server's default PHP) |
| `--webroot public` | Folder inside the app that Nginx serves. Laravel defaults to `public`; plain PHP to the app folder itself |

```bash
sudo srv site add blog.example.com --type php --php 8.3 --db --ssl          # WordPress etc.
sudo srv site add shop.example.com --type laravel --pg --redis --ssl \
     --repo git@github.com:you/shop.git
```

For Laravel, srv also asks whether to set up queue workers, Horizon or Reverb,
adds the scheduler (`schedule:run` every minute) and writes `APP_URL`, the
database, Redis and Reverb settings into `.env` (see `site apply-env` below).

### Static and SPA

| Option | Meaning |
|---|---|
| `--webroot dist` | Folder inside the app that Nginx serves (e.g. `dist`, `build`, `public`); blank = the app folder |

```bash
sudo srv site add docs.example.com --type static --ssl
sudo srv site add app.example.com  --type spa --webroot dist --ssl
```

### Node.js

| Option | Meaning |
|---|---|
| `--node 22` | Node.js major version (must be installed; default: the server's default) |
| `--preset next\|nuxt\|nest\|generic` | Sets sensible start and build commands (table below) |
| `--start "<cmd>"` | Command that starts the server (e.g. `node server.js`) |
| `--build "<cmd>"` | Build command run after installing dependencies; `--build ""` for none |
| `--pm systemd\|pm2\|supervisor` | Which process manager keeps it running (default `systemd`) |
| `--port 3001` | Local port; by default the next free port from 3001 is picked |
| `--websocket` / `--no-websocket` | Pass WebSocket upgrades through Nginx (needed for socket.io, Next.js dev tools, etc.) |

| Preset | Start command | Build command |
|---|---|---|
| `next` | `npm start` | `npm run build` |
| `nuxt` | `node .output/server/index.mjs` | `npm run build` |
| `nest` | `node dist/main` | `npm run build` |
| `generic` | asked (e.g. `npm start`) | asked |

Your app **must listen on the port in `$PORT`** (srv also sets `HOST=127.0.0.1`
and `NODE_ENV=production`). Next.js and Nuxt do this by themselves. In your own
server: `server.listen(process.env.PORT || 3000)`.

```bash
sudo srv site add app.example.com --type node --node 22 --preset next --ssl
sudo srv site add ws.example.com --type node --preset generic \
     --start "node server.js" --build "" --pm pm2 --websocket --no-db --ssl
```

### Python

| Option | Meaning |
|---|---|
| `--framework django\|flask\|fastapi\|other` | Picks defaults for the server and module |
| `--server gunicorn\|uvicorn` | WSGI (gunicorn) or ASGI (uvicorn). FastAPI defaults to uvicorn |
| `--module main:app` | The app object. Flask defaults to `app:app`, FastAPI to `main:app`; Django is found automatically (`project.wsgi:application`) |
| `--workers 3` | Number of worker processes |
| `--python 3.12` | Python version for the virtualenv (install it first with `srv python install 3.12`); default: the system Python |
| `--pm`, `--port`, `--websocket` | As for Node.js |

Dependencies come from `requirements.txt` (or `pyproject.toml`) and are
installed into a virtualenv. Django gets `collectstatic`, and Nginx serves
`/static/` and `/media/` directly. Git deploys also run `migrate`; without git,
run it yourself: `srv app exec <domain> 'python manage.py migrate'`.

```bash
sudo srv site add api.example.com --type python --framework fastapi --module main:app --ssl
sudo srv site add cms.example.com --type python --framework django --pg --ssl
```

### Proxy

| Option | Meaning |
|---|---|
| `--upstream 127.0.0.1:8080` | Where to forward requests: `host:port`, or `http(s)://host:port`. Host names are re-resolved at request time, so the site still starts if the upstream is down |
| `--websocket` / `--no-websocket` | Pass WebSocket upgrades through |

```bash
sudo srv site add grafana.example.com --type proxy --upstream 127.0.0.1:3000 --websocket --ssl
```

Proxy sites have no code, database or deploys. For upstreams on this machine or
an IP address, the visitor's `Host` header is passed through; for a host-name
upstream (usually another website) you're asked, and the default is to send the
upstream's own name. Change it with `srv site set <domain> PRESERVE_HOST yes|no`.

## Putting code on a site without git

If you don't use [git deploys](04-deploys.md), upload your code into
`/var/www/<domain>/app/` (with `scp`, `rsync`, SFTP…), then:

```bash
sudo srv site fix-perms example.com    # give the files back to the site user
sudo srv app build example.com         # Node/Python: install deps, build, (re)start
```

For PHP, Laravel, static and SPA sites, `fix-perms` is all you need; for Laravel,
also run `composer install` and migrations, for example with
`srv app exec example.com 'composer install --no-dev && php artisan migrate --force'`.

## Managing sites

```bash
sudo srv site list                       # all sites: type, status, SSL, app state
sudo srv site info example.com           # paths, settings, database, ports, URLs
sudo srv site info example.com --secrets # …including database and Redis passwords
sudo srv site disable example.com        # take the site offline in Nginx (files, app and config are kept)
sudo srv site enable example.com
sudo srv site logs example.com           # error log, followed live (Ctrl+C to stop)
sudo srv site logs example.com access    # error|access|php|laravel|app|queue|horizon|reverb|deploy
sudo srv site rebuild example.com        # regenerate all its config
sudo srv site rebuild --all              # every site (do this after `srv self-update`)
```

`site info`, `site list` and `site logs` accept the domain or any of its aliases.

### Changing settings

```bash
sudo srv site set example.com <KEY> <value>
```

The change is validated, saved, and the site's config is regenerated at once
(`DEPLOY_*` settings apply from the next deploy). Which keys can be changed
depends on the type:

| Type | Keys |
|---|---|
| static, spa | `WEBROOT` |
| php, laravel | `WEBROOT`, `PHP` |
| node | `START_CMD`, `BUILD_CMD`, `INSTALL_CMD`, `NODE`, `PORT`, `TIMEOUT`, `WEBSOCKET`, `MAX_BODY` |
| python | `PY_APP`, `PY_SERVER`, `PY_VERSION`, `WORKERS`, `BUILD_CMD`, `PORT`, `TIMEOUT`, `WEBSOCKET`, `MAX_BODY`, `STATIC_DIR`, `MEDIA_DIR` |
| proxy | `UPSTREAM`, `PRESERVE_HOST`, `TIMEOUT`, `WEBSOCKET`, `MAX_BODY` |
| all except proxy | `BRANCH` and the `DEPLOY_*` keys ([Git deploys](04-deploys.md#settings)) |
| all | `CANONICAL` |

Examples:

```bash
sudo srv site set example.com PHP 8.4                 # switch PHP version
sudo srv site set app.example.com START_CMD "node dist/server.js"
sudo srv site set app.example.com NODE 24
sudo srv site set app.example.com TIMEOUT 300         # seconds, for slow requests
sudo srv site set app.example.com MAX_BODY 200m       # upload size limit
sudo srv site set api.example.com WORKERS 5
sudo srv site set api.example.com PY_VERSION 3.12     # then: srv app build (or deploy)
sudo srv site set grafana.example.com UPSTREAM 10.0.0.5:3000
```

The full meaning of every key is in the [reference](10-reference.md#site-settings).

### Aliases and canonical redirects

With `CANONICAL=yes`, requests to an alias (such as `www.example.com`) get a 301
redirect to the main domain, keeping the path. With `no`, the site answers on
every name.

```bash
sudo srv site set example.com CANONICAL no
```

To add an alias to an existing site, also issue the certificate for it once DNS
points at the server: `srv ssl add example.com` expands the certificate to cover
every alias.

### Custom Nginx directives

Don't edit `/etc/nginx/sites-available/<domain>.conf`: srv regenerates it. Put
your own directives in files under `/etc/nginx/srv-custom/<domain>/` instead:

```bash
sudo tee /etc/nginx/srv-custom/example.com/headers.conf <<'EOF'
add_header X-Frame-Options SAMEORIGIN always;
location /old-page { return 301 /new-page; }
EOF
sudo nginx -t && sudo systemctl reload nginx
```

Every `*.conf` file there is included inside the site's `server { }` block (for
the HTTPS server when the site has a certificate).

### File permissions

After uploading files as another user, or when an app can't write to a folder:

```bash
sudo srv site fix-perms example.com
```

This gives everything back to the site user. Nginx (via the group) can read but
not write the files, and other users get no access. Folders that Laravel and
uploads need to write (`storage/`, `bootstrap/cache/`) stay writable for the
site user.

### .env and app.env

```bash
sudo srv site apply-env example.com
```

- **Laravel:** writes `APP_URL`, the database settings, the Redis settings and
  the Reverb settings into `.env`. Other lines are kept.
- **Node.js and Python:** rewrites `/var/www/<domain>/app.env` with
  `DATABASE_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` and
  `REDIS_URL`. Your own variables in that file are kept.

srv runs this automatically when it creates a site and when the database or Redis
settings change; run it by hand after restoring onto a new server or editing
`.env` by mistake.

### Redis per site

```bash
sudo srv site redis example.com on     # give the site its own Redis database number
sudo srv site redis example.com off
```

- **Node.js and Python:** the site gets its own Redis database number
  (`REDIS_DB`) so keys don't collide, and `REDIS_URL` is updated in `app.env`.
  Restart the app to pick it up: `srv app restart <domain>`.
- **PHP and Laravel:** write the Redis settings into `.env` with
  `srv site apply-env <domain>`.

Redis has a password and listens on localhost only.

### Maintenance mode

```bash
sudo srv site maintenance example.com on
sudo srv site maintenance example.com on --allow "203.0.113.7 198.51.100.0/24"
sudo srv site maintenance example.com status
sudo srv site maintenance example.com off
```

While it's on, visitors get a 503 "back soon" page with a `Retry-After` header,
while the IPs in `--allow` still see the real site (handy for checking a
release). Health checks report the site as "maintenance" instead of failing.
The page lives at `/var/www/_srv/maintenance.html`; edit it to match your brand.
Deploys can turn it on automatically while migrations run (`srv deploy <domain>
--maintenance`).

### Removing a site

```bash
sudo srv site remove example.com           # removes the config, processes and cron jobs
sudo srv site remove example.com --purge   # …and also deletes the files, user, database and certificate
```

Without `--purge`, the files in `/var/www/<domain>` (still owned by the site
user), the database and the certificate stay, so you can still back them up. srv asks for confirmation;
with `--yes` it doesn't.

Next: [Apps and processes](03-apps.md)
