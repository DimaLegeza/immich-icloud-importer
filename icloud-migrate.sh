#!/usr/bin/env bash
#
# Migrate an iCloud Photos library into Immich, album structure preserved,
# staged through a disk far smaller than the library.
#
# Strategy:
#   small albums (< $SMALL_MAX assets)  -> batched together until the staging
#                                          disk fills, uploaded, deleted
#   large albums                        -> downloaded one year at a time
#   everything else                     -> a final catch-all pass by year, so
#                                          assets in no album are not missed
#
# Immich deduplicates by checksum server-side, so re-offering an asset costs
# transfer but not storage — which is what makes an asset in three albums work:
# it uploads once and joins all three.
#
# Usage:
#   export ICLOUD_USER=wife@icloud.com
#   export STAGE=/Volumes/HDD/icloud
#   ./icloud-migrate.sh login
#   ./icloud-migrate.sh albums      # fast
#   ./icloud-migrate.sh preflight   # fast, and gates the 'big' strategy
#   ./icloud-migrate.sh counts      # slow: walks every album
#   ./icloud-migrate.sh small
#   ./icloud-migrate.sh big
#   ./icloud-migrate.sh plan        # one enumeration -> per-month census
#   ./icloud-migrate.sh sync        # RECOMMENDED: unfiltered, self-resuming
#   ./icloud-migrate.sh orphans     # legacy windowed pass (see cmd_sync notes)
#   ./icloud-migrate.sh report      # progress + assets too big for FAT32
#   ./icloud-migrate.sh album "Japan"   # one album, for validating the pipeline
#   ./icloud-migrate.sh verify [--fix]  # cross-check done.txt against the server

set -euo pipefail

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }

# Help must work before the required-variable check below, or you can never
# read the usage without already knowing what to set.
case "${1:-}" in ""|-h|--help|help) usage; exit 0 ;; esac

ICLOUD_USER="${ICLOUD_USER:?set ICLOUD_USER=someone@icloud.com}"
COOKIES="${COOKIES:-$HOME/.icloudpd-${ICLOUD_USER%%@*}}"
STAGE="${STAGE:-/Volumes/HDD/icloud}"
WORK="${WORK:-$HOME/.icloud-migrate}"

# Staging directories are removed with `rm -rf` once their contents have been
# uploaded. That is safe only while $STAGE points somewhere disposable, so
# refuse the values where a typo would be expensive. Cheap insurance against
# `export STAGE=` in the wrong shell.
case "${STAGE%/}" in
    ""|"/"|"$HOME"|"/Users"|"/home"|"/Volumes"|"/mnt"|"/media"|"/tmp")
        printf '\033[31m!! refusing STAGE=%s — point it at a dedicated staging directory\033[0m\n' \
            "${STAGE:-<empty>}" >&2
        exit 1 ;;
esac

SMALL_MAX="${SMALL_MAX:-1000}"     # assets; at or above this an album goes per-year
MIN_FREE_GB="${MIN_FREE_GB:-60}"   # stop staging more when free space drops below this
# Left empty on purpose: when a manifest exists these are derived from it, so a
# hardcoded floor cannot silently drop assets. This library holds 5 photos dated
# 1985-11 -- scanned originals -- which a 2008 default would have excluded
# without a word.
YEAR_FROM="${YEAR_FROM:-}"
YEAR_TO="${YEAR_TO:-}"
# Granularity of the catch-all pass. Most assets live in no album (they are just
# in "Recents"), so this pass carries the bulk of the library. A whole year of a
# video-heavy period can exceed a 500 GB staging disk, and icloudpd would fill it
# and fail mid-download -- so default to months. Set GRAIN=year for fewer, larger
# batches if the staging disk is comfortably bigger than any single year.
GRAIN="${GRAIN:-month}"
IMMICH_CONC="${IMMICH_CONC:-2}"    # keep low: the Pi is the bottleneck, not the network

# Files per immich invocation. A whole album in one call means immich hashes the
# entire staging directory, then uploads it -- two full passes over a spinning
# disk, and a stall costs the whole album. Batching bounds the I/O burst and
# preserves progress: each batch's files are deleted once it succeeds, so a
# retry never re-reads them. Lower on FAT, which is markedly more fragile here.
BATCH_FILES="${BATCH_FILES:-0}"    # 0 = choose from the staging filesystem

# Time-box a run so it ends at a window boundary instead of being killed. The
# catch-all pass is ~216 month windows over ~265k assets, i.e. days of work,
# and a laptop that commutes cannot host an uninterrupted run. Both limits are
# checked between windows, never mid-window, so nothing is left half-done.
MAX_MINUTES="${MAX_MINUTES:-0}"    # 0 = no limit
MAX_WINDOWS="${MAX_WINDOWS:-0}"    # 0 = no limit
START_TS=$(date +%s)
WINDOWS_DONE=0

# True when $STAGE sits on an MS-DOS/FAT volume (FAT16/FAT32, not exFAT).
#
# Parsed out of `mount` rather than `stat -f`, because the two platforms
# disagree on both the flag and the name:
#   macOS   /dev/disk4s1 on /Volumes/X (msdos, local, nodev, ...)
#   Linux   /dev/sdb1 on /mnt/x type vfat (rw,relatime,...)
# and macOS `stat -f` takes a format string, so `stat -f -c %T` silently
# returns the literal "-c" instead of failing.
#
# exFAT must NOT match: it has no 4 GiB per-file ceiling, so the FAT handling
# below would be wrong for it. Anchoring on "(" or "type " keeps "exfat" out.
stage_is_fat() {
    local mp line
    mp=$(df -P "$STAGE" 2>/dev/null | awk 'NR==2 {print $6}')
    [ -n "$mp" ] || return 1
    line=$(mount | grep -F " on ${mp} " | head -1)
    [ -n "$line" ] || return 1
    printf '%s' "$line" | grep -qE '(\(|type )(msdos|vfat)([,) ]|$)'
}

