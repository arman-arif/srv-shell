# 9. Recipes

Complete walkthroughs for common setups. Each assumes srv is installed with the
features it mentions (`srv install …` adds anything missing; most commands also
offer to install what they need).

- [A new server, start to finish](#a-new-server-start-to-finish)
- [Laravel with git deploys, PostgreSQL, Redis, Horizon and Reverb](#laravel-with-git-deploys-postgresql-redis-horizon-and-reverb)
- [WordPress](#wordpress)
- [Next.js](#nextjs)
- [Nuxt or NestJS](#nuxt-or-nestjs)
- [Express or any Node.js API](#express-or-any-nodejs-api)
- [A worker or bot next to a site](#a-worker-or-bot-next-to-a-site)
- [socket.io server for a site](#socketio-server-for-a-site)
- [React/Vue/Vite single-page app from git](#reactvuevite-single-page-app-from-git)
- [A static site](#a-static-site)
- [Django](#django)
- [FastAPI](#fastapi)
- [Flask](#flask)
- [A Docker container or another server behind Nginx](#a-docker-container-or-another-server-behind-nginx)
- [Staging and production on one server](#staging-and-production-on-one-server)
- [Moving a site from another host](#moving-a-site-from-another-host)
- [Deploying from GitHub Actions](#deploying-from-github-actions)

---

## A new server, start to finish

```bash
# 1. As root on a fresh Ubuntu server
curl -fsSL -o srv.sh https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh
sudo bash srv.sh setup
#    pick: upgrade, timezone, swap, sudo-user, ssh, firewall, fail2ban, auto-updates,
#          nginx, php, composer, database, redis, node, supervisor, certbot, backup

# 2. Check SSH in a NEW terminal before closing the old one
ssh -p <port> admin@<server-ip>

# 3. Alerts and off-site backups
sudo srv notify setup
sudo srv install rclone && sudo srv backup remote setup

# 4. Your first site (DNS must point at the server)
sudo srv site add example.com --type php --db --ssl
sudo srv status
```

## Laravel with git deploys, PostgreSQL, Redis, Horizon and Reverb

```bash
sudo srv install postgres 17
sudo srv install redis

sudo srv site add shop.example.com --type laravel --php 8.4 --pg --redis --ssl \
     --repo git@github.com:you/shop.git --branch main
```

1. srv shows a **deploy key**; add it to the repository (read-only) and let it
   continue. The first deploy runs: `composer install`, assets, `.env` from
   `.env.example` with the database, Redis and `APP_URL` filled in, `APP_KEY`,
   `storage:link`, migrations, `optimize`.
2. Edit anything else in the shared `.env` (mail, third-party keys):
   ```bash
   sudo nano /var/www/shop.example.com/shared/.env
   sudo srv deploy shop.example.com     # or: srv app exec shop.example.com 'php artisan optimize'
   ```
3. Queues with Horizon, and Reverb for WebSockets:
   ```bash
   sudo srv site workers shop.example.com --horizon --reverb
   sudo srv site apply-env shop.example.com      # REVERB_HOST/PORT/SCHEME for the public domain
   sudo srv deploy shop.example.com              # rebuild assets with the new Reverb settings
   ```
4. Auto-deploy on push:
   ```bash
   sudo srv deploy webhook shop.example.com on   # add the URL + secret to GitHub
   ```

Daily use: `git push` deploys; `srv deploy releases shop.example.com` shows
history; `srv deploy rollback shop.example.com` goes back;
`srv site logs shop.example.com laravel` shows `storage/logs/laravel.log`.

## WordPress

```bash
sudo srv site add blog.example.com --type php --php 8.3 --db --mysql --ssl
cd /tmp && curl -fsSLO https://wordpress.org/latest.tar.gz && tar -xzf latest.tar.gz
sudo rsync -a /tmp/wordpress/ /var/www/blog.example.com/app/
sudo srv site fix-perms blog.example.com
sudo srv site info blog.example.com --secrets      # database name, user, password
```

Open `https://blog.example.com` and run the installer with those database
details (host `127.0.0.1`). Plugins and updates work, because PHP runs as the
site user, which owns the files.

For bigger uploads, add `client_max_body_size 64m;` in
`/etc/nginx/srv-custom/blog.example.com/uploads.conf` and raise `upload_max_filesize`
(see [php.ini changes](07-runtimes.md#phpini-changes)).

## Next.js

```bash
sudo srv install node 22
sudo srv site add app.example.com --type node --node 22 --preset next --ssl \
     --repo git@github.com:you/app.git
```

Every deploy runs the install, `npm run build` and `npm start` in a new release.
Environment variables go in `/var/www/app.example.com/app.env`; variables that
must be available at build time (`NEXT_PUBLIC_*`) are read from there during the
build as well. After changing them: `sudo srv deploy app.example.com`.

Without git: upload the project to `/var/www/app.example.com/app/` and run
`sudo srv app build app.example.com`.

## Nuxt or NestJS

```bash
sudo srv site add web.example.com --type node --preset nuxt --ssl --repo git@github.com:you/web.git
sudo srv site add api.example.com --type node --preset nest --pg --ssl --repo git@github.com:you/api.git
```

NestJS reads `DATABASE_URL` (or `DB_*`) from the environment, so TypeORM/Prisma
work without extra config. Run Prisma migrations on every deploy:

```bash
sudo srv site set api.example.com DEPLOY_BUILD "npx prisma generate && npx prisma migrate deploy"
```

## Express or any Node.js API

```bash
sudo srv site add api.example.com --type node --preset generic \
     --start "node src/index.js" --build "" --ssl
```

In your code: `app.listen(process.env.PORT || 3000, '127.0.0.1')`.
TypeScript? Use `--build "npm run build" --start "node dist/index.js"`.

## socket.io server for a site

Say the site is `example.com` (any type: Laravel, PHP, Node.js …) and the
socket.io server lives in its `socket/` folder.

1. Make the server listen on srv's port:
   ```js
   const httpServer = require('http').createServer();
   const io = require('socket.io')(httpServer);
   io.on('connection', (socket) => { /* … */ });
   httpServer.listen(process.env.PORT || 6001, '127.0.0.1');
   ```
2. Add it as a service of the site, at the path socket.io uses:
   ```bash
   sudo srv service add example.com socket --start "node server.js" --path /socket.io/
   ```
   srv installs its dependencies, starts it, and Nginx sends
   `https://example.com/socket.io/` (WebSockets included) to it.
3. In the browser, connect to the same site: `io()`. It's the same origin, so no
   CORS configuration and no extra certificate are needed.

Check it with `srv service status example.com socket` and
`srv service logs example.com socket`. For git sites, every deploy updates the
socket server together with the site (and a rollback rolls it back too); without
git, run `srv service build example.com socket` after changing its code.

**On its own subdomain instead:** point DNS for `socket.example.com` at the
server, then:
```bash
sudo srv service add example.com socket --start "node server.js" \
     --domain socket.example.com --ssl
```
In that case, allow your page's origin in the server (`cors: { origin:
['https://example.com'] }`) and connect with `io('https://socket.example.com')`.

**With PM2** (to use `pm2 monit` and friends), add `--pm pm2`; the service then
appears as `example.com--socket` in `sudo -u example_com pm2 status`.

**A socket.io server with its own repository** (not inside a site) is simply a
Node.js site:
```bash
sudo srv site add socket.example.com --type node --preset generic \
     --start "node server.js" --build "" --websocket --no-db --aliases "" --ssl \
     --repo git@github.com:you/socket.git
```

## A worker or bot next to a site

A queue consumer, a Telegram bot or any long-running script that belongs to a
site runs as an internal service, with the site's environment:

```bash
sudo srv service add example.com bot --dir bot --start "node bot.js" --internal
sudo srv service add example.com consumer --dir workers --start "python consume.py" --python 3.12 --internal
echo 'BOT_TOKEN=123:abc' | sudo tee -a /var/www/example.com/svc-bot.env
sudo srv service restart example.com bot
```

Python services get their own virtualenv in `<folder>/.venv`. For Laravel queue
workers, use `srv site workers` instead (built in).

## React/Vue/Vite single-page app from git

```bash
sudo srv install node 22                       # the build uses the default Node.js
sudo srv site add app.example.com --type spa --webroot dist --ssl
sudo srv deploy setup app.example.com --repo git@github.com:you/frontend.git --no-deploy
sudo srv site set app.example.com DEPLOY_BUILD "npm ci && npm run build"
sudo srv deploy app.example.com
```

The build runs with the server's default Node.js. Nginx serves `dist/` and sends
unknown paths to `index.html`, so client-side routing works. Build-time
variables (`VITE_*`) can be set in a committed `.env.production`, or in
`DEPLOY_BUILD` (`"VITE_API=https://api.example.com npm run build"`, after `npm ci &&`).

## A static site

```bash
sudo srv site add example.com --type static --ssl
rsync -av --delete ./public/ you@server:/tmp/site/
ssh you@server 'sudo rsync -a --delete /tmp/site/ /var/www/example.com/app/ && sudo srv site fix-perms example.com'
```

Or deploy from git with `--repo` (and `--webroot` for a subfolder).

## Django

```bash
sudo srv install python && sudo srv install postgres
sudo srv site add cms.example.com --type python --framework django --pg --ssl \
     --repo git@github.com:you/cms.git
```

In `settings.py`, read the database and secrets from the environment and set
the static/media roots srv serves:

```python
import os, dj_database_url                       # pip install dj-database-url
DATABASES = {"default": dj_database_url.config()}   # uses DATABASE_URL
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
ALLOWED_HOSTS = ["cms.example.com"]
CSRF_TRUSTED_ORIGINS = ["https://cms.example.com"]
STATIC_ROOT = BASE_DIR / "staticfiles"   # Nginx serves /static/ from here
MEDIA_ROOT = BASE_DIR / "media"          # …and /media/ (shared between releases)
STATIC_URL, MEDIA_URL = "/static/", "/media/"
```

Add `DJANGO_SECRET_KEY=…` to `/var/www/cms.example.com/app.env`, then deploy.
Each deploy installs `requirements.txt`, runs `collectstatic` and `migrate`.
Admin user: `sudo srv app exec cms.example.com 'python manage.py createsuperuser'`.

Different folder names? `srv site set cms.example.com STATIC_DIR static`
(and `MEDIA_DIR`). A different module than the one detected?
`srv site set cms.example.com PY_APP config.wsgi:application`. ASGI (Channels):
`srv site set cms.example.com PY_SERVER uvicorn` and
`PY_APP config.asgi:application`, plus `WEBSOCKET yes`.

## FastAPI

```bash
sudo srv site add api.example.com --type python --framework fastapi --module app.main:app \
     --workers 4 --pg --ssl --repo git@github.com:you/api.git
```

Runs under uvicorn. Read `DATABASE_URL` from `os.environ`. Alembic migrations on
each deploy:

```bash
sudo srv site set api.example.com DEPLOY_BUILD "alembic upgrade head"
```

## Flask

```bash
sudo srv site add web.example.com --type python --framework flask --module app:app --ssl
```

Runs under gunicorn. With an app factory, use a module like
`"app:create_app()"`.

## A Docker container or another server behind Nginx

```bash
docker run -d --restart unless-stopped -p 127.0.0.1:3000:3000 grafana/grafana
sudo srv site add grafana.example.com --type proxy --upstream 127.0.0.1:3000 --websocket --ssl
```

Publish container ports on `127.0.0.1` only. (Docker's own port publishing
bypasses UFW, so `-p 3000:3000` would make it reachable from the internet.)

For an upstream on another machine: `--upstream https://10.0.0.5:8443`. Apps
that check the host name (or generate absolute URLs) need the visitor's `Host`
header, which IP upstreams get by default; for a host-name upstream, use
`srv site set grafana.example.com PRESERVE_HOST yes`.

## Staging and production on one server

```bash
sudo srv site add shop.example.com         --type laravel --pg --redis --ssl --repo git@github.com:you/shop.git --branch main
sudo srv site add staging.shop.example.com --type laravel --pg --redis --ssl --repo git@github.com:you/shop.git --branch develop --aliases ""
sudo srv deploy webhook shop.example.com on
sudo srv deploy webhook staging.shop.example.com on
```

Each site has its own user, database, Redis database and deploy key, so they
can't touch each other. Add both webhooks to the repository; each only reacts to
its own branch. Keep staging private:
`srv site maintenance staging.shop.example.com on --allow "<your IP>"`.

## Moving a site from another host

1. Create the site on the srv server with the same domain (`--db` if it has a
   database). Don't add `--ssl` yet.
2. Copy the files into `/var/www/<domain>/app/` and run
   `srv site fix-perms <domain>`.
3. Import the database:
   ```bash
   gzip dump.sql                                                 # srv expects a .sql.gz
   sudo srv backup restore-db <database> /path/to/dump.sql.gz
   ```
   Find the database name with `srv site info <domain> --secrets`, and update
   the app's config with the new credentials (`srv site apply-env` for Laravel).
4. Test before switching DNS by adding the server to your computer's `hosts`
   file: `<server-ip> example.com www.example.com`.
5. Switch DNS, then `sudo srv ssl add <domain>`.

From another srv server, use [backup and restore](06-backups.md#moving-a-site-to-a-new-server) instead.

## Deploying from GitHub Actions

Either add the webhook (simplest), or deploy over SSH at the end of your
workflow once tests pass:

```yaml
- name: Deploy
  run: |
    install -m 600 /dev/null ~/.ssh_key && echo "${{ secrets.DEPLOY_SSH_KEY }}" > ~/.ssh_key
    ssh -i ~/.ssh_key -o StrictHostKeyChecking=accept-new deploy@server.example.com \
        "sudo srv deploy shop.example.com --ref ${{ github.sha }} --yes"
```

To limit what that SSH user can do, allow only this command in sudoers
(`/etc/sudoers.d/deploy`):

```
deploy ALL=(root) NOPASSWD: /usr/local/bin/srv deploy *
```

Next: [Command reference](10-reference.md)
