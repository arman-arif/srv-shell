# 4. Git deploys

Any site except `proxy` can deploy from a git repository. Each deploy builds a
fresh *release* next to the live one, switches to it in one atomic step, checks
that the site still works, and switches back automatically if it doesn't.

## Folder layout

Once git deploys are set up, the site's home looks like this:

```
/var/www/example.com/
├── repo.git/                  bare mirror of your repository
├── releases/
│   ├── 20261028T101500Z/      one folder per deploy (UTC time)
│   └── 20261029T083000Z/
├── shared/                    kept between releases: .env, storage/, media/ …
├── current -> releases/20261029T083000Z    what Nginx and the app serve
├── logs/
└── app.env                    (Node.js / Python)
```

Files and folders listed in `DEPLOY_SHARED_FILES` / `DEPLOY_SHARED_DIRS` live in
`shared/` and are symlinked into every release, so uploads, logs and `.env`
survive deploys.

## Setting it up

Either when creating the site:

```bash
sudo srv site add shop.example.com --type laravel --repo git@github.com:you/shop.git --branch main
```

or later, for an existing site:

```bash
sudo srv deploy setup shop.example.com --repo git@github.com:you/shop.git --branch main
sudo srv deploy setup shop.example.com              # asks for everything
```

| Option | Meaning |
|---|---|
| `--repo <url>` | `git@host:owner/repo.git`, `ssh://…`, `https://…`, or a local path |
| `--branch <name>` | Branch to deploy (default `main`) |
| `--keep <n>` | How many releases to keep (2–50, default 5) |
| `--no-deploy` | Only save the settings; don't deploy now |

If the site already has code in `app/`, the shared files and folders that exist
there (for example `storage/` and `.env` for Laravel) are copied into `shared/`
first, so nothing is lost.

### Private repositories: deploy keys

For SSH URLs, srv creates an SSH key for the site and shows its public part:

```bash
sudo srv deploy key shop.example.com
```

Add it to the repository as a **read-only deploy key**:

- **GitHub:** repository → Settings → Deploy keys → Add deploy key
- **GitLab:** repository → Settings → Repository → Deploy keys
- **Bitbucket:** repository → Repository settings → Access keys

During an interactive setup, srv waits until you've added the key and pressed
Enter, then checks that it can reach the repository. Without a terminal (or
with `--yes`), add the key afterwards and run `srv deploy <domain>`.

Each site has its own key, so one leaked key gives access to one repository
only. HTTPS URLs with a token (`https://user:token@github.com/…`) also work, but a
deploy key is safer.

## Deploying

```bash
sudo srv deploy shop.example.com                       # the configured branch
sudo srv deploy shop.example.com --ref v1.4.2          # a tag, branch or commit
sudo srv deploy shop.example.com --maintenance         # maintenance page during migrations
sudo srv deploy shop.example.com --no-migrate          # skip migrations this time
sudo srv deploy log shop.example.com                   # the last deploy's output
sudo srv deploy log shop.example.com -f                # follow a running deploy
```

### What happens during a deploy

1. **Fetch** the repository and export the commit into `releases/<id>/`
   (submodules are not included).
2. **Link shared files** from `shared/` into the release. A new Laravel site
   gets a `.env` created from `.env.example`, filled with `APP_URL`, the database
   and Redis settings, and an `APP_KEY`.
