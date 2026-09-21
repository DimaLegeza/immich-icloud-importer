# Design notes

Why `icloud-migrate.sh` is shaped the way it is. Operational instructions are
in [README.md](README.md).

Each section below records a measurement that changed the design. They are kept
because every one of them was counter-intuitive, and several were discovered
only after losing work to the alternative.

## `sync`: why there are no date windows

Two measurements killed the windowed design.

**Date filtering is client-side.** Every `--skip-created-before/after` invocation
walks the *entire* asset list and discards what falls outside the window, at
roughly 38 assets/sec. For a 248k-asset library that is **~107 minutes of pure
walking per window**, whatever the window contains.

**icloudpd's iCloud session dies about two hours in.** Observed twice:

```
run 1   16:19:57 -> 18:20:16   2h00m19s   386 downloaded
run 2   18:46:13 -> 20:55:15   2h09m02s  1512 downloaded
```

Elapsed time, not volume. So the walk consumed nearly the whole session and left
~10 minutes of useful downloading per attempt — and a window of 24,000 assets
would have needed roughly 24 two-hour attempts.

> **Correction (2026-09-09).** The "sessions die at two hours" reading was
> wrong as a general rule: once `sync` was downloading continuously, a single
> pass ran for **11+ hours** and another for **12¼**. What the two runs above
> have in common is not elapsed time but ~107 minutes of *enumeration* — the
> connection goes stale while idle and fails on first use. Continuous
> downloading keeps it warm. This does not change the conclusion (the windowed
> design was still paying 107 minutes per window for nothing), but the
> mechanism is staleness, not a session timeout.

`sync` drops the filters entirely. Unfiltered there is nothing to skip: every
asset walked is an asset downloaded, so work starts immediately. Each pass runs
until the session expires; the next pass resumes, with the zero-byte stubs making
icloudpd skip what is already imported. The only growing cost is walking past
those stubs.

It stops when icloudpd finally exits **successfully**, and aborts after three
passes that import nothing — so a broken session or dead network cannot spin all
night. `DEBUG_DL=1` swaps in `--log-level debug` to capture the real exception
behind icloudpd's generic "Cannot connect to Apple iCloud service", which is
still unidentified.

`plan` and `orphans` remain for reference, but `sync` supersedes them.

## Zero-byte stubs make the catch-all resumable

Verified 2026-09-08: under `--file-match-policy name-id7`, icloudpd treats a
**zero-byte file as already downloaded**. Truncate a downloaded file to 0 and a
later run skips it without re-fetching.

The catch-all uses that. After each batch uploads, its files are truncated
rather than deleted, and the file list only considers files of non-zero size.
So:

- **resume costs nothing** — no re-download, and no re-hashing either
- **disk stays near empty** between windows; the stubs are directory entries
- all windows share **one** staging tree (`$STAGE/all`) with
  `--folder-structure '{:%Y/%m}'`, because icloudpd looks for
  `<dir>/<YYYY>/<MM>/<name>` and per-window directories would hide the stubs.
  The date subfolders also keep each FAT32 directory to ~1300 entries instead of
  one directory holding 248k, which FAT32 scans linearly.

**Never delete `$STAGE/all`.** Those stubs are the record of what has been
imported; losing them means re-downloading the library.

The cosmetic cost is that `name-id7` appends a 7-character asset id to filenames
(`IMG_3614_QVl3UGt.HEIC`), which becomes the original filename in Immich.
Deduplication is by checksum, so nothing functional changes.

## Why `plan` exists

Every date-filtered icloudpd invocation walks the **entire** asset list and skips
whatever falls outside its window, logging a `DEBUG Skipping ...` line for each.
Over ~275k assets and 228 month windows that is ~62 million skip decisions, and
hours of enumeration before a single byte downloads.

`--folder-structure '{:%Y/%m}'` makes `--only-print-filenames` emit paths that
carry each asset's date, so **one** pass yields a complete per-month census.
`orphans` then reads that manifest and:

