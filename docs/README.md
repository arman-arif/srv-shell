# srv documentation

This is the full guide to `srv`. It covers every command, every option and
every setting a site can have. If you're new, read the guides in order; later,
use the reference and recipes to look things up.

All commands need root, so run them with `sudo srv …`. Running `sudo srv` with
no command opens the interactive menu, which can do almost everything the
commands below do.

## Guides

| # | Guide | What it covers |
|---|---|---|
| 1 | [Getting started](01-getting-started.md) | Installing srv, the setup wizard, the menu, adding features later, global options |
| 2 | [Sites](02-sites.md) | Every site type, all `site add` options, managing, changing and removing sites, custom Nginx config, redirects, maintenance mode |
| 3 | [Apps and processes](03-apps.md) | Node.js and Python apps, systemd, PM2 and Supervisor, environment variables, Laravel queues, Horizon and Reverb, Redis |
| 4 | [Git deploys](04-deploys.md) | Releases, rollbacks, deploy keys, webhooks for GitHub, GitLab and Bitbucket, every `DEPLOY_*` setting |
| 5 | [SSL and databases](05-ssl-databases.md) | Let's Encrypt certificates, MySQL/MariaDB and PostgreSQL databases and users |
| 6 | [Backups and restore](06-backups.md) | Daily backups, restoring sites and databases, remote copies, moving to a new server |
| 7 | [Runtimes](07-runtimes.md) | Several PHP, Node.js and Python versions side by side, PHP extensions |
| 8 | [Administration](08-admin.md) | Adminer/phpMyAdmin, health checks, alerts, the dashboard, cron jobs, status, updating srv |

## Look-ups

- [Recipes](09-recipes.md): complete walkthroughs for Laravel, WordPress,
  Next.js, a socket.io server on a subdomain, Django, FastAPI, a Docker
  container, a static site and more.
- [Command reference](10-reference.md): every command and option on one page,
  every site setting and server setting, and where srv keeps its files.
- [Troubleshooting](11-troubleshooting.md): what to do when a site doesn't load,
  a certificate fails, an app won't start or a deploy fails.

## Conventions used in these docs

- `example.com` stands for your domain. Replace it with yours.
- `<domain>` is a required value; `[value]` is optional; `a|b` means "one of".
- A site's *home* is `/var/www/<domain>`; its Linux user is the domain with dots
  turned into underscores (`example.com` → `example_com`).
- Commands that ask questions accept `--yes` (or `-y`) to take the defaults
  instead, which is what you want in scripts and CI.
