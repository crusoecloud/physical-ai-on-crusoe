#!/usr/bin/env python3
"""Empty a Crusoe Object Storage bucket, including all object versions.

Crusoe buckets live behind a location-scoped S3 endpoint and are reachable
only from VMs/pods in the bucket's own location (docs: "All S3 operations
are performed directly from your Crusoe Cloud VMs"). Versioning is always on
for buckets this skill creates, so a purge must delete every object VERSION
and every delete MARKER — plain object deletes leave noncurrent versions
that keep `buckets delete` failing with "Bucket ... is not empty".

Runs inside the cluster — a python:3.12-slim pod on a node-pool VM in the
bucket's location (the only in-location compute this skill uses) — with the
credentials supplied via env or an s3-keys-style mount.

Usage: empty_bucket.py BUCKET_NAME LOCATION
Reads credentials from (in order): CRUSOE_ACCESS_KEY_ID/CRUSOE_SECRET_KEY
env vars, then /root/.s3keys/{access_key_id,access_key} (the OSMO s3-keys
mount shape), then ~/.crusoe/config (single-quoted; the CLI's own store).

Exit 0 when the bucket holds zero versions and zero markers — then the
AGENT completes the deletion with `crusoe storage buckets delete <name>`
(the CLI/control plane). This script never deletes the bucket itself:
S3 credentials manage objects only, and an S3-level delete_bucket gets
"Access Denied". Exit 1 with a clear message
on any failure. Never prints credentials.
"""
import os
import re
import sys


def read_credentials():
    ak = os.environ.get("CRUSOE_ACCESS_KEY_ID")
    sk = os.environ.get("CRUSOE_SECRET_KEY")
    if ak and sk:
        return ak, sk, "env"
    for mount in ("/root/.s3keys", os.path.expanduser("~/.s3keys")):
        try:
            ak = open(os.path.join(mount, "access_key_id")).read().strip()
            sk = open(os.path.join(mount, "access_key")).read().strip()
            if ak and sk:
                return ak, sk, mount
        except OSError:
            continue
    try:
        raw = open(os.path.expanduser("~/.crusoe/config")).read()

        def field(name):
            # ~/.crusoe/config values are usually single-quoted, but handle all
            # three styles (same parser as scripts/check_capacities.py).
            m = re.search(rf"^{name}\s*=\s*'([^']*)'", raw, re.M) or \
                re.search(rf'^{name}\s*=\s*"([^"]*)"', raw, re.M) or \
                re.search(rf"^{name}\s*=\s*([^\s#]+)", raw, re.M)
            return m.group(1) if m else None

        ak, sk = field("access_key_id"), field("secret_key")
        if ak and sk:
            return ak, sk, "~/.crusoe/config"
    except OSError:
        pass
    print("no credentials: set CRUSOE_ACCESS_KEY_ID/CRUSOE_SECRET_KEY, or mount "
          "s3-keys at /root/.s3keys, or log in with the crusoe CLI")
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        print("usage: empty_bucket.py BUCKET_NAME LOCATION")
        sys.exit(2)
    bucket, location = sys.argv[1], sys.argv[2]
    ak, sk, source = read_credentials()

    import boto3
    from botocore.config import Config
    s3 = boto3.client(
        "s3",
        endpoint_url=f"https://object.{location}.crusoecloudcompute.com",
        aws_access_key_id=ak,
        aws_secret_access_key=sk,
        region_name=location,  # placeholder if required; path-style next
        config=Config(connect_timeout=10, read_timeout=60,
                       retries={"max_attempts": 3},
                       s3={"addressing_style": "path"}),  # virtual-host style unsupported
    )

    # Delete every version and every delete marker (versioning is always on).
    to_delete = []
    paginator = s3.get_paginator("list_object_versions")
    for page in paginator.paginate(Bucket=bucket):
        for v in page.get("Versions", []):
            to_delete.append({"Key": v["Key"], "VersionId": v["VersionId"]})
        for dm in page.get("DeleteMarkers", []):
            to_delete.append({"Key": dm["Key"], "VersionId": dm["VersionId"]})
    print(f"listing complete: {len(to_delete)} versions+markers to delete "
          f"(credentials via {source})")

    del_errors = 0
    for i in range(0, len(to_delete), 1000):
        resp = s3.delete_objects(Bucket=bucket, Delete={"Objects": to_delete[i:i + 1000]})
        for e in resp.get("Errors", []):
            del_errors += 1
            print(f"delete failed: {e['Key']}@{e['VersionId']}: {e['Code']} {e['Message']}")

    # Verify: zero versions and zero markers remain.
    remaining = 0
    for page in paginator.paginate(Bucket=bucket):
        remaining += len(page.get("Versions", [])) + len(page.get("DeleteMarkers", []))
    if remaining:
        print(f"purge incomplete: {remaining} versions+markers remain"
              + (f" ({del_errors} delete errors reported above)" if del_errors else ""))
        sys.exit(1)
    print(f"bucket {bucket} is empty (0 versions, 0 markers); "
          "'crusoe storage buckets delete' will now succeed")


if __name__ == "__main__":
    main()