- never visits a month with no assets
- merges consecutive sparse months into one window, up to `WINDOW_MAX` assets
- leaves heavy months on their own so the staging disk is not overrun

On a library whose early years hold a handful of photos a month, that collapses
228 invocations into a few dozen. Downloads also run at `--log-level info`, which
keeps every error and drops the per-skipped-asset DEBUG spam.

**Most assets are in no album** — they are simply in "Recents", which is a smart
album covering the whole timeline. So `orphans` carries the bulk of the library
and is the long pole; `small` and `big` cover a minority. It runs month by month
by default (`GRAIN=month`), because a single year of a video-heavy period can
exceed a 500 GB staging disk and icloudpd would fill it and fail mid-download.
Set `GRAIN=year` only if the staging disk comfortably exceeds any single year.

It records progress in `~/.icloud-migrate/done.txt`, so it is safe to interrupt
and re-run. Tunables: `SMALL_MAX`, `MIN_FREE_GB`, `YEAR_FROM`/`YEAR_TO`,
`IMMICH_CONC`, `BATCH_FILES`, `SKIP_ALBUMS_RE`, `GRAIN`, `SKIP_LIVE`.

**Always run `verify` after a pass.** Every failure encountered while building
this looked like success — parsed log lines, a missing `--directory` returning 0
for every album, AppleDouble sidecars doubling file counts, an album journalled
as done after a failed upload, a glob metacharacter making the CLI skip 178
files while exiting 0, and a failure-detector that did not match the failure
text. Local state cannot see any of that; only the server can.

## Staging on FAT is deliberate

The pool is FAT32, so a file that cannot be written to a FAT staging disk could
never have lived on the pool either. Staging on FAT makes it fail at *download*,
before the bandwidth is spent, and `report` lists what was rejected.

The script detects a FAT staging volume and adapts: **uploads are batched**
(`BATCH_FILES`, default 150 on FAT and 1000 elsewhere). A whole album in one
`immich upload` call means immich hashes the entire directory and then uploads
it — two full passes over a spinning disk — and one stall costs the album.
Batching bounds each I/O burst, and each batch's files are deleted as soon as it
lands, so a retry never re-reads what already succeeded.

Two FAT-specific effects are handled automatically: AppleDouble `._` sidecars
(macOS writes one per file, since FAT holds no xattrs) are stripped before
counting or uploading, and glob metacharacters in album names are removed from
staging paths — the Immich CLI globs its path argument, so a directory named
`Escape to B (редактир)` matched nothing and uploaded zero files while exiting
successfully.

**Verified on Immich 3.1.0 (2026-09-07): duplicates do join the named album.**
An 8-asset album where 6 already existed from a phone backup reported:

```
Found 2 new files and 6 duplicates
Successfully uploaded 2 new assets (4 MB)
Successfully created 0 new albums
Successfully updated 8 assets
```

All 8 joined the album, and the CLI reused the existing album by name rather
than creating a second one — so [immich#28142](https://github.com/immich-app/immich/issues/28142)
does not apply to this version. Album-first ordering is therefore a nicety
rather than a requirement, though still worth keeping: it means an asset's album
is set on its first upload rather than depending on the duplicate path.

**Two behaviours are undocumented upstream** and `preflight` probes both:
whether `--folder-structure none` is accepted, and whether `--album` can be
combined with `--skip-created-before`/`--skip-created-after`. If the latter
fails, large albums cannot be split by year and need another strategy.

## The FAT32 ceiling

Every pool branch is FAT32, so **no single file over 4 GiB can be stored**. The
staging disk is FAT32 too, deliberately: an oversized asset then fails at
*download* time rather than after the bandwidth has been spent, and nothing gets
staged that could not be stored anyway.

The cost is that such failures are otherwise invisible — the file never appears
on disk, so a size check after the fact can never see it. `download()` therefore
logs every window and greps for `EFBIG`/"file too large", collecting the affected
assets:

```bash
./icloud-migrate.sh report
```

Anything listed there is a genuine gap in the library. Options: give the pool one
exFAT or ext4 branch for large video, transcode them smaller, or copy them across
by hand.