3. **Build** in the new release, as the site user:
   - **PHP/Laravel:** `composer install --no-dev --optimize-autoloader` (if
     there's a `composer.json`); front-end assets with the detected package
     manager and `npm run build` (if `package.json` has a `build` script);
     `artisan storage:link`; `artisan optimize`.
   - **Node.js:** install dependencies (pnpm, yarn or npm, from the lock file),
     then `BUILD_CMD`.
   - **Python:** a new virtualenv in the release (`.venv`), dependencies from
     `requirements.txt` or `pyproject.toml`, `collectstatic` for Django.
   - Then your own `DEPLOY_BUILD` command, if set.
4. **Migrate** (Laravel: `artisan migrate --force`; Django: `manage.py migrate`),
   if `DEPLOY_MIGRATE=yes`. With `--maintenance`, the maintenance page is shown
   from here until the health check.
5. **Switch** `current` to the new release in one atomic step, then reload
   PHP-FPM, or restart the app, and restart the Laravel workers.
6. Run your `DEPLOY_AFTER` command, if set (a failure only warns).
7. **Health check:** request `DEPLOY_HEALTH_PATH` (default `/`) through Nginx,
   retrying for about 15 seconds. Any status below 500 counts as healthy. If the
   site returns 5xx or doesn't answer, srv **switches back to the previous
   release** (`DEPLOY_AUTO_ROLLBACK=yes`).
8. **Clean up:** delete releases beyond `DEPLOY_KEEP`.

If anything fails before step 5 (a build error, a failed migration), the live
release is never touched. Failed and successful deploys can be reported to
Telegram/Slack/Discord (see [Alerts](08-admin.md#alerts)).

**Downtime:** PHP, Laravel, static and SPA sites switch with zero downtime.
Node.js and Python apps restart, which takes about a second.

## Releases and rollback

```bash
sudo srv deploy releases shop.example.com          # list (* = live), with commit and status
sudo srv deploy rollback shop.example.com          # back to the previous release
sudo srv deploy rollback shop.example.com 20261028T101500Z
```

`srv site rollback` does the same. Rolling back switches code only: **database
migrations are not undone**. If a release ran migrations that the previous code
can't handle, roll them back yourself first
(`srv app exec <domain> 'php artisan migrate:rollback'`).

## Auto-deploy on push (webhooks)

```bash
sudo srv deploy webhook shop.example.com on       # enable; prints the URL and secret
sudo srv deploy webhook shop.example.com show     # show them again
sudo srv deploy webhook shop.example.com rotate   # new secret
sudo srv deploy webhook shop.example.com off
```

The webhook URL is `https://<domain>/_srv/deploy`. Add it to your repository:

| Host | Where | What to enter |
|---|---|---|
| GitHub | Settings → Webhooks → Add webhook | Payload URL; content type `application/json`; the secret; "Just the push event" |
| GitLab | Settings → Webhooks | URL; secret token; "Push events" |
| Bitbucket | Repository settings → Webhooks | URL; secret; "Repository push" |
| Anything else | — | `POST` to the URL with the header `X-Srv-Token: <secret>` |

How it works: the receiver (installed with `srv install webhook`, or
automatically the first time) runs as an unprivileged user on a local port.
It checks the signature, ignores pushes to other branches, and adds the site to a
queue. A systemd path unit picks up the queue and runs `srv deploy` as root, one
deploy at a time. The receiver itself can't run commands.

Turn on HTTPS for the site first (`srv ssl add <domain>`), so the secret isn't
sent in clear text.

Deploying from CI instead? Run `ssh you@server sudo srv deploy <domain> --yes`
at the end of your pipeline, or call the webhook URL with `X-Srv-Token`.

## Settings

Change any of these with `srv site set <domain> <KEY> <value>`. They apply from
the next deploy.

| Key | Default | Meaning |
|---|---|---|
| `BRANCH` | `main` | Branch to deploy (and that webhooks react to) |
| `DEPLOY_KEEP` | `5` | Releases to keep (2–50) |
| `DEPLOY_SHARED_DIRS` | Laravel: `storage`; Django: `media`; others: none | Space-separated folders kept in `shared/` |
| `DEPLOY_SHARED_FILES` | Laravel: `.env`; others: none | Space-separated files kept in `shared/` |
| `DEPLOY_BUILD` | — | Extra build command, run in the new release after the standard build |
| `DEPLOY_AFTER` | — | Command run in the live release after the switch (e.g. cache warm-up) |
| `DEPLOY_MIGRATE` | `yes` for Laravel and Django, otherwise `no` | Run migrations |
| `DEPLOY_COMPOSER` | `yes` | Run `composer install` (PHP/Laravel) |
| `DEPLOY_NPM` | `yes` | Build front-end assets (PHP/Laravel) |
| `DEPLOY_OPTIMIZE` | `yes` | `artisan optimize` (Laravel) |
| `DEPLOY_HEALTH_PATH` | `/` | Path the health check requests, e.g. `/health` |
| `DEPLOY_AUTO_ROLLBACK` | `yes` | Switch back automatically when the health check fails |

Examples:

```bash
sudo srv site set shop.example.com DEPLOY_SHARED_DIRS "storage public/uploads"
sudo srv site set shop.example.com DEPLOY_BUILD "php artisan icons:cache"
sudo srv site set shop.example.com DEPLOY_AFTER "php artisan cache:clear"
sudo srv site set app.example.com  DEPLOY_HEALTH_PATH /api/health
sudo srv site set blog.example.com DEPLOY_SHARED_DIRS "wp-content/uploads"
sudo srv site set blog.example.com DEPLOY_SHARED_FILES "wp-config.php"
```

## Tips

- Commit your lock file (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`,
  `composer.lock`) so every release installs exactly the same versions.
- Keep secrets out of git: Laravel's `.env` is shared automatically; for Node.js
  and Python, use `app.env` (which lives outside the releases).
- Building a large front-end on a small server needs memory: add swap
  (`srv install swap`), or build in CI and commit or download the result in
  `DEPLOY_BUILD`.
- A deploy that needs root (installing a system package) doesn't belong in
  `DEPLOY_BUILD`, which runs as the site user. Do that once by hand.

Next: [SSL and databases](05-ssl-databases.md)
