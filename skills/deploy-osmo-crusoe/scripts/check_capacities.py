#!/usr/bin/env python3
"""Crusoe capacities check (read-only) — the deploy skill's signed /v1/capacities call.

Usage: check_capacities.py LOCATION TYPE

Reads API credentials from the CRUSOE_ACCESS_KEY_ID/CRUSOE_SECRET_KEY
environment variables first, then ~/.crusoe/config (single-quoted values;
a naive [^"]* regex picks up the quotes and produces a 401 — the config
parsing below handles all three quote styles). Never prints the secret key.

Exit 0 with `quantity >= 1` (a presence flag: 0 = none, 1 = some capacity
exists); exit 1 with a clear message otherwise. `num_slices` feeds the
quota check, and multi-node stock depth is not provable from this API —
the create is the real test.

`quantity` is a capacity-presence flag (0 = none, 1 = some), NOT a slice
or node count — every L40s size reads 1; H100
read 1 after its whole IB reservation was consumed).
"""
import base64, hmac, hashlib, json, os, re, sys, urllib.request, urllib.error, datetime

def main():
    if len(sys.argv) < 3:
        print(__doc__.strip()); sys.exit(2)
    loc, typ = sys.argv[1], sys.argv[2]
    # Input allowlist (review finding, input-validation): both values are
    # interpolated into a signed API URL. Fail closed on anything outside
    # [a-z0-9-] / the known product-name shape BEFORE any URL is built —
    # a prompt-injected argument must never steer this script at another
    # endpoint (SSRF) or shape a hostile query.
    import re as _re
    if not _re.fullmatch(r"[a-z][a-z0-9-]*-[a-z][a-z0-9-]*", loc):
        print(f"check_capacities.py: invalid location {loc!r} (expected e.g. us-southcentral1-a)"); sys.exit(2)
    if not _re.fullmatch(r"[a-z0-9][a-z0-9.-]*", typ):
        print(f"check_capacities.py: invalid instance type {typ!r} (expected e.g. l40s-48gb.4x)"); sys.exit(2)
    try:
        raw = open(os.path.expanduser("~/.crusoe/config")).read()
    except FileNotFoundError:
        raw = ""   # env-only credentials; field() finds nothing and falls through

    def field(name):
        m = re.search(rf"^{name}\s*=\s*'([^']*)'", raw, re.M) or \
            re.search(rf'^{name}\s*=\s*"([^"]*)"', raw, re.M) or \
            re.search(rf"^{name}\s*=\s*([^\s]+)", raw, re.M)
        return m.group(1) if m else None

    # Credentials: env first (CRUSOE_ACCESS_KEY_ID/CRUSOE_SECRET_KEY, the
    # CLI's own override order), then ~/.crusoe/config.
    ak = os.environ.get("CRUSOE_ACCESS_KEY_ID") or field("access_key_id")
    sk = os.environ.get("CRUSOE_SECRET_KEY") or field("secret_key")
    if not ak or not sk:
        print("no API credentials: set CRUSOE_ACCESS_KEY_ID/CRUSOE_SECRET_KEY, or put them in ~/.crusoe/config")
        sys.exit(1)
    try:
        sk_b = base64.urlsafe_b64decode(sk + "=" * (-len(sk) % 4))
    except (ValueError, base64.binascii.Error) as e:
        print(f"secret_key is not valid base64url (got {len(sk)} chars): {e}")
        sys.exit(1)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    qp = f"location={loc}&product_name={typ}"
    payload = f"/v1/capacities\n{qp}\nGET\n{ts}\n"
    sig = base64.urlsafe_b64encode(
        hmac.new(sk_b, payload.encode(), hashlib.sha256).digest()
    ).decode().rstrip("=")
    req = urllib.request.Request(
        f"https://api.cloud.crusoe.ai/v1/capacities?{qp}",
        headers={"X-Crusoe-Timestamp": ts,
                 "Authorization": f"Bearer 1.0:{ak}:{sig}",
                 "User-Agent": "crusoe-osmo-skill"})
    try:
        items = json.load(urllib.request.urlopen(req, timeout=20)).get("items", [])
    except json.JSONDecodeError as e:
        print(f"/v1/capacities returned a non-JSON body: {e}")
        sys.exit(1)
    except urllib.error.HTTPError as e:
        hint = " (signature/config problem — check the single-quoted values in ~/.crusoe/config)" if e.code == 401 else ""
        print(f"HTTP {e.code} from /v1/capacities{hint}: {e.read().decode(errors='ignore')[:200]}")
        sys.exit(1)
    except (urllib.error.URLError, OSError) as e:
        print(f"cannot reach api.cloud.crusoe.ai: {e}")
        sys.exit(1)
    seen = {}
    for i in items:                      # entries repeat: dedupe
        seen[(i["type"], i["location"])] = i
    entry = seen.get((typ, loc))
    if not entry:
        print(f"NO-ENTRY: {typ} does not appear in {loc}'s capacities (weak evidence it is not offered there)")
        sys.exit(1)
    q, s = entry["quantity"], entry["num_slices"]
    print(f"{typ} in {loc}: quantity={q} num_slices={s} quota_type={entry['quota_type']}")
    if q < 1:
        print(f"OUT-OF-STOCK: quantity={q} (no capacity for {typ} in {loc})"); sys.exit(1)

if __name__ == "__main__":
    main()
