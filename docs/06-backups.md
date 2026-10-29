# 6. Backups and restore

## Turning on daily backups

```bash
sudo srv install backup
```

You're asked how many days to keep backups (default 7) and whether to include
site files as well as databases (default yes). After that, a cron job runs
`srv backup run` every night at **02:30**. It:

1. dumps every MariaDB/MySQL and PostgreSQL database (`.sql.gz`);
2. archives every site's files (`.tar.gz`);
3. deletes local backups older than the retention period;
4. copies everything to remote storage, if configured, and deletes remote
   copies older than the remote retention (default 30 days);
5. sends an alert if anything failed (when [alerts](08-admin.md#alerts) are set
   up). `srv check` also warns when the newest backup is more than a day old.

Run `srv install backup` again to change the retention or the file setting.

### What a site backup contains

| Site kind | Archived |
|---|---|
| Without git deploys | `app/`, the Python `venv/`, `app.env` |
| With git deploys | the live release, `shared/` (so `.env`, `storage/`, uploads), `app.env` |
| Always | the site's srv settings, its custom Nginx files and release info |

Build caches (`node_modules/.cache`, `.next/cache`, `__pycache__`) are left
out. Databases are backed up separately, as dumps.

### Where backups go

```
/var/backups/srv/
├── db/<database>/<database>-<date>.sql.gz         MariaDB / MySQL
├── pgsql/<database>/<database>-<date>.sql.gz      PostgreSQL
└── files/<domain>/<domain>-<date>.tar.gz          site files
```

Everything is readable by root only. Backups on the same disk protect you
against mistakes, but not against losing the server, so set up a remote copy.

## Backing up by hand

```bash
sudo srv backup run                      # everything, as the nightly job does
sudo srv backup db --all                 # all databases
sudo srv backup db shop_example_com      # one database
sudo srv backup db analytics --pg        # choose the engine when both are installed
sudo srv backup site example.com         # one site's files
sudo srv backup site --all
sudo srv backup list                     # what's there, with sizes and dates
```

Take a manual backup before risky changes, such as a major upgrade or a big
migration.

## Restoring

### A whole site (files and database)

```bash
sudo srv backup restore example.com                    # pick a backup (newest first)
sudo srv backup restore example.com --file /path/to/example.com-….tar.gz
sudo srv backup restore example.com --no-db            # files only
sudo srv backup restore example.com --db               # files + database, no question
```

What happens:

- The current files are **moved aside, not deleted** (`shared.before-restore-<time>`,
  `app.before-restore-<time>`, …), so you can go back.
- The files are restored and permissions fixed. For git sites, the release from
  the backup becomes `current`.
- With the database (if the site has one here): the current database is dumped
  to a **safety copy** first, then the newest dump of the site's database is
  imported into it.
- `.env` / `app.env` are updated with *this* server's database and Redis
  details, so a backup from another server just works.
- The git settings and webhook secret are restored too, so auto-deploys keep
  working.
- The app (or PHP-FPM) restarts.

### One database

```bash
sudo srv backup restore-db shop_example_com                 # newest dump; pick from a list
sudo srv backup restore-db shop_example_com /var/backups/srv/db/shop_example_com/….sql.gz
sudo srv backup restore-db analytics --pg
```

A safety copy of the current database is taken first, and its path is printed.
To undo the restore, restore that safety copy the same way.

## Remote storage

Backups can be copied to any storage rclone supports. srv sets up the most
common ones for you:

```bash
sudo srv backup remote setup
```

| Choice | Notes |
|---|---|
| Amazon S3 or S3-compatible | AWS, Cloudflare R2, Wasabi, DigitalOcean Spaces, MinIO, others. Asks for the access key, secret, region/endpoint, bucket and folder |
| Backblaze B2 | Asks for the key ID, application key and bucket |
| Google Drive | Runs rclone's own wizard (you'll copy a link into your browser) |
| Other | rclone's wizard, for any of its 70+ backends (SFTP, Dropbox, OneDrive, Azure…) |

You're also asked how many days to keep remote copies (default 30). Use a
bucket key that can only reach that bucket.

Non-interactive setup, e.g. for Cloudflare R2:

```bash
sudo srv backup remote setup --type s3 --provider Cloudflare \
     --access-key "$KEY" --secret-key "$SECRET" \
     --endpoint https://<account>.r2.cloudflarestorage.com \
     --bucket my-backups --prefix server1 --keep 30
```

Options: `--type s3|b2|drive|other`, `--provider AWS|Cloudflare|Wasabi|DigitalOcean|Minio|Other`,
`--access-key`, `--secret-key`, `--region`, `--endpoint`, `--bucket`, `--prefix`,
`--keep <days>`, or `--existing <remote:path>` to reuse a remote you already
defined in `/etc/srv/rclone.conf`.

Managing it:

```bash
sudo srv backup remote            # current setting
sudo srv backup remote test       # check that it can write and read
sudo srv backup remote push       # upload now
sudo srv backup remote list       # files on the remote
sudo srv backup remote pull       # download everything into /var/backups/srv
sudo srv backup remote pull files/example.com    # just one site's files
sudo srv backup remote pull db/shop_example_com  # just one database
sudo srv backup remote off        # stop copying (nothing is deleted remotely)
```

## Moving a site to a new server

1. On the new server, install srv and the features the site needs (PHP, the
   database, Node.js…).
2. Create the site with **the same domain and type**, and a database on the
   **same engine** if the old site had one (the restore imports into it):
   ```bash
   sudo srv site add example.com --type laravel --pg --no-ssl
   ```
3. Get the backups, either from remote storage:
   ```bash
   sudo srv backup remote setup         # same bucket and folder as the old server
   sudo srv backup remote pull
   ```
   or by copying `/var/backups/srv/` over with `rsync`/`scp`.
4. Restore:
   ```bash
   sudo srv backup restore example.com --db
   ```
5. Point DNS at the new server, then `sudo srv ssl add example.com`.

For git sites, the deploy key is new on the new server: add the one from
`srv deploy key <domain>` to the repository. The webhook URL and secret stay the
same.

Next: [Runtimes](07-runtimes.md)
