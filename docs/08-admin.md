# 8. Administration

## Status

```bash
sudo srv status
```

One screen with the OS, uptime, load, memory and disk; every service srv manages
and whether it's running; installed features and versions; each site with its
type, SSL and app state; and certificate expiry dates.

## Dashboard

```bash
sudo srv dashboard                 # refreshes every 5 seconds; press q to quit
sudo srv dashboard --interval 10
sudo srv dashboard --once          # print once and exit
```

`srv top` is the same. It shows CPU, memory, swap and disk bars, services,
every site's HTTP status and response time, apps and workers, certificates and
the results of the health checks.

## The server IP

What visitors see when they open `http://<server-ip>` (or any domain pointed at
the server that isn't a site):

```bash
sudo srv ip                          # current setting
sudo srv ip block                    # close the connection (the default)
sudo srv ip page                     # a static page from /var/www/_srv/ip
sudo srv ip page ./landing.html      # …using this file as index.html
sudo srv ip page ./landing/          # …or this whole folder (needs an index.html)
sudo srv ip redirect example.com     # 301 to https://example.com (keeps the path)
sudo srv ip site example.com         # show example.com's content on the IP
```

| Mode | `http://<ip>` | Good for |
|---|---|---|
| `block` | Connection closed (Nginx code 444) | Production servers: scanners and bots get nothing |
| `page` | Your static HTML page | A neutral "nothing here" or contact page |
| `redirect` | 301 to the site's domain | Sending stray visitors to your main site |
| `site` | The site itself, over HTTP | Testing before DNS is ready, or a server with one app |

**HTTPS on the IP is always refused**, in every mode. No certificate can be valid
for a bare IP, so without this Nginx would answer with one of your sites and its
certificate (and a browser warning). On Nginx 1.19.4 and newer the handshake is
rejected outright; older Nginx gets a throwaway self-signed certificate and then
closes the connection.

Details:

- **page:** edit the files in `/var/www/_srv/ip/` at any time, no reload
  needed. `index.html` is the start page; CSS, images and other files next to
  it are served too. `srv ip page <file|folder>` replaces the folder's contents.
- **site:** works for every site type. Apps receive the site's own domain as the
  `Host` header, so host checks (such as Django's `ALLOWED_HOSTS`) still pass.
  The site's maintenance mode applies on the IP too. Changing the site's settings
  updates the IP's config automatically.
- If the site used by `redirect` or `site` is disabled, the IP falls back to
  `block` until it's enabled again; if the site is removed, the setting goes back
  to `block`.
- The database tools keep working on the IP in every mode, when they're served
  there (`srv tools host _`). Move them to a domain with `srv tools host <domain>`
  so nothing but your chosen mode answers on the IP.

## Health checks

```bash
sudo srv check                     # all checks, one line each
sudo srv check --quiet             # only the summary
echo $?                            # 0 = all ok, 1 = warnings, 2 = failures
```

| Check | Warning | Failure |
|---|---|---|
| Disk (each filesystem) | ≥ 85 % used | ≥ 95 % used |
| Memory | < 10 % available | < 5 % available |
| Load | 5-minute load > 2 × CPU count | — |
| Services (Nginx, PHP-FPM, databases, Redis, Supervisor, the webhook receiver, fail2ban…) | — | not running |
| Each enabled site | — | 5xx or no answer from `DEPLOY_HEALTH_PATH` (default `/`) |
| Certificates | expires in < 14 days | < 3 days, or missing |
| Apps | — | not running, or its port isn't open |
| Laravel workers | not all running | — |
| Backups (when installed) | none yet, or newest older than 26 hours | — |

Disabled sites and sites in maintenance mode are reported but don't count as
failures. The exit code makes `srv check` usable from your own monitoring
(Nagios-style), CI or a load balancer script.

## Alerts

```bash
sudo srv notify setup              # choose Telegram, Slack, Discord or a webhook
sudo srv notify test               # send a test message
sudo srv notify                    # current setting
sudo srv notify deploys off        # no messages for deploys (on by default)
sudo srv notify off                # stop alerts
```

Once set up, `srv check --notify` runs every 5 minutes from cron
(`/etc/cron.d/srv-check`). You get a message **only when something changes**: a
new problem, or a recovery. A disk that stays full doesn't send a message every
5 minutes. Failed backups and deploy results (success and failure) are sent too.

| Channel | What you need |
|---|---|
| Telegram | A bot token from [@BotFather](https://t.me/BotFather). Send your bot any message first; srv then finds your chat ID by itself |
| Slack | An incoming webhook URL |
| Discord | A channel webhook URL (Channel settings → Integrations → Webhooks) |
| Webhook | Any URL. srv POSTs JSON: `{"text": "…", "host": "<hostname>"}` |

Non-interactive:

```bash
sudo srv notify setup --telegram "123456:ABC…" --chat 987654321
sudo srv notify setup --slack https://hooks.slack.com/services/…
sudo srv notify setup --discord https://discord.com/api/webhooks/…
sudo srv notify setup --webhook https://example.com/alerts
```

## Database tools

Adminer and/or phpMyAdmin, served from a secret URL, behind a password, and
optionally only for your IP addresses.

```bash
sudo srv tools install                 # asks: Adminer, phpMyAdmin or both; host; IP allowlist
sudo srv tools install phpmyadmin
sudo srv tools install adminer --host example.com --allow "203.0.113.7"
sudo srv tools                         # URL(s), user, host, allowlist
```

**Which tool for which database:** phpMyAdmin only works with MariaDB/MySQL.
For PostgreSQL, use Adminer, which handles both. You can have both installed;
`srv tools install adminer` adds Adminer without touching phpMyAdmin. Both are
then linked from the tools URL (`…/adminer/` and `…/phpmyadmin/`).

### Logging in

There are two logins:

1. **The browser password prompt** (HTTP basic auth). The user is `admin`
   unless you changed it; the password is shown when the tools are installed.
   Reset it with `srv tools password` (or `srv tools password <new user name>`).
2. **The database login** in Adminer/phpMyAdmin. Use a site's database user
   (`srv site info <domain> --secrets`), or create an admin login that can see
   every database:
   ```bash
   sudo srv tools db-user --mysql      # creates/resets user srv_admin and prints its password
   sudo srv tools db-user --pg
   ```
   In Adminer, pick **System: PostgreSQL** (or MySQL) and use `localhost` as
   the server.
   The database `root` user can't log in through the tools: on the server it
   uses socket authentication, which is the safe default.

### Changing where the tools live

```bash
sudo srv tools host _                  # on the server's IP: http://<ip>/_srv-tools-<secret>/
sudo srv tools host example.com        # on a site: https://example.com/_srv-tools-<secret>/
```

Using a site with a certificate is recommended, so the password travels over
HTTPS. If that site is removed later, the tools move back to the IP.

To change the secret part of the URL, edit `TOOLS_PATH` in `/etc/srv/srv.conf`
(keep the `_srv-tools-` prefix and use letters, digits and dashes), then run
`sudo srv tools host <current host>` to apply it.

### Restricting by IP

```bash
sudo srv tools allow "203.0.113.7 198.51.100.0/24"   # only these addresses
sudo srv tools allow off                              # any address (password still required)
```

### Updating and removing

```bash
sudo srv tools update                  # newest Adminer / phpMyAdmin
sudo srv tools remove
```

The tools run in their own PHP-FPM pool as the user `srv-tools`, restricted with
`open_basedir`, so they can't read the sites' files.

## Cron jobs for sites

```bash
sudo srv cron example.com list
sudo srv cron example.com add "*/15 * * * *" "php artisan report:send"
sudo srv cron example.com add "@daily" "node scripts/cleanup.js"
sudo srv cron example.com add "0 3 * * 1" "python manage.py clearsessions"
sudo srv cron example.com run 2        # run job #2 now, to test it
sudo srv cron example.com remove 2
```

Jobs run as the site user, in the app folder (the live release for git sites),
with `app.env` loaded and the site's Node.js/Python/PHP versions on the `PATH`.
Output is appended to `/var/www/<domain>/logs/cron.log`.

Schedules use the standard five fields (minute, hour, day of month, month, day of
week) or `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`, `@reboot`.
They're checked before saving, and the times use the server's timezone.

Laravel's scheduler doesn't need a job here: it's set up automatically for every
Laravel site.

## Updating srv

```bash
sudo srv self-update               # newest version from GitHub
sudo srv site rebuild --all        # apply improved config templates to existing sites
```

- The new script is downloaded and syntax-checked before it replaces anything.
- The previous version is kept as `/usr/local/bin/srv.bak-<version>`.
- Older versions are refused unless you add `--force` (to downgrade on purpose).
- From another source: `sudo srv self-update https://example.com/srv.sh` or
  `sudo srv self-update ./srv.sh`. A URL you pass is remembered for later
  plain `srv self-update` runs (stored as `UPDATE_URL` in `/etc/srv/srv.conf`).
- `sudo bash srv.sh self-install` also installs or upgrades the command from a
  downloaded file.

Servers on srv 4.0.0 need the URL once, because that version had no default:

```bash
sudo srv self-update https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh
```

## The log

```bash
sudo tail -f /var/log/srv.log
sudo grep -n 'TRACE\|ERROR' /var/log/srv.log | tail
```

Every srv command, every command it ran, and their output. When a command fails,
srv prints a short message; the details (and a `TRACE` line with the failing
function) are here.

Next: [Recipes](09-recipes.md)