# Smart/system albums: auto-generated, overlapping, and not real user structure.
# Their contents are still captured by the 'orphans' pass, just without a
# meaningless album attached. "Recently Deleted" and "Hidden" are the important
# ones -- uploading those would resurrect deleted or deliberately hidden photos.
SKIP_ALBUMS_RE="${SKIP_ALBUMS_RE:-^(All Photos|Recents|Recently Added|Favorites|Favourites|Hidden|Deleted|Recently Deleted|Time-lapse|Slo-mo|Bursts|Panoramas|Screenshots|Selfies|Live|Live Photos|Portrait|Animated|Videos|Отмечен\. флажком|Отмеченные)$}"

# SKIP_LIVE=1 omits the video half of Live Photos. See cmd_preflight: the CLI
# cannot pair them, so importing both halves yields two assets per Live Photo.
SKIP_LIVE="${SKIP_LIVE:-0}"
ICD=(icloudpd --username "$ICLOUD_USER" --cookie-directory "$COOKIES")
# icloudpd writes its INFO/DEBUG log lines to STDOUT, so anything parsing its
# output must silence them or they end up in the data. ICDQ is for
# machine-readable output (--list-albums, --only-print-filenames); ICD stays
# verbose for interactive auth and for downloads, where progress is useful.
ICDQ=("${ICD[@]}" --log-level error)
# Downloads log one DEBUG line per asset *skipped* by a date filter. Over a
# 275k-asset library that is tens of thousands of lines per window, all noise.
# --log-level info keeps "Downloaded X" and every error, and drops the rest.
ICDL=("${ICD[@]}" --log-level info)
# DEBUG_DL=1 captures the real exception behind icloudpd's generic
# "Cannot connect to Apple iCloud service". Very verbose.
[ "${DEBUG_DL:-0}" = 1 ] && ICDL=("${ICD[@]}" --log-level debug)
DL=(--size original)
[ "$SKIP_LIVE" = 1 ] && DL+=(--skip-live-photos)
mkdir -p "$WORK"

# FAT staging is a deliberate choice here: the pool is FAT32, so a file that
# cannot be written to the staging disk could never have lived on the pool
# either. It fails at download instead of after the bandwidth is spent.
if stage_is_fat; then
    STAGE_FAT=1
    [ "$BATCH_FILES" -eq 0 ] && BATCH_FILES=150
else
    STAGE_FAT=0
    [ "$BATCH_FILES" -eq 0 ] && BATCH_FILES=1000
fi

ALBUMS="$WORK/albums.txt"
COUNTS="$WORK/album-counts.tsv"
DONE="$WORK/done.txt"; touch "$DONE"
FAILURES="$WORK/failures.txt"; touch "$FAILURES"
MANIFEST="$WORK/manifest.tsv"     # YYYY-MM <tab> asset count, from 'plan'
# Assets per window when merging sparse months. Windows are merged until adding
# the next month would exceed this, so the staging disk is never overrun.
WINDOW_MAX="${WINDOW_MAX:-4000}"
LOGS="$WORK/logs"; mkdir -p "$LOGS"

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

free_gb() { df -k "$STAGE" | awk 'NR==2 {print int($4/1048576)}'; }
# Ctrl-C is a supported way to stop. The signal also reaches whichever child is
# in the foreground (icloudpd or immich), so it dies immediately; this flag then
# stops the loop at the next boundary rather than blundering into the next
# window. Nothing is marked done unless it fully succeeded, so a resume simply
# repeats the interrupted window -- and icloudpd skips files already on disk, so
# a part-downloaded window continues rather than restarting.
INTERRUPTED=0
on_interrupt() {
    INTERRUPTED=1
    printf '\n'
    warn "interrupt received — stopping at the end of this step"
}
trap on_interrupt INT TERM

stopping() { [ "$INTERRUPTED" = 1 ]; }

resume_hint() {
    local orph total
    orph=$(grep -c '^orphans:' "$DONE" 2>/dev/null || true)
    total=$(grep -c . "$WORK/windows.tsv" 2>/dev/null || true)
    log "stopped — progress is saved"
    printf '   %s of %s window(s) complete\n' "${orph:-0}" "${total:-?}"
    printf '   resume with the same command; completed windows are skipped\n'
}

# Fill YEAR_FROM/YEAR_TO from the manifest when the caller has not set them.
derive_years() {
    if [ -s "$MANIFEST" ]; then
        [ -n "$YEAR_FROM" ] || YEAR_FROM=$(cut -d- -f1 "$MANIFEST" | sort -n | head -1)
        [ -n "$YEAR_TO" ]   || YEAR_TO=$(cut -d- -f1 "$MANIFEST" | sort -n | tail -1)
    fi
    # No manifest (the per-year album pass) -- fall back to a sane calendar.
    [ -n "$YEAR_FROM" ] || YEAR_FROM=2008
    [ -n "$YEAR_TO" ]   || YEAR_TO=2026
}

# True when this run has used up its allowance. Checked only between windows.
budget_spent() {
    if [ "$MAX_WINDOWS" -gt 0 ] && [ "$WINDOWS_DONE" -ge "$MAX_WINDOWS" ]; then
        log "MAX_WINDOWS=$MAX_WINDOWS reached — stopping cleanly"
        return 0
    fi
    if [ "$MAX_MINUTES" -gt 0 ]; then
        local mins=$(( ( $(date +%s) - START_TS ) / 60 ))
        if [ "$mins" -ge "$MAX_MINUTES" ]; then
            log "MAX_MINUTES=$MAX_MINUTES reached (${mins}m elapsed) — stopping cleanly"
            return 0
        fi
    fi
    return 1
}

strip_logs() { grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} +(DEBUG|INFO|WARNING|ERROR)' || true; }
# First day of the month after YYYY MM -- the exclusive upper bound of a window.
next_month() {
    local y="$1" m="$2"
    if [ "$m" -ge 12 ]; then printf '%04d-01-01' "$((y+1))"
    else printf '%04d-%02d-01' "$y" "$((m+1))"; fi
}
# The Immich CLI treats its path argument as a glob, so ( ) [ ] { } ! * ? in a
# directory name make it match nothing -- it prints "No files found, exiting"
# and exits 0. Album names like "Escape to B (редактир)" therefore uploaded
# nothing at all. Sanitise the staging directory; the album name passed to -A
# is unaffected, so Immich still shows the real name.
slug()    { printf '%s' "$1" | tr '/:\\()[]{}!*?' '_____________' | tr -s ' ' ' '; }
is_done() { grep -qxF "$1" "$DONE"; }
mark_done(){ printf '%s\n' "$1" >> "$DONE"; }

