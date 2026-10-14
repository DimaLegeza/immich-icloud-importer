# immich-icloud-importer

Move an iCloud Photos library into [Immich](https://immich.app), album
structure preserved, staging through a disk **far smaller than the library**.

The whole thing is designed around one assumption: **it will be interrupted.**
Laptop lids close, VPNs drop, Apple throttles, drives get unplugged for the
commute. Every command is resumable and safe to re-run.

A bash wrapper around [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader)
and the Immich CLI. It adds the parts those two do not cover between them:
staging within a fixed disk budget, album-preserving upload, journalled
progress, and resume that costs nothing.

## Safety

**It never modifies your iCloud library.** No delete, no move, no metadata
write — icloudpd is invoked for download only, and the script passes no
destructive flags. The only things it removes are files it has itself staged
on the staging disk, after they have been accepted by Immich.

Still: this is a tool that moves a quarter of a million irreplaceable files
around. Read [Prerequisites](#1-prerequisites) before running it, and try
`./icloud-migrate.sh album "<some small album>"` first.

## Status

Proven on a **~250,000-asset library**, staged through a 500 GB FAT32 external
disk, uploading to Immich on a Raspberry Pi 4 over LAN. Completed 2026-09-19:
250,025 assets imported, three failures, all understood.

Tested with:

| | |
|---|---|
| icloudpd | 1.32.3 |
| Immich CLI | 3.1.0 |
| Immich server | 3.1.0 – 3.2.2 |
| bash | 3.2 (macOS system bash) and later |
| host | macOS. Should work on Linux — the only platform-specific logic is FAT detection, which handles both `msdos` and `vfat` — but it has not been run there. |

This was built to solve one migration and is shared in case it is useful. It is
not packaged, has no test suite, and its defaults reflect the library it was
written for.

---

## 1. Prerequisites

### Install

macOS:

```bash
brew install icloudpd immich-cli
```

`immich-cli` is in homebrew-core; the official Immich docs list only npm and
Docker.

Linux, or if you prefer not to use Homebrew:

```bash
pipx install icloudpd          # or: pip install --user icloudpd
npm install -g @immich/cli
```

Verify both:

```bash
icloudpd --version
immich --version
```

### Immich: API key and CLI login

In the Immich web UI: **Account Settings → API Keys → New API Key**. Give it
all permissions. Copy the key — it is shown once.

```bash
immich login http://<pi-address>:2283/api <api-key>
```

This writes `~/.config/immich/auth.yml`. Check it worked:

```bash
immich server-info
```

The CLI must stay logged in for the whole migration. It is not re-authenticated
by the script.

### Immich: what to turn OFF before starting

A large import will overwhelm a small server if the background jobs are left
running. On a Pi 4 this caused an OOM reboot that took the storage pool with it.

In **Administration → Settings**:

| setting | do this | why |
|---|---|---|
| **Machine Learning** → all features | **disable** | Smart Search and Face Detection queue a job per asset. Pausing the queue is not enough — jobs still accumulate. |
| **Thumbnail Generation** job | **pause** | Competes for disk with the upload. Run it once, after the import. |

And stop the ML container outright, since a disabled feature still leaves it
resident:

```bash
ssh <pi> 'docker stop immich_machine_learning && \
          docker update --restart=no immich_machine_learning'
```

Note that `docker compose up -d` resets the restart policy, so this needs
redoing after any stack update.

Re-enable everything **after** the import, one at a time, thumbnails first.

### iCloud: two-factor authentication

```bash
./icloud-migrate.sh login
```

Prompts for the password and a 2FA code once. The trust token then persists for
weeks in `$COOKIES` (default `~/.icloudpd-<user>`). If a run later dies with
authentication errors, re-run `login`.

### Staging disk

Needs to be a real disk, not a network share, with enough free space for the
largest single batch — **60 GB free is the default floor** (`MIN_FREE_GB`).

**FAT32 staging is deliberate here.** The destination pool is FAT32, so a file
that cannot be written to the staging disk could never have been stored on the
pool either. Staging on FAT makes an oversized file fail at *download*, before
the bandwidth is spent, and `report` lists what was rejected. On a non-FAT
staging disk the same file downloads happily and fails at upload instead.

The script detects FAT and adapts: 150 files per upload batch instead of 1000,
AppleDouble `._` sidecars stripped, glob metacharacters removed from directory
names.

### Configure the session

```bash
cp session.env.example session.env    # then edit
source session.env
```

`session.env` is gitignored — it holds an Apple ID.

| variable | meaning |
|---|---|
| `ICLOUD_USER` | the Apple ID whose library is being migrated — **not** the Immich login |
| `STAGE` | staging directory, e.g. `/Volumes/STAGING/icloud` |
| `SKIP_LIVE` | `1` omits the `.MOV` half of Live Photos (see below) |
| `WINDOW_MAX` | assets per window; **must not change mid-job** |
| `MIN_FREE_GB` | stop staging when free space drops below this |
| `IMMICH_CONC` | parallel uploads. 2 is sane; 1 if the destination struggles |

Other tunables, all with defaults and settable the same way:

| variable | default | meaning |
|---|---|---|
| `SKIP_ALBUMS_RE` | see below | regex of album names to skip |
| `SMALL_MAX` | `1000` | at or above this an album is fetched per-year |
| `BATCH_FILES` | `150` FAT / `1000` other | files per `immich upload` call |
| `MAX_MINUTES` / `MAX_WINDOWS` | `0` (no limit) | stop cleanly at a window boundary |
| `COOKIES` | `~/.icloudpd-<user>` | icloudpd cookie/trust-token directory |
| `WORK` | `~/.icloud-migrate` | journal, manifests and logs |
| `DEBUG_DL` | `0` | `1` runs icloudpd at `--log-level debug` |
| `PROBE_ALBUM` | first non-smart album | which album `preflight` measures against |

### `SKIP_ALBUMS_RE` is locale-specific — check it

The default skips Apple's smart and system albums, which are huge, overlap
each other, and are not real user structure. Their contents still arrive via
`sync`, just without a meaningless album attached.

**Apple localises these names**, and the default only covers English plus the
two Russian names the reference library had. If your library is in another
language, list your albums and extend the pattern, or you will import
"Recently Deleted" and "Hidden" — resurrecting photos that were deleted or
deliberately hidden:

```bash
./icloud-migrate.sh albums
export SKIP_ALBUMS_RE='^(All Photos|Recents|...|Zuletzt gelöscht|Ausgeblendet)$'
```

Sourcing prints a confirmation line. If you see `set ICLOUD_USER=...`, you
forgot to source it — a fresh shell has none of these.

### Keep the machine awake

```bash
screen -S icloud
caffeinate -s ./icloud-migrate.sh sync 2>&1 \
  | tee -a ~/.icloud-migrate/logs/night-$(date +%F).log
```

`caffeinate -s` stops the Mac sleeping mid-run. `screen` survives a dropped SSH
session — detach with **Ctrl-A** then **D**, reattach with `screen -r icloud`.
The `tee` is not optional in practice: every diagnosis in this project came out
of those logs.

---

## 2. Execution flow

State lives in `$WORK` (default `~/.icloud-migrate`): `done.txt`,
`failures.txt`, `manifest.tsv`, `albums.txt`, `album-counts.tsv`, and `logs/`.

### Step 0 — verify assumptions

```bash
./icloud-migrate.sh albums      # fast: list album names
./icloud-migrate.sh preflight   # fast: probes undocumented icloudpd behaviour
```

`preflight` answers three things the upstream docs do not, by measuring rather
than assuming:

- whether `--folder-structure none` is accepted;
- whether `--album` composes with the date filters (this gates the `big`
  strategy);
- **what `--skip-live-photos` actually drops.** icloudpd downloads a Live
  Photo's video component as a separate file and the Immich CLI cannot pair
  them, so importing both halves gives you two assets per Live Photo. The docs
  do not say whether the flag drops only the `.MOV` or the still as well.
  `preflight` diffs two listings and tells you.

It probes a real album, not a smart one. Override with
`PROBE_ALBUM='Japan' ./icloud-migrate.sh preflight`.

### Step 1 — albums

```bash
./icloud-migrate.sh counts      # slow: walks every album
./icloud-migrate.sh small       # albums under SMALL_MAX, batched together
./icloud-migrate.sh big         # larger albums, one year at a time
```

Assets are uploaded with `-A "<album name>"`, so Immich builds the album as it
goes. An asset in three albums uploads once and joins all three — Immich
deduplicates by checksum server-side, and **verified on 3.1.0, duplicates do
still join the named album**.

Smart and system albums are skipped (`SKIP_ALBUMS_RE`). "Recently Deleted" and
"Hidden" matter most: importing those would resurrect deleted or deliberately
hidden photos.

To validate the pipeline on one album before committing to all of them:

```bash
./icloud-migrate.sh album "Japan"
```

### Step 2 — everything else

Most assets are in **no album** — they are simply in "Recents", which is a smart
album covering the whole timeline. So this pass carries the bulk of the library.

```bash
./icloud-migrate.sh sync
```

`sync` runs unfiltered passes until icloudpd exits cleanly. Per pass it:

1. uploads anything already staged from a previous run;
2. runs icloudpd unfiltered with `--folder-structure '{:%Y/%m}'`;
3. uploads what arrived, truncating each uploaded file to a **zero-byte stub**;
4. repeats, aborting after three passes that import nothing.

**Use `sync`.** `plan` and `orphans` are the earlier date-windowed design and
are kept only for reference. They were abandoned because
`--skip-created-before/after` are **client-side** filters: every window walks
the entire library before matching anything, which meant ~107 minutes of silence
before the first download. `sync` starts downloading in about four seconds.

### Step 3 — check what did not make it

```bash
./icloud-migrate.sh report
./icloud-migrate.sh verify        # cross-check done.txt against the server
./icloud-migrate.sh verify --fix  # un-mark anything the server disagrees with
```

`report` is **cumulative** — it lists every failure ever recorded, including
ones a later pass recovered. Check whether a file is actually missing before
acting on it, and check case-insensitively; icloudpd writes `.JPG` where the log
said `.jpg`:

```bash
find "$STAGE/all" -iname 'IMG_1234_*' -exec ls -l {} \;
```

A zero-byte result means **imported**. No result means genuinely missing.

### Step 4 — afterwards

- Re-enable thumbnails, let them finish, then re-enable ML. Not together.
- Album cleanup. An iCloud library typically arrives with a lot of noise —
  empty albums, duplicate names, and smart-album mirrors left over from Apple's
  own organisation. On the reference library that was 214 albums down to about
  55. Immich's own album view plus its API will get you there; this tool does
  not do it for you.
- **Do not delete the staging tree.** See below.

### Step 5 — optional: free up iCloud

Once the library looks right in Immich, `prune` deletes from iCloud everything
taken before a date, to get under a smaller storage plan:

```bash
./icloud-migrate.sh prune 2020-01-01                  # dry run: counts, deletes nothing
./icloud-migrate.sh prune 2020-01-01 --delete         # lists, then asks you to type "delete N"
./icloud-migrate.sh prune 2020-01-01 --resume ~/.icloud-migrate/prune/before-….jsonl
```

- It does **not** check Immich. It deletes by date only, so run it after you
  have looked.
- Deleted assets go to **Recently Deleted**: recoverable for 30 days, and still
  counting against the plan until that album is emptied. Emptying it is the
  point of no return, and Immich then holds the only copy.
- Lost with the iCloud copy: the motion half of Live Photos (if you imported
  with `SKIP_LIVE=1`) and edits (the import takes unedited originals).
- Listing a 150k-asset library takes about an hour. Each listing is saved as a
  `.jsonl` plan, and `--resume` deletes the rest of a plan without listing
  again.
- Apple throttles bulk deletes (503, "concurrent write", dropped connections).
  The script waits and retries; if Apple keeps refusing, it stops and prints
  the `--resume` command.
- The listing pages by position, and the iPhone syncing deletions mid-listing
  shifts positions: some assets come back twice and as many are skipped. Run a
  dry run at the end, and `--delete` again until it reports nothing.

---

## 3. Re-triggering flow

### Stopping

**Ctrl-C once.** The signal reaches whichever child is in the foreground
(icloudpd or `immich`), which dies immediately; the script then stops at the
next clean boundary rather than starting another batch. Don't press it
repeatedly — the second one can kill the shell before the handler finishes.

Then confirm nothing still holds the disk, and unmount properly:

```bash
ps aux | grep -E 'icloudpd|immich upload|icloud-migrate' | grep -v grep
diskutil unmountDisk /Volumes/STAGING      # macOS; FAT32 has no journal
```

Wait for `Unmount of all volumes ... was successful` before pulling the cable.

### Resuming

```bash
ls -d "$STAGE/all"        # must be the ORIGINAL path, not "STAGING 1"
screen -S icloud
cd /path/to/icloud-migrate
source session.env        # a fresh shell has nothing
caffeinate -s ./icloud-migrate.sh sync 2>&1 \
  | tee -a ~/.icloud-migrate/logs/night-$(date +%F).log
```

macOS mounts a second copy as `STAGING 1` if the previous unmount was unclean.
Running against that path would re-download the entire library.

Re-run **the same command**. Nothing needs to be told where it got to.

### Why resume is cheap: zero-byte stubs

Verified 2026-09-08: under `--file-match-policy name-id7`, icloudpd treats a
**zero-byte file as already downloaded**. So after each batch uploads, its files
are truncated rather than deleted. The stub is a permanent marker:

- icloudpd skips it without re-fetching from Apple;
- the script's own file list uses `-size +0`, so it is never re-hashed or
  re-uploaded;
- the staging disk stays near-empty — the stubs are just directory entries.

> ### Never delete `$STAGE/all`
>
> Those stubs are the only record of what has been imported. Losing them means
> re-downloading the entire library — a fortnight of work.

### What survives an interruption

| | |
|---|---|
| completed albums | `done.txt`, skipped on re-run |
| uploaded assets | zero-byte stubs, skipped by icloudpd and by the uploader |
| downloaded-but-not-uploaded | kept at full size, uploaded first on the next pass |
| a partly-downloaded window | resumes; icloudpd skips files already present |
| a failed upload batch | files kept at full size, retried |

Nothing is marked done unless the download **and** the upload both succeeded. A
partial download that uploads cleanly is not success — that bug cost a window of
several thousand assets before it was fixed.

### Interrupting for a while, not just a moment

```bash
MAX_MINUTES=120 ./icloud-migrate.sh sync    # stop cleanly after ~2 hours
MAX_WINDOWS=5   ./icloud-migrate.sh sync    # stop after 5 windows
```

Both are checked **between** windows, never mid-window.

### When a run fails

```bash
ls -lt ~/.icloud-migrate/logs | head
tail -30 ~/.icloud-migrate/logs/sync-pass-1.log
```

| symptom | meaning | do |
|---|---|---|
| `Cannot connect to Apple iCloud service` | session went stale, usually after hours | re-run; `DEBUG_DL=1` for the real exception |
| `Gone (410)`, many, with long stalls | **Apple throttling** — episodic, recovers within the same session | nothing; a 410'd file leaves no stub and retries next pass |
| `Bad Request (400)` on the same file repeatedly | server-side asset problem, often a `.TRIM` edited video | duplicate it in Photos on the phone; the copy syncs cleanly |
| `IOError while writing ... might be too large` | over FAT32's 4 GiB ceiling | genuine gap; needs an exFAT/ext4 branch |
| `No files found, exiting` with exit 0 | the Immich CLI globbed the path and matched nothing | already handled by `slug()`; treated as failure |
| `set ICLOUD_USER=...` | you didn't `source session.env` | source it |

### Never edit the script while it is running

bash reads scripts incrementally. Shifting byte offsets mid-run produces
nonsense errors like `is: command not found`. Check `ps` first.

---

## A successful upload does not mean the bytes landed

The most important thing learned from this migration.

`immich upload` returned exit 0, the script truncated the file to a stub, and
the destination drive dropped mid-write — leaving 46 MB of a 203 MB video on
disk. The CLI had its success, the database row was written, the stub claimed
the asset was safely imported, and the data was gone.

Immich's **Integrity Report cannot see this**: the file still exists, and the
stored checksum is of the complete original. Only `fsck` on the destination
filesystem finds it.

Worse, re-uploading does not repair it. Immich matches the checksum, replies
"duplicate", and never touches the truncated file. **The asset must be deleted
in Immich — and the trash emptied — before a re-upload is accepted.**

If the destination is a journal-less filesystem such as FAT32 — likely if you
are pooling USB disks — run `fsck.vfat -a` on it after any unclean event, and
read the output carefully:

```
cluster chain length is > 42991616   <- surplus trimmed, file INTACT
cluster chain length is 46628864     <- file TRUNCATED, data lost
```

---

## Known limitations

Left unfixed deliberately — they cost wall-clock, not correctness.

1. **Uploads only run after a download pass ends.** A 12-hour download means
   nothing reaches Immich for 12 hours.
2. **A full staging disk makes icloudpd skip files and exit 0**, which the loop
   would read as "fully imported". Watch `MIN_FREE_GB`.
3. **Ctrl-C does not bank downloads in progress.** The backlog stays staged and
   is picked up on the next run, but it is not uploaded on the way out.

---

## Licence

MIT — see [LICENSE](LICENSE).
