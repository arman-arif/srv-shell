# 11. Troubleshooting

Start with these three; they answer most questions:

```bash
sudo srv check                         # what's failing, in one list
sudo srv site info <domain>            # what srv thinks the site looks like
sudo tail -n 50 /var/log/srv.log       # what srv did, with full command output
```

## "The connection was reset" when opening the server's IP

That's intentional, and the default. Requests for a name that isn't a site
(including the bare IP) are dropped by Nginx's catch-all server with code 444, and
HTTPS connections to the IP are refused during the handshake, so scanners learn
nothing. It also proves Nginx and the firewall are working. Open the site by its
domain instead, or choose what the IP shows with `srv ip` (a page, a redirect or
a site, see [Administration](08-admin.md#the-server-ip)). The database tools are
the exception: `srv tools host _` serves them on the IP under their secret path,
in every mode.

## The domain doesn't load

1. **Is there a site for it?** `srv site list`. The domain must match exactly,
   or be one of the aliases. `www.example.com` only works if it's an alias.
2. **Does DNS point here?** `dig +short example.com` (on your computer) must
   show the server's IP. After changing DNS, allow time for it to spread.
3. **Is the port open?** Providers with a cloud firewall (DigitalOcean, AWS
   security groups, Hetzner, Oracle) need 80 and 443 allowed there as well as in
   UFW (`sudo ufw status`).
4. **Is the site enabled?** `srv site enable <domain>`.
5. **Does Nginx accept the config?** `sudo nginx -t`. If you added custom files
   in `/etc/nginx/srv-custom/<domain>/`, an error there stops the reload.
6. **From the server itself:** `curl -I -H "Host: example.com" http://127.0.0.1/`.

## 502 Bad Gateway (Node.js, Python, proxy sites)

Nginx can't reach the app.

- `srv app status <domain>`: is it running? If not, `srv app logs <domain>`
  shows why (a missing module, a syntax error, a missing environment variable).
- **Wrong port.** The app must listen on `$PORT` (see `srv site info`), on
  `127.0.0.1` or `0.0.0.0`. A hard-coded port is the most common cause.
- **Not built.** For non-git sites, run `srv app build <domain>` after uploading.
- **Proxy sites:** is the upstream running? `curl -I http://127.0.0.1:<port>`
  on the server.
- Restart and watch: `srv app restart <domain> && srv app logs <domain>`.

## A service doesn't answer

- `srv service status <domain> <name>` and `srv service logs <domain> <name>`.
- It must listen on `$PORT` (see `srv service info`). `running*` in
  `srv service list` means the process is up but nothing listens on its port.
- **Path services get the full path** (`/socket.io/…`). If your service expects
  requests at `/`, either change its routes or add the prefix stripping:
  `srv service set <domain> <name> STRIP yes`.
- After changing its code without git: `srv service build <domain> <name>`.
- On its own domain: DNS must point here, then `srv service ssl <domain> <name>`.

## Laravel workers aren't running

- `srv app status <domain>` shows e.g. `workers 0/2 running`; the reason is in
  `srv site logs <domain> queue` (or `horizon`, `reverb`). Errors from earlier
  attempts stay in the file, so look at the newest lines.
- **`Could not open input file: …/artisan`**: the Laravel project isn't
  directly in the site's code folder (`app/`, or `current/` with git). Put it
  there, so `artisan` sits at the top of that folder.
- **Workers that crashed repeatedly** (Supervisor shows `FATAL`) stay down even
  after the cause is fixed. `srv app restart <domain>` starts them again.
- Run the worker by hand to see its error directly:
  `srv app exec <domain> 'php artisan queue:work --once -vvv'`.
- Since srv 4.3.2, workers set up before the code exists wait, and start by
  themselves once it arrives (on deploy, `srv site fix-perms` or
  `srv app start`).

## 500 errors (PHP, Laravel)

- `srv site logs <domain> php` (PHP-FPM) and `srv site logs <domain> laravel`.
- Laravel: missing `APP_KEY`, wrong database settings or a stale config cache.
  `srv site apply-env <domain>`, then
  `srv app exec <domain> 'php artisan optimize:clear'`.
- Permission errors (`storage/` not writable after uploading files as another
  user): `srv site fix-perms <domain>`.

## 504 Gateway Timeout

A request took longer than the proxy timeout (60 seconds by default):
`srv site set <domain> TIMEOUT 300`. For PHP, also check `max_execution_time`.

## 413 Request Entity Too Large

Raise the upload limit: `srv site set <domain> MAX_BODY 100m` (apps and
proxies), or `client_max_body_size 100m;` in a custom Nginx file (PHP sites),
plus `upload_max_filesize`/`post_max_size` for PHP.

## WebSockets don't connect

- `srv site set <domain> WEBSOCKET yes` (apps, proxies).
- socket.io: allow your front-end's origin in the server's `cors` option, and
  connect with `https://` (Nginx terminates TLS).
- Laravel Reverb: `srv site workers <domain> --reverb`, then
  `srv site apply-env <domain>` and rebuild the assets.

## The certificate won't issue

- The name must resolve to this server: srv skips names that don't and tells
  you which. Fix DNS, then `srv ssl add <domain>` again.
- Port 80 must be reachable from outside (cloud firewall!).
- Let's Encrypt limits how many certificates you can get per week; after
  repeated failures, wait an hour.
- Details: `sudo tail -n 50 /var/log/letsencrypt/letsencrypt.log`.
- Renewal problems: `srv ssl renew-test`.

## A deploy fails

- `srv deploy log <domain>` shows the full output. The live site is unchanged
  unless the failure was in the health check, and then it was rolled back
  automatically.
- **"Permission denied (publickey)":** the deploy key isn't on the repository
  (`srv deploy key <domain>`), or it was added to a different repository.
- **Build runs out of memory** (killed, exit 137): add swap
  (`srv install swap`) or build in CI.
- **Health check fails** although the site works: the health path returns 5xx
  (for example `/` needs a login that errors). Point it at something simple:
  `srv site set <domain> DEPLOY_HEALTH_PATH /health`.
- **A webhook doesn't trigger:** check the delivery in GitHub/GitLab. The
  response tells you what happened: `403` wrong secret, `404` webhook not
  enabled for that site, `202 deploy queued`, or `202 ignored: …` for a push to
  another branch. On the server: `systemctl status srv-webhook`.
- **"Another srv process is running":** srv's lock is held by another command
  (for example a deploy or the nightly backup). Wait for it to finish.

## The database tools don't load

- Use the full URL from `srv tools`, including the trailing slash.
- The browser password is the basic-auth login (`srv tools password` resets it);
  the database login is separate (`srv tools db-user --mysql`).
- An IP allowlist blocks other addresses: `srv tools allow off`, or add your
  current IP.
- After updating srv: `srv tools host <current host>` re-applies the config.

## A command asks nothing and fails in a script

Without a terminal, srv never asks; it uses defaults and fails when a required
value is missing. Pass the values as options, and add `--yes` to confirm.

## Locked out of SSH

Use your provider's web console (DigitalOcean: "Access → Recovery console"),
then check `/etc/ssh/sshd_config.d/00-srv.conf` (srv's SSH settings) and
`sudo ufw status`. Next time, test a new
login before closing the old session.

## Reporting a bug

Include the srv version (`srv version`), the OS, the command you ran, and the
relevant part of `/var/log/srv.log` (remove passwords and tokens first). Open an
issue at <https://github.com/arman-arif/srv-shell/issues>.