# download <key> <icloudpd args...>
# Logs each window and records assets that could not be written. The staging
# disk is FAT32, so anything over 4 GiB fails at WRITE time with EFBIG rather
# than being visible on disk afterwards -- warn_oversize can never see it. Left
# unrecorded these are silent holes in the library, so grep them out of the log.
download() {
    local key="$1"; shift
    local logf="$LOGS/$(printf '%s' "$key" | tr '/ :' '___').log"
    local ok=1
    "${ICDL[@]}" "$@" 2>&1 | tee "$logf" || ok=0
    # A transient 'Cannot connect to Apple iCloud service' mid-window leaves a
    # partial download. Returning 0 here made that indistinguishable from
    # success: the partial set uploaded fine, so the window was journalled
    # complete with thousands of assets missing.
    [ "$ok" = 1 ] || warn "icloudpd exited non-zero for '$key' — PARTIAL download, see $logf"
    # Match icloudpd's actual wording. It reports an oversized file as
    #   'IOError while writing file to X. You might have run out of disk space,
    #    or the file might be too large for your OS. Skipping this file...'
    # which contains none of 'file too large', 'EFBIG' or 'Errno 27' -- so the
    # original pattern silently missed every one of them.
    local pat='IOError while writing|too large|EFBIG|Errno 27|Could not download|out of disk space'
    if grep -qiE "$pat" "$logf"; then
        { printf '### %s\n' "$key"
          grep -iE "$pat" "$logf"
          printf '\n'; } >> "$FAILURES"
        warn "asset(s) could not be written — see 'report'"
    fi
    [ "$ok" = 1 ] || return 1
    return 0
}

