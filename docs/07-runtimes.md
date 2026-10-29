# 7. Runtimes: PHP, Node.js and Python versions

srv can keep several versions of each language installed side by side. Each site
picks its own version, and a server-wide *default* is used for new sites and for
the plain `php` / `node` commands.

## PHP

PHP comes from the well-known Ondřej Surý repository (a PPA on Ubuntu, the
sury.org repository on Debian), so every current PHP version is available.
Each version has its own PHP-FPM service, and every PHP site has its own pool
running as the site user.

```bash
sudo srv php list                 # installed versions, the default, and which sites use each
sudo srv php install 8.4          # same as: srv install php 8.4
sudo srv php default 8.4          # new sites, the `php` command and Composer use 8.4
sudo srv site set example.com PHP 8.4    # move one site to 8.4
sudo srv php remove 8.2           # only when no site (and not the database tools) uses it
```

`php remove` refuses while a site still uses the version, or while it's the
default and other versions exist. Move the sites first.

### Extensions

The common extensions (mbstring, xml, curl, zip, gd, intl, bcmath, mysql, pgsql,
redis, opcache, …) are installed with every version. For others:

```bash
sudo srv php ext imagick          # for every installed PHP version
sudo srv php ext imagick 8.3      # just one
sudo srv php ext mongodb
```

The PHP-FPM service is restarted afterwards. If there's no package for an
extension, srv says so (it may be built in: check with `php8.3 -m`).

### php.ini changes

Put your own settings in a file in the version's `conf.d` folders, so upgrades
don't overwrite them:

```bash
echo 'upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 512M' | sudo tee /etc/php/8.3/fpm/conf.d/99-custom.ini
sudo systemctl restart php8.3-fpm
```

For large uploads, also raise Nginx's limit with a custom file, e.g.
`client_max_body_size 64m;` in `/etc/nginx/srv-custom/<domain>/upload.conf`
(see [Custom Nginx directives](02-sites.md#custom-nginx-directives)).

## Node.js

Node.js versions are installed from the official nodejs.org builds into
`/opt/srv/node/<major>`. They don't depend on the OS package, so any version
works on any supported OS. Each version comes with npm, and with pnpm and yarn
through corepack.

```bash
sudo srv node list                 # installed majors, exact versions, default, and users
sudo srv node install 22           # also: lts, latest
sudo srv node default 22           # `node`, `npm`, PM2 and PHP/static front-end builds use it
sudo srv site set app.example.com NODE 24   # move one app (restarts it)
sudo srv node upgrade 22           # newest 22.x release, then restart the apps on 22
sudo srv node remove 20            # only when no app uses it
```

Each app's launcher puts its own Node.js version first on the `PATH`, so
`srv app exec <domain> 'node -v'` shows the version that app uses.

When the default changes, PM2 daemons keep running on the old version until
their app restarts (`srv app restart <domain>`).

## Python

The OS Python 3 is always available. Other versions are installed with
[uv](https://docs.astral.sh/uv/) into `/opt/srv/python/`, without touching the
system Python.

```bash
sudo srv python list               # system Python, extra versions, and which sites use them
sudo srv python install 3.12
sudo srv site set api.example.com PY_VERSION 3.12
sudo srv app build api.example.com # rebuild the virtualenv (git sites: srv deploy api.example.com)
sudo srv python remove 3.11        # only when no site uses it
```

Use `PY_VERSION system` to go back to the OS Python. A new site can pick a
version straight away with `srv site add … --python 3.12`.

Next: [Administration](08-admin.md)
