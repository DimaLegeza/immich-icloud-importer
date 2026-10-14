#!/usr/bin/env python3
"""
Remove old photos and videos from iCloud.

Deletes every asset in the iCloud library taken before a cutoff date. It does
not check Immich: run it only once the import is done and looks right there.
Without --delete it only counts, and changes nothing.

Run it through icloud-migrate.sh, which supplies the account and cookie
directory and uses icloudpd's own Python:

    ./icloud-migrate.sh prune 2020-01-01             # dry run: count only
    ./icloud-migrate.sh prune 2020-01-01 --delete    # asks before deleting

Deleting moves assets to iCloud's Recently Deleted, the same as deleting on
the iPhone: recoverable there for 30 days, and still counting against the
storage plan until that album is emptied. Hidden photos, shared albums and a
Shared Library are never touched: only the main library is listed.

What Immich does not have is gone from both once Recently Deleted is emptied:
the motion part of Live Photos (the import used --skip-live-photos), edits
(it took the unedited originals), and anything over FAT32's 4 GiB limit.

Each run writes the full list to ~/.icloud-migrate/prune/, both as a TSV to
read and as a .jsonl plan, and every deleted asset is appended to deleted.tsv
there. Apple throttles bulk deletes (HTTP 503 after a few hundred): the script
then waits and retries, and if Apple keeps refusing it stops and prints a
--resume command, which deletes the rest of a saved plan without listing the
whole library again.
"""

import argparse
import datetime as dt
import json
import os
import sys
import termios
import time
import urllib.parse

from tzlocal import get_localzone

from icloudpd.base import build_filename_cleaner
from icloudpd.filename_policies import create_filename_builder
from pyicloud_ipd.base import PyiCloudService
from pyicloud_ipd.exceptions import (
    PyiCloudAPIResponseException,
    PyiCloudConnectionErrorException,
    PyiCloudServiceNotActivatedException,
    PyiCloudServiceUnavailableException,
)
from pyicloud_ipd.file_match import FileMatchPolicy
from pyicloud_ipd.item_type import AssetItemType
from pyicloud_ipd.utils import get_password_from_keyring

WORK = os.path.expanduser(os.environ.get("WORK", "~/.icloud-migrate"))
OUT = os.path.join(WORK, "prune")
DELETE_BATCH = 100   # records per CloudKit modify request
PAUSE = 5            # seconds between batches; at 1 s Apple refused after 600
BACKOFF = [30, 60, 120, 300, 600, 900]   # waits after a refusal before giving up


def delete_batch(library, batch, log):
    """Move a batch to Recently Deleted. Returns the number that succeeded."""
    url = f"{library.service_endpoint}/records/modify?{urllib.parse.urlencode(library.params)}"
    body = {
        "atomic": False,
        "desiredKeys": ["isDeleted"],
        "operations": [
            {
                "operationType": "update",
                "record": {
                    "fields": {"isDeleted": {"value": 1}},
                    "recordChangeTag": a["tag"],
                    "recordName": a["record"],
                    "recordType": "CPLAsset",
                },
            }
            for a in batch
        ],
        "zoneID": library.zone_id,
    }
    res = library.session.post(url, data=json.dumps(body), headers={"Content-type": "application/json"})
    by_name = {r.get("recordName"): r for r in res.json().get("records", [])}
    ok = 0
    for a in batch:
        r = by_name.get(a["record"])
        if r and "serverErrorCode" not in r:
            ok += 1
            log.write(f"{dt.datetime.now().isoformat(timespec='seconds')}\t{a['taken']}\t"
                      f"{a['name']}\t{a['record']}\n")
        else:
            why = f"{r.get('serverErrorCode', '')} {r.get('reason', '')}" if r else "no reply"
            print(f"\n  NOT deleted: {a['name']}: {why.strip()}")
    log.flush()
    return ok


def delete_with_backoff(library, batch, log):
    """delete_batch, waiting out Apple's refusals. None if Apple keeps refusing.

    Two kinds seen: 503 throttling after a burst, and TRY_AGAIN_LATER ("Sync
    zone CAS Op-Lock failed ... concurrent write") while the iPhone syncs the
    deletions it has just been told about. Both reject the whole request, so
    retrying the same batch is safe. The third, a dropped connection, may come
    after Apple applied the batch; the retry then reports those assets as
    NOT deleted (stale change tag) although they are gone, which a dry run
    afterwards settles.
    """
    for wait in BACKOFF + [None]:
        try:
            return delete_batch(library, batch, log)
        except (
            PyiCloudServiceUnavailableException,
            PyiCloudAPIResponseException,
            PyiCloudConnectionErrorException,
        ) as e:
            if "BAD_REQUEST" in str(e):
                raise   # the request itself is wrong; retrying cannot help
            if wait is None:
                return None
            print(f"\n  Apple refused ({str(e)[:60]}); retrying in {wait} s", flush=True)
            time.sleep(wait)


