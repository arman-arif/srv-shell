# 5. SSL and databases

## HTTPS with Let's Encrypt

### Before you start

1. Point the domain's DNS **A record** (and **AAAA** for IPv6) at the server,
   for the main domain and every alias (`www`).
2. Make sure port 80 is reachable from the internet. The UFW firewall set up by
   srv allows it; check your provider's cloud firewall too.
3. Install certbot if you skipped it: `sudo srv install certbot`.

### Issuing a certificate

```bash
sudo srv site add example.com --type php --ssl     # when creating the site
sudo srv ssl add example.com                       # for an existing site
```

srv checks each name first. Names that don't resolve to this server are left
out (you're asked whether to include them anyway), so one missing `www` record
doesn't stop the main domain from getting a certificate. `--force` includes every
name without asking.

After the certificate is issued, srv regenerates the site's Nginx config:
HTTP redirects to HTTPS, HTTP/2 and modern TLS settings are on, and HSTS is not
forced (so you can still go back).

Certificates use the webroot method, so Nginx keeps running while they are
issued and renewed. Renewal is automatic (certbot's timer), and Nginx reloads
after each renewal.

```bash
sudo srv ssl list          # all certificates and their expiry dates
sudo srv ssl renew-test    # dry run of the renewal, to check it will work
sudo srv ssl add example.com   # run again after adding an alias: expands the certificate
```

The e-mail address for expiry notices is the admin e-mail asked during the
certbot setup (`ADMIN_EMAIL`).

### Sites behind Cloudflare or another proxy

If the domain is proxied (orange cloud), the name resolves to the proxy, not to
your server, and srv warns about it. Issuing still works as long as the proxy
passes `/.well-known/acme-challenge/` through on port 80, which Cloudflare does.
Use the SSL mode "Full (strict)" once the certificate is in place.

## Databases

srv can run **MariaDB or MySQL** (`srv install database`, or `srv install mysql`
/ `srv install mariadb`) and **PostgreSQL** (`srv install postgres 17`), on
the same server if you like. Both listen on localhost only.

When both are installed, add `--mysql` or `--pg` to choose which one a
command uses; otherwise you're asked (or the default engine is used with
`--yes`).

### Databases for sites

The easiest way is to let `site add` create one:

```bash
sudo srv site add shop.example.com --type laravel --pg      # PostgreSQL
sudo srv site add blog.example.com --type php --db --mysql  # MariaDB/MySQL
```

The database and user are named after the site (`shop_example_com`), the
password is random, and the details go where the app reads them: Laravel's
`.env`, or `app.env` (`DATABASE_URL`, `DB_*`) for Node.js and Python. For plain
PHP (WordPress), copy them from:

```bash
sudo srv site info blog.example.com --secrets
```

### Managing databases by hand

```bash
sudo srv db list                         # every database: engine, size, which site uses it
sudo srv db create analytics             # asks for the user name; prints the password
sudo srv db create analytics reporting --pg
sudo srv db password reporting           # new random password for a user (printed once)
sudo srv db drop analytics               # asks first
```

`db create` prints the host, database, user and password. Store the password
somewhere safe; it isn't shown again (reset it with `db password`).

To give an *existing* site a database, create one with `srv db create` and put
the details in its `.env` or `app.env` yourself.

### Connecting from your computer

The database servers don't listen on the internet. Use an SSH tunnel instead:

```bash
# MariaDB/MySQL on your local port 3307
ssh -N -L 3307:127.0.0.1:3306 you@server
# PostgreSQL on your local port 5433
ssh -N -L 5433:127.0.0.1:5432 you@server
```

Then connect your client (TablePlus, DBeaver, DataGrip…) to `127.0.0.1:3307` or
`127.0.0.1:5433` with the site's database user. Or use the web tools
(Adminer, phpMyAdmin, or pgweb for PostgreSQL), see [Administration](08-admin.md#database-tools).

### Root access on the server

```bash
sudo mysql                       # MariaDB/MySQL as root (socket authentication)
sudo -u postgres psql            # PostgreSQL as the postgres superuser
```

Next: [Backups and restore](06-backups.md)