# _upload_batch — relies on bash's dynamic scoping to see the caller's locals.
_upload_batch() {
    [ "${#batch[@]}" -gt 0 ] || return 0
    if stopping; then warn "interrupted — not starting another batch"; failed=1; batch=(); return 0; fi
    local rc=0
    if [ -n "$album" ]; then
        immich upload --concurrency "$IMMICH_CONC" -A "$album" "${batch[@]}" 2>&1 | tee -a "$logf" || rc=$?
    else
        immich upload --concurrency "$IMMICH_CONC" "${batch[@]}" 2>&1 | tee -a "$logf" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        warn "batch of ${#batch[@]} failed (exit $rc) — its files are kept for retry"
        failed=1
    else
        # Deliberately do NOT delete the batch here. Files stay until the whole
        # window succeeds, so an interrupted window resumes without
        # re-downloading anything: icloudpd skips files already present, and
        # immich skips them by checksum. Re-hashing locally is far cheaper than
        # re-fetching from iCloud, especially over a VPN.
        sent=$(( sent + ${#batch[@]} ))
        printf '   %d/%d uploaded\n' "$sent" "$total"
    fi
    batch=()
    return 0
}

# upload_and_clear <dir> [album] [keep]
# Uploads in batches; only removes the staging directory if everything landed.
#   keep=keep  upload but do not delete the staging copy. Used when the download
#              was incomplete: the retry then fetches only the remainder, since
#              icloudpd skips files already present.
upload_and_clear() {
    local dir="$1" album="${2:-}" keep="${3:-}"
    [ -d "$dir" ] || { warn "no such dir, nothing to upload: $dir"; return 0; }
    strip_apple_cruft "$dir"

    local list="$WORK/filelist.$$"
    find "$dir" -type f ! -name '._*' ! -name '.DS_Store' > "$list"
    local total; total=$(grep -c . "$list" || true)
    if [ "${total:-0}" -eq 0 ]; then
        warn "no uploadable files in $dir"; rm -f "$list"; rm -rf "$dir"; return 0
    fi

    local logf="$LOGS/upload_$(printf '%s' "${album:-orphans}" | tr '/ :' '___').log"
    : > "$logf"
    log "uploading $total file(s) in batches of $BATCH_FILES ${album:+(album: $album)}"

    local -a batch=(); local sent=0 failed=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        batch+=("$f")
        [ "${#batch[@]}" -ge "$BATCH_FILES" ] && _upload_batch
    done < "$list"
    _upload_batch
    rm -f "$list"

    grep -iE 'found|uploaded|duplicat|error|fail' "$logf" | tail -4 | sed 's/^/   | /' || true

    # immich exits 0 after "No files found, exiting". With files demonstrably
    # present that means it could not match the path -- usually a glob
    # metacharacter in the name. Never treat that as success.
    if grep -qi 'no files found' "$logf"; then
        warn "immich matched no files although $total were present — path problem"
        return 1
    fi
    if [ "$failed" -ne 0 ] || [ "$sent" -lt "$total" ]; then
        warn "$sent/$total uploaded — keeping $dir for retry"
        return 1
    fi
    if [ "$keep" = keep ]; then
        log "$sent/$total uploaded; staging kept so the retry fetches only the rest"
        return 1
    fi
    rm -rf "$dir"
    return 0
}

# macOS writes AppleDouble sidecars (._name) whenever it cannot store extended
# attributes natively -- which is the case on FAT32, i.e. the staging disk. They
# are 4 KB binary metadata blobs, one per real file, so they double the apparent
# file count and immich would happily try to upload every one of them. Also
# clears .DS_Store and Spotlight droppings.
strip_apple_cruft() {
    local dir="$1" n=0
    n=$(find "$dir" \( -name '._*' -o -name '.DS_Store' -o -name '.Spotlight-V100' \
        -o -name '.fseventsd' -o -name '.TemporaryItems' \) -print 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
        find "$dir" \( -name '._*' -o -name '.DS_Store' -o -name '.Spotlight-V100' \
            -o -name '.fseventsd' -o -name '.TemporaryItems' \) -exec rm -rf {} + 2>/dev/null || true
        echo "   removed $n macOS sidecar file(s) — FAT32 cannot hold xattrs natively"
    fi
    return 0
}

# _stub_batch — upload one batch, then truncate its files to zero bytes.
#
# A 0-byte file still counts as "already downloaded" to icloudpd under
# --file-match-policy name-id7 (verified 2026-09-08), so the stub is a permanent
# marker. That gives resume for free: a later run skips it without re-fetching,
# and our own file list ignores empty files so nothing is re-hashed either.
_stub_batch() {
    [ "${#batch[@]}" -gt 0 ] || return 0
    if stopping; then warn "interrupted — not starting another batch"; failed=1; batch=(); return 0; fi
    local rc=0
    immich upload --concurrency "$IMMICH_CONC" "${batch[@]}" 2>&1 | tee -a "$logf" || rc=$?
    if grep -qi 'no files found' "$logf"; then
        warn "immich matched no files — path problem, not truncating"; failed=1; batch=(); return 0
    fi
    if [ "$rc" -ne 0 ]; then
        warn "batch of ${#batch[@]} failed (exit $rc) — files kept at full size for retry"
        failed=1
    else
        local f
        for f in "${batch[@]}"; do : > "$f"; done   # truncate, never delete
        sent=$(( sent + ${#batch[@]} ))
        printf '   %d/%d uploaded (%s GB free)\n' "$sent" "$total" "$(free_gb)"
    fi
    batch=()
    return 0
}

# upload_and_stub <dir>
# For the catch-all pass: uploads every non-empty file under $dir, truncating as
# it goes. The staging tree is NEVER deleted -- the stubs are the record of what
# has been imported, and they are what make the walk skip them next time.
upload_and_stub() {
    local dir="$1"
    [ -d "$dir" ] || { warn "no such dir: $dir"; return 0; }
    strip_apple_cruft "$dir"

    local list="$WORK/filelist.$$"
    # size +0 excludes the stubs from previous runs: already imported, nothing
    # to re-hash, nothing to re-send.
    find "$dir" -type f -size +0 ! -name '._*' ! -name '.DS_Store' > "$list"
    local total; total=$(grep -c . "$list" || true)
    if [ "${total:-0}" -eq 0 ]; then
        log "nothing new to upload under $dir"; rm -f "$list"; return 0
    fi

    local logf="$LOGS/upload_stream.log"
    : > "$logf"
    log "uploading $total new file(s) in batches of $BATCH_FILES"
    local -a batch=(); local sent=0 failed=0 f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        batch+=("$f")
        [ "${#batch[@]}" -ge "$BATCH_FILES" ] && _stub_batch
    done < "$list"
    _stub_batch
    rm -f "$list"
    grep -iE 'found|uploaded|duplicat|error|fail' "$logf" | tail -4 | sed 's/^/   | /' || true
    [ "$failed" -eq 0 ] && [ "$sent" -ge "$total" ]
}

# Files that cannot land on a FAT32 branch. Report rather than fail silently.
warn_oversize() {
    local dir="$1" big
    big=$(find "$dir" -type f -size +4G 2>/dev/null || true)
    [ -n "$big" ] && { warn "these exceed FAT32's 4 GiB per-file limit and will fail to upload:"; printf '%s\n' "$big" >&2; }
    return 0
}

# do_album <name> [count] — download one whole album and upload it tagged.
do_album() {
    local a="$1" n="${2:-?}"
    local dir="$STAGE/albums/$(slug "$a")"
    log "album: $a  ($n assets)"
    local dlok=0
    download "album:$a" --album "$a" --directory "$dir" \
        --folder-structure none "${DL[@]}" || dlok=1
    warn_oversize "$dir"
    # Journal as done only when the download was complete AND the upload
    # succeeded. A partial download that uploads cleanly is not success.
    if [ "$dlok" -ne 0 ]; then
        upload_and_clear "$dir" "$a" keep || true
        warn "NOT marking '$a' done — download was incomplete"
    elif upload_and_clear "$dir" "$a"; then
        mark_done "album:$a"
    else
        warn "NOT marking '$a' done — re-run to retry it"
    fi
}

# One named album, ignoring the done-marker. For validating the pipeline before
# committing to 51 albums, and for retrying one that failed.
cmd_album() {
    local a="${1:-}"
    [ -n "$a" ] || die "usage: $(basename "$0") album \"<album name>\""
    grep -qxF "$a" "$ALBUMS" 2>/dev/null || warn "'$a' is not in $ALBUMS — continuing anyway"
    do_album "$a"
}

cmd_login() {
    log "authenticating $ICLOUD_USER (cookies: $COOKIES)"
    "${ICD[@]}" --auth-only
    log "done — session persists until Apple's trust token expires (weeks)"
}

# The two things the reference docs do not state. Verify, don't assume.
cmd_preflight() {
    command -v icloudpd >/dev/null || die "icloudpd not installed"
    command -v immich   >/dev/null || die "immich CLI not installed"
    [ -d "$STAGE" ] || die "staging dir does not exist: $STAGE"
    log "staging: $STAGE ($(free_gb) GB free)"
    if [ "$STAGE_FAT" = 1 ]; then
        echo "   filesystem: FAT — batches of $BATCH_FILES, sidecars stripped,"
        echo "   and files over 4 GiB will fail at download (intentional: the"
        echo "   pool is FAT32, so they could never be stored anyway)."
    else
        echo "   filesystem: non-FAT — batches of $BATCH_FILES, no 4 GiB limit."
        echo "   NOTE: oversized files will download here and fail at UPLOAD."
    fi

    log "does --folder-structure none work?"
    if icloudpd --help 2>&1 | grep -q -- '--folder-structure'; then
        if "${ICDQ[@]}" --directory /tmp/icd-probe --folder-structure none \
             --recent 1 --only-print-filenames >/dev/null 2>&1; then
            echo "   yes"
        else
            warn "no — edit FLAT below to use '{:%Y}' instead of 'none'"
        fi
    fi

    # Probe against a REAL album, not a smart one. "Time-lapse" has a single
    # asset, which makes every probe below meaningless.
    local a="${PROBE_ALBUM:-}"
    [ -n "$a" ] || while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        [[ "$cand" =~ $SKIP_ALBUMS_RE ]] && continue
        a="$cand"; break
    done < "$ALBUMS"
    [ -n "$a" ] || { warn "no non-smart album found; run 'albums' first"; return 0; }
    local n_probe
    n_probe=$("${ICDQ[@]}" --album "$a" --directory /tmp/icd-probe \
                --only-print-filenames | strip_logs | wc -l | tr -d ' ')
    log "probe album: '$a' ($n_probe assets)"
    [ "$n_probe" -gt 1 ] || warn "that album has $n_probe asset(s) — probes below may be inconclusive"

    log "can --album be combined with the date filters?"
    # Deliberately span everything: a failure then means the flags do not
    # compose, not merely that the window was empty.
    local out rc=0
    out=$("${ICDQ[@]}" --album "$a" --directory /tmp/icd-probe \
            --skip-created-before 2000-01-01 --skip-created-after 2030-01-01 \
            --only-print-filenames 2>&1) || rc=$?
    local n_win; n_win=$(printf '%s\n' "$out" | strip_logs | grep -c . || true)
    if [ "$rc" -eq 0 ] && [ "$n_win" -gt 0 ]; then
        echo "   yes — $n_win asset(s) through a 2000..2030 window; per-year splitting works"
    else
        warn "no (exit $rc, $n_win assets). icloudpd said:"
        printf '%s\n' "$out" | tail -8 | sed 's/^/      /' >&2
    fi

    # icloudpd downloads a Live Photo's video component as a SEPARATE file, and
    # the Immich CLI does not pair them (only the mobile app does). Uploaded via
    # CLI you therefore get the still plus a standalone ~3s clip as two assets.
    # The docs do not say whether --skip-live-photos drops only the .MOV or the
    # still too, so measure it. No downloads: --only-print-filenames.
    log "what does --skip-live-photos actually drop?"
    "${ICDQ[@]}" --album "$a" --directory /tmp/icd-probe --only-print-filenames \
        | strip_logs | sed '/^$/d' | sort > "$WORK/lp-with.txt"
    "${ICDQ[@]}" --album "$a" --directory /tmp/icd-probe --skip-live-photos \
        --only-print-filenames | strip_logs | sed '/^$/d' | sort > "$WORK/lp-without.txt"
    local n_with n_without movs others
    n_with=$(wc -l < "$WORK/lp-with.txt" | tr -d ' ')
    n_without=$(wc -l < "$WORK/lp-without.txt" | tr -d ' ')
    comm -23 "$WORK/lp-with.txt" "$WORK/lp-without.txt" > "$WORK/lp-dropped.txt" || true
    # Count from the file, never from a variable: an empty $() collapses to "",
    # and printf '%s\n' "" emits one blank line that grep -vc counts as a hit.
    movs=$(grep -ci '\.mov$'  "$WORK/lp-dropped.txt" || true)
    others=$(grep -vci '\.mov$' "$WORK/lp-dropped.txt" || true)
    printf '   %s assets, %s with --skip-live-photos, %s dropped\n' \
        "$n_with" "$n_without" "$(wc -l < "$WORK/lp-dropped.txt" | tr -d ' ')"
    printf '   of those dropped: %s .MOV, %s non-.MOV\n' "$movs" "$others"
    [ -s "$WORK/lp-dropped.txt" ] && { echo "   sample:"; head -5 "$WORK/lp-dropped.txt" | sed 's/^/      /'; }
    if [ "$others" -gt 0 ]; then
        warn "it drops non-.MOV files too — inspect $WORK/lp-dropped.txt before using SKIP_LIVE=1"
    elif [ "$movs" -gt 0 ]; then
        echo "   safe: drops only the video half. Use SKIP_LIVE=1."
    else
        echo "   nothing dropped — no Live Photos in '$a'. Probe a different album:"
        echo "      PROBE_ALBUM='Japan' ./$(basename "$0") preflight"
    fi
}

cmd_albums() {
    log "listing albums"
    # --list-albums prints log lines and then a literal "Albums:" header before
    # the names. Take only what follows the header; fall back to pattern-based
    # log stripping if a future version drops the header.
    "${ICDQ[@]}" --list-albums | awk '/^Albums:$/ {seen=1; next} seen' \
        | sed '/^[[:space:]]*$/d' > "$ALBUMS"
    if [ ! -s "$ALBUMS" ]; then
        warn "no 'Albums:' header found — falling back to log-pattern filtering"
        "${ICDQ[@]}" --list-albums | strip_logs \
            | sed '/^Albums:$/d; /^[[:space:]]*$/d' > "$ALBUMS"
    fi
    wc -l < "$ALBUMS" | xargs printf '%s album(s) -> '; echo "$ALBUMS"
}

cmd_counts() {
    [ -s "$ALBUMS" ] || cmd_albums
    log "counting assets per album (no downloads; this takes a while)"
    [ "$SKIP_LIVE" = 1 ] && echo "   SKIP_LIVE=1: counting stills only, excluding Live Photo .MOV halves"
    : > "$COUNTS"
    local FAILED_ALBUMS=0
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        if [[ "$a" =~ $SKIP_ALBUMS_RE ]]; then
            printf '   skip (system album): %s\n' "$a"; continue
        fi
        # --directory is REQUIRED even with --only-print-filenames; without it
        # icloudpd errors and every album silently counts 0, which would
        # classify the whole library as "small" and download nothing.
        #
        # Count with the SAME download options that will actually be used, or
        # Live Photo .MOV halves inflate the count and albums get misclassified
        # against SMALL_MAX. Here roughly half of all files are .MOV halves.
        local n out rc=0
        out=$("${ICDQ[@]}" --album "$a" --directory "$WORK/probe" \
                --only-print-filenames "${DL[@]}" 2>&1) || rc=$?
        n=$(printf '%s\n' "$out" | strip_logs | grep -c . ) || n=0
        if [ "$rc" -ne 0 ]; then
            warn "icloudpd failed on album '$a' (exit $rc):"
            printf '%s\n' "$out" | tail -4 | sed 's/^/      /' >&2
            FAILED_ALBUMS=$((FAILED_ALBUMS+1))
            continue
        fi
        printf '%s\t%s\n' "$n" "$a" >> "$COUNTS"
        printf '   %6s  %s\n' "$n" "$a"
    done < "$ALBUMS"
    sort -rn -o "$COUNTS" "$COUNTS"
    log "counts -> $COUNTS"
    awk -F'\t' -v m="$SMALL_MAX" '{ if ($1+0 >= m) b++; else s++ } END {
        printf "   %d large (>= %d), %d small\n", b, m, s }' "$COUNTS"
    local total; total=$(awk -F'\t' '{t+=$1} END {print t+0}' "$COUNTS")
    printf '   %s assets across %s album(s)\n' "$total" "$(wc -l < "$COUNTS" | tr -d ' ')"
    if [ "$FAILED_ALBUMS" -gt 0 ]; then
        warn "$FAILED_ALBUMS album(s) failed to enumerate — do not proceed until resolved"
    elif [ "$total" -eq 0 ]; then
        warn "every album counted 0 — that is almost certainly a bug, not an empty library"
    fi
}

# Small albums: stage several at once, upload as a batch, free the disk, repeat.
cmd_small() {
    [ -s "$COUNTS" ] || die "run 'counts' first"
    log "small albums (< $SMALL_MAX assets)"
    local batch=0
    while IFS=$'\t' read -r n a; do
        [ -n "${a:-}" ] || continue
        [ "$n" -lt "$SMALL_MAX" ] || continue
        is_done "album:$a" && { echo "   already done: $a"; continue; }
        stopping && { log "stopped — completed albums are journalled"; return 0; }

        if [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; then
            log "free space below ${MIN_FREE_GB} GB — flushing batch of $batch album(s)"
            batch=0
        fi

        do_album "$a" "$n"
        batch=$((batch+1))
    done < "$COUNTS"
    log "small albums complete"
}

# Large albums: one year at a time so the staging disk never fills.
cmd_big() {
    [ -s "$COUNTS" ] || die "run 'counts' first"
    derive_years
    log "large albums (>= $SMALL_MAX assets), per year"
    while IFS=$'\t' read -r n a; do
        [ -n "${a:-}" ] || continue
        [ "$n" -ge "$SMALL_MAX" ] || continue
        for y in $(seq "$YEAR_FROM" "$YEAR_TO"); do
            is_done "album:$a:$y" && continue
            stopping && { resume_hint; return 0; }
            budget_spent && { resume_hint; return 0; }
            local dir="$STAGE/albums/$(slug "$a")/$y"
            log "album: $a  year: $y"
            local dlok=0
            download "album:$a:$y" --album "$a" --directory "$dir" \
                --folder-structure none "${DL[@]}" \
                --skip-created-before "${y}-01-01" \
                --skip-created-after  "$((y+1))-01-01" || dlok=1
            warn_oversize "$dir"
            if [ "$dlok" -ne 0 ]; then
                upload_and_clear "$dir" "$a" keep || true
                warn "NOT marking '$a' $y done — download was incomplete"
            elif upload_and_clear "$dir" "$a"; then mark_done "album:$a:$y"
            else warn "NOT marking '$a' $y done — re-run to retry"; fi
            WINDOWS_DONE=$((WINDOWS_DONE+1))
        done
    done < "$COUNTS"
    log "large albums complete"
}

# Catch-all: assets in no album. Run LAST — see the note in the README.
#
# Driven by the manifest from 'plan' rather than by a fixed calendar. Months with
# no assets are never visited at all, and sparse months are merged into a single
# window up to WINDOW_MAX assets. On a library whose early years hold a handful
# of photos a month, that collapses 228 invocations into a few dozen -- and each
# invocation costs a full walk of the asset list, so it is the dominant cost.
cmd_orphans() {
    [ -s "$MANIFEST" ] || die "run 'plan' first — it builds the month census this pass needs"
    derive_years

    # WINDOW_MAX decides where windows begin and end, and window keys encode
    # those boundaries ("orphans:1985-11..2013-04"). Change it mid-job and every
    # key changes, so done.txt stops matching and completed work looks unstarted.
    # Pin it on first use and refuse to run with a different value.
    local pin="$WORK/window_max"
    if [ -f "$pin" ]; then
        local was; was=$(cat "$pin")
        if [ "$was" != "$WINDOW_MAX" ]; then
            warn "this job was started with WINDOW_MAX=$was, you passed $WINDOW_MAX"
            warn "window boundaries would change and done.txt would stop matching"
            die  "use WINDOW_MAX=$was, or delete $pin and $DONE's orphans: lines to re-plan"
        fi
    else
        printf '%s\n' "$WINDOW_MAX" > "$pin"
        log "WINDOW_MAX pinned at $WINDOW_MAX for this job"
    fi
    log "year range: $YEAR_FROM..$YEAR_TO"

    # Never drop assets quietly. If the range excludes any, say so and how many.
    local excl
    excl=$(awk -F'\t' -v lo="$YEAR_FROM" -v hi="$YEAR_TO" \
        '{split($1,d,"-"); y=d[1]+0; if (y<lo||y>hi) n+=$2} END {print n+0}' "$MANIFEST")
    if [ "$excl" -gt 0 ]; then
        warn "$excl asset(s) fall outside $YEAR_FROM..$YEAR_TO and will NOT be uploaded"
        awk -F'\t' -v lo="$YEAR_FROM" -v hi="$YEAR_TO" \
            '{split($1,d,"-"); y=d[1]+0; if (y<lo||y>hi) printf "      %s  %s\n", $1, $2}' "$MANIFEST" >&2
        warn "unset YEAR_FROM/YEAR_TO to cover the whole manifest"
    fi

    local plan="$WORK/windows.tsv"
    awk -F'\t' -v lo="$YEAR_FROM" -v hi="$YEAR_TO" -v max="$WINDOW_MAX" '
      { split($1, d, "-"); y = d[1] + 0
        if (y < lo || y > hi) next
        rows[++n] = $1; cnt[n] = $2 + 0 }
      END {
        i = 1
        while (i <= n) {
          total = cnt[i]; j = i
          while (j + 1 <= n && total + cnt[j+1] <= max) { j++; total += cnt[j] }
          printf "%s\t%s\t%d\n", rows[i], rows[j], total
          i = j + 1 } }' "$MANIFEST" | sort > "$plan"

    local nwin; nwin=$(grep -c . "$plan" || true)
    log "catch-all: $nwin window(s), merging sparse months up to $WINDOW_MAX assets"

    local sk ek total key dir from to
    while IFS=$'\t' read -r sk ek total; do
        [ -n "$sk" ] || continue
        key="orphans:${sk}..${ek}"
        is_done "$key" && { echo "   already done: $key  (~$total)"; continue; }
        stopping    && { resume_hint; return 0; }
        budget_spent && { resume_hint; return 0; }
        if [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; then
            die "only $(free_gb) GB free on $STAGE — free space and re-run (progress is kept)"
        fi

        from="${sk}-01"
        # 10# so a leading zero is not read as octal
        to=$(next_month "${ek%%-*}" "$((10#${ek##*-}))")

        # ONE shared tree for every window. icloudpd looks for
        # <dir>/<YYYY>/<MM>/<name>, so stubs left by earlier windows are found
        # and skipped. Per-window directories would hide them. The date
        # subfolders also keep each FAT32 directory to ~1300 entries rather than
        # one directory of 248k, which FAT32 scans linearly.
        dir="$STAGE/all"
        mkdir -p "$dir"

        log "$key  ~$total asset(s)  [$from .. $to)"
        local dlok=0
        download "$key" --directory "$dir" --folder-structure '{:%Y/%m}' "${DL[@]}" \
            --file-match-policy name-id7 \
            --skip-created-before "$from" --skip-created-after "$to" || dlok=1
        if stopping; then
            warn "interrupted mid-download — uploading what arrived, then stopping"
            upload_and_stub "$dir" || true
            resume_hint; return 0
        fi
        warn_oversize "$dir"
        if upload_and_stub "$dir"; then
            if [ "$dlok" -ne 0 ]; then
                warn "NOT marking $key done — download was incomplete (~$total expected)"
            else
                mark_done "$key"
            fi
        else
            warn "NOT marking $key done — upload incomplete, re-run to retry"
        fi
        WINDOWS_DONE=$((WINDOWS_DONE+1))
    done < "$plan"
    log "catch-all complete"
}

count_stubs()   { find "$1" -type f -size 0  ! -name '._*' 2>/dev/null | wc -l | tr -d ' '; }
count_pending() { find "$1" -type f -size +0 ! -name '._*' 2>/dev/null | wc -l | tr -d ' '; }

# cmd_sync — import the whole library with no date filters.
#
# Why no windows: every date-filtered invocation walks the entire asset list
# client-side, skipping what it will not download, at ~38 assets/sec. For this
# library that is ~107 minutes of pure walking per window. And icloudpd's iCloud
# session dies about two hours into the process (observed twice: 2h00m and
# 2h09m, at 386 and 1512 downloads respectively -- so it is elapsed time, not
# volume). The walk therefore consumed almost the whole session lifetime and
# left ~10 minutes of useful downloading per attempt.
#
# Unfiltered, there is nothing to skip: every asset walked is an asset
# downloaded, so work starts immediately. Each pass runs until the session
# expires, then the next pass resumes -- zero-byte stubs make icloudpd skip what
# is already imported. The only growing cost is walking past those stubs.
cmd_sync() {
    local dir="$STAGE/all"
    mkdir -p "$dir"
    local pass=0 barren=0 total_lib
    total_lib=$(awk -F'\t' '{t+=$2} END {print t+0}' "$MANIFEST" 2>/dev/null)
    [ "${total_lib:-0}" -gt 0 ] || total_lib="?"

    log "sync: unfiltered passes until icloudpd completes cleanly"
    printf '   staging: %s\n   imported so far: %s of %s\n' \
        "$dir" "$(count_stubs "$dir")" "$total_lib"

    while :; do
        stopping     && { log "stopped by request"; break; }
        budget_spent && break
        pass=$((pass+1))

        local before after gained dlok=0
        before=$(count_stubs "$dir")

        local pend; pend=$(count_pending "$dir")
        if [ "$pend" -gt 0 ]; then
            log "pass $pass: $pend file(s) already staged from a previous run — uploading first"
            upload_and_stub "$dir" || warn "could not upload all of the backlog"
        fi

        log "pass $pass: icloudpd (unfiltered; resumes from $before stub(s))"
        download "sync-pass-$pass" --directory "$dir" \
            --folder-structure '{:%Y/%m}' "${DL[@]}" \
            --file-match-policy name-id7 || dlok=1

        warn_oversize "$dir"
        upload_and_stub "$dir" || warn "pass $pass: upload incomplete, files kept"

        after=$(count_stubs "$dir")
        gained=$(( after - before ))
        log "pass $pass: +$gained imported (total $after of $total_lib)"

        if [ "$dlok" -eq 0 ]; then
            log "icloudpd exited cleanly — the library is fully imported"
            break
        fi

        # A pass that imports nothing means something is wrong (auth, network,
        # a permanent API error), not a session timeout. Do not spin all night.
        if [ "$gained" -le 0 ]; then
            barren=$((barren+1))
            warn "pass $pass imported nothing ($barren consecutive)"
            if [ "$barren" -ge 3 ]; then
                warn "three passes with no progress — stopping rather than looping"
                warn "check the newest log in $LOGS, and try DEBUG_DL=1 for the real error"
                return 1
            fi
            log "waiting 120s before retrying"
            sleep 120
        else
            barren=0
        fi
    done
    log "sync finished: $(count_stubs "$dir") imported, $(count_pending "$dir") still staged"
}

# Every failure mode hit during this migration looked like success: log lines
# parsed as album names, a missing --directory making every count 0, AppleDouble
# sidecars doubling file counts, a glob metacharacter making immich skip 178
# files while exiting 0. The only reliable check is to ask the server what it
# actually holds. --fix un-marks anything that fell short so a re-run retries it.
cmd_verify() {
    [ -s "$COUNTS" ] || die "run 'counts' first"
    local fix=0; [ "${1:-}" = "--fix" ] && fix=1
    FIX="$fix" DONE_F="$DONE" COUNTS_F="$COUNTS" python3 - <<'PY'
import json, os, re, sys, urllib.request, collections
auth = os.path.expanduser("~/.config/immich/auth.yml")
t = open(auth).read()
url = re.search(r"^url:\s*(\S+)", t, re.M).group(1).strip("\"'").rstrip('/')
key = re.search(r"^key:\s*(\S+)", t, re.M).group(1).strip("\"'")
al = json.load(urllib.request.urlopen(
        urllib.request.Request(url + "/albums", headers={"x-api-key": key}), timeout=60))
srv = collections.defaultdict(list)
for a in al:
    srv[a["albumName"]].append(a.get("assetCount", 0))

expect = {}
for line in open(os.environ["COUNTS_F"]):
    n, name = line.rstrip("\n").split("\t", 1)
    expect[name] = int(n)

done_path = os.environ["DONE_F"]
done = [l.rstrip("\n") for l in open(done_path)]
bad = []
print(f"{'status':10} {'expect':>7} {'server':>20}  album")
for entry in done:
    if not entry.startswith("album:"):
        continue
    name = entry[len("album:"):].split(":")[0]
    exp = expect.get(name)
    got = sorted(srv.get(name, []), reverse=True)
    if exp is None:
        print(f"{'NO COUNT':10} {'?':>7} {str(got):>20}  {name!r}"); continue
    if got and max(got) >= exp:
        print(f"{'OK':10} {exp:>7} {str(got):>20}  {name!r}")
    else:
        print(f"{'SHORT':10} {exp:>7} {str(got):>20}  {name!r}")
        bad.append(entry)

print(f"\n{len(bad)} album(s) marked done but short on the server")
if bad and os.environ["FIX"] == "1":
    keep = [l for l in done if l not in bad]
    open(done_path, "w").write("".join(l + "\n" for l in keep))
    print("un-marked:"); [print("  " + b) for b in bad]
    print("re-run 'small' / 'big' to retry them")
elif bad:
    print("re-run with --fix to un-mark them")
PY
}

# One enumeration of the whole library, recording each asset's year-month.
#
# Every date-filtered invocation walks the entire asset list and skips whatever
# falls outside its window. With 228 month windows over ~275k assets that is
# ~62M skip decisions and hours of enumeration before anything downloads.
#
# --folder-structure '{:%Y/%m}' makes --only-print-filenames emit paths that
# carry the date, so a single pass yields a complete per-month census. 'orphans'
# then skips empty months outright and merges sparse ones, cutting the number of
# invocations by roughly an order of magnitude.
cmd_plan() {
    log "enumerating the whole library once (no downloads; slow, but only once)"
    local raw="$WORK/plan-paths.txt"
    "${ICDQ[@]}" --directory "$WORK/probe" --folder-structure '{:%Y/%m}' \
        --only-print-filenames "${DL[@]}" | strip_logs > "$raw" || true
    local n; n=$(grep -c . "$raw" || true)
    [ "${n:-0}" -gt 0 ] || die "enumeration produced nothing — check auth and try 'preflight'"

    # .../YYYY/MM/file -> YYYY-MM
    sed -E 's#.*/([0-9]{4})/([0-9]{2})/[^/]+$#\1-\2#' "$raw" \
        | grep -E '^[0-9]{4}-[0-9]{2}$' | sort | uniq -c \
        | awk '{printf "%s\t%s\n", $2, $1}' > "$MANIFEST"

    log "manifest -> $MANIFEST"
    printf '   %s assets across %s month(s) with content\n' \
        "$n" "$(wc -l < "$MANIFEST" | tr -d ' ')"
    echo
    awk -F'\t' '{split($1,d,"-"); y[d[1]]+=$2} END {for (k in y) printf "   %s  %6d\n", k, y[k]}' \
        "$MANIFEST" | sort
    echo
    awk -F'\t' -v m="$WINDOW_MAX" '$2+0 > m {c++} END {printf "   %d month(s) exceed WINDOW_MAX=%d and will run alone\n", c+0, m}' "$MANIFEST"
}

cmd_report() {
    log "progress"
    printf '   windows completed: %s\n' "$(wc -l < "$DONE" | tr -d ' ')"
    derive_years
    local total; total=$(grep -c . "$WORK/windows.tsv" 2>/dev/null || echo 0)
    local orph;  orph=$(grep -c '^orphans:' "$DONE" || true)
    printf '   catch-all: %s / %s window(s) (%s%%)\n' \
        "${orph:-0}" "$total" "$(( ${orph:-0} * 100 / (total>0?total:1) ))"
    if [ -s "$FAILURES" ]; then
        log "assets that could NOT be downloaded (over FAT32's 4 GiB limit)"
        cat "$FAILURES"
        printf '\nThese are gaps in the library. Options: put them on an exFAT/ext4\n'
        printf 'branch, transcode them smaller, or copy them across by hand.\n'
    else
        log "no oversized failures recorded"
    fi
}

case "${1:-}" in
    login)     cmd_login ;;
    report)    cmd_report ;;
    plan)      cmd_plan ;;
    verify)    cmd_verify "${2:-}" ;;
    album)     cmd_album "${2:-}" ;;
    preflight) cmd_preflight ;;
    albums)    cmd_albums ;;
    counts)    cmd_counts ;;
    small)     cmd_small ;;
    big)       cmd_big ;;
    orphans)   cmd_orphans ;;
    sync)      cmd_sync ;;
    *) printf 'unknown command: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