def already_deleted():
    path = os.path.join(OUT, "deleted.tsv")
    if not os.path.exists(path):
        return set()
    return {line.rstrip("\n").split("\t")[3] for line in open(path) if line.count("\t") >= 3}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("before", help="cutoff date, YYYY-MM-DD; assets taken before it (local time) go")
    ap.add_argument("--user", required=True)
    ap.add_argument("--cookies", required=True)
    ap.add_argument("--delete", action="store_true", help="actually delete (default: count only)")
    ap.add_argument("--resume", metavar="PLAN", help="delete the rest of a saved .jsonl plan, without listing")
    args = ap.parse_args()

    cutoff = dt.datetime.strptime(args.before, "%Y-%m-%d").replace(tzinfo=get_localzone())
    os.makedirs(OUT, exist_ok=True)
    stem = os.path.join(OUT, f"before-{args.before}-{dt.datetime.now():%Y%m%d-%H%M%S}")

    icloud = PyiCloudService(
        "com", args.user, lambda: get_password_from_keyring(args.user), cookie_directory=args.cookies
    )
    if icloud.requires_2fa or icloud.requires_2sa:
        sys.exit("iCloud wants a new 2FA code: run './icloud-migrate.sh login' first")
    try:
        library = icloud.photos
    except PyiCloudServiceNotActivatedException as e:
        sys.exit(f"iCloud refused: {e}. Nothing was changed; try again later.")

    if args.resume:
        gone = already_deleted()
        plan = [json.loads(line) for line in open(args.resume)]
        assert all(a["taken"] < f"{args.before}" for a in plan), "plan has assets past the cutoff"
        left = [a for a in plan if a["record"] not in gone]
        print(f"Plan {os.path.basename(args.resume)}: {len(plan)} assets, "
              f"{len(plan) - len(left)} already deleted, {len(left)} to go")
        delete_all(library, left, args, args.resume)
        return

    name_of = create_filename_builder(FileMatchPolicy.NAME_ID7, build_filename_cleaner(False))

    print(f"{args.user}: {len(library.all)} assets in the library; listing those taken before {cutoff:%Y-%m-%d}")
    plan, photos, videos = [], 0, 0
    with open(stem + ".tsv", "w") as out, open(stem + ".jsonl", "w") as js:
        # Every asset is looked at, not just up to the first one past the cutoff:
        # the query asks for ASCENDING but iCloud returns newest first, so the
        # order is not something to rely on. Nothing is deleted while listing:
        # it pages by position, and deleting would shift the positions.
        for seen, photo in enumerate(library.all, 1):
            if seen % 1000 == 0:
                print(f"\r  looked at {seen}, {len(plan)} before the cutoff", end="", flush=True)
            if photo.created >= cutoff:
                continue
            a = {
                "record": photo._asset_record["recordName"],
                "tag": photo._asset_record["recordChangeTag"],
                "name": name_of(photo),
                "taken": f"{photo.created:%Y-%m-%d %H:%M}",
            }
            plan.append(a)
            js.write(json.dumps(a) + "\n")
            if photo.item_type == AssetItemType.MOVIE:
                videos += 1
            else:
                photos += 1
            out.write(f"{a['taken']}\t{a['name']}\n")
    print()

    if not plan:
        print("Nothing taken before the cutoff.")
        return
    dates = sorted(a["taken"] for a in plan)
    print(f"{len(plan)} assets ({photos} photos, {videos} videos), "
          f"{dates[0][:10]} to {dates[-1][:10]}")
    print(f"Full list: {stem}.tsv")
    if not args.delete:
        print("\nDry run: nothing deleted. Add --delete to delete them.")
        return

    delete_all(library, plan, args, stem + ".jsonl")


def delete_all(library, plan, args, plan_path):
    # The listing can return an asset twice (34 times in 54,833 on 2026-10-11),
    # and Apple rejects a batch that names a record twice.
    plan = list({a["record"]: a for a in plan}.values())
    if not plan:
        print("Nothing left to delete.")
        return
    print(f"\nThis moves {len(plan)} assets to Recently Deleted in {args.user}'s iCloud.")
    # Keys pressed during the hour-long listing (arrow keys, on 2026-10-11) sit
    # in the terminal's input buffer and would be read as part of the answer.
    if sys.stdin.isatty():
        termios.tcflush(sys.stdin, termios.TCIFLUSH)
    if input(f"Type 'delete {len(plan)}' to go ahead: ").strip() != f"delete {len(plan)}":
        print("Not confirmed; nothing deleted.")
        return

    done = 0
    with open(os.path.join(OUT, "deleted.tsv"), "a") as log:
        for i in range(0, len(plan), DELETE_BATCH):
            ok = delete_with_backoff(library, plan[i:i + DELETE_BATCH], log)
            if ok is None:
                print(f"\nApple kept refusing; stopped after {done} of {len(plan)}. Later, run:")
                print(f"  ./icloud-migrate.sh prune {args.before} --resume {plan_path}")
                return
            done += ok
            print(f"\r  deleted {done} of {len(plan)}", end="", flush=True)
            time.sleep(PAUSE)
    print(f"\nDone: {done} moved to Recently Deleted, {len(plan) - done} not.")
    print("Recoverable there for 30 days. To free the storage now, empty Recently")
    print("Deleted in Photos on the iPhone or on icloud.com.")


if __name__ == "__main__":
    main()
