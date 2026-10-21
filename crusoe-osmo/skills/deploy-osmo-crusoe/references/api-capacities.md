# api-capacities.md — the capacities and quotas API for availability checks

Part of the deploy-osmo-crusoe skill. Read [SKILL.md](../SKILL.md) first: its scope, tool-routing and secret rules apply. This file exists because L40s (and every non-InfiniBand GPU type) has no InfiniBand network to check, `crusoe compute vms types` is a global catalog with no per-location availability, and the CLI has no capacities command. The one live per-location stock surface is the Crusoe REST API — the same endpoint the `crusoe-cloud` MCP's `list_capacities` wraps.

**Scope: non-IB types only.** For InfiniBand-connected types (`-ib.`), the IB networks check (provision.md Phase 1 step e) is the gate; `/capacities` is informational only and **never stops the run for them** — its `quantity` is not the authoritative reserved-GPU signal (`quantity: 1` observed for `h100-80gb-sxm-ib.8x` in `us-southcentral1-a` while IB Network 1 showed 16 reserved GPUs).

**Use it in both modes**: `mcp+cli` mode goes through `list_capacities`/`list_project_quotas`; `cli-only` mode uses the signed calls below. All of it is read-only. Auth: the same API access key ID and secret key the CLI already holds in `~/.crusoe/config`; `CRUSOE_ACCESS_KEY_ID`/`CRUSOE_SECRET_KEY` are an honored fallback (the script checks the env vars first, then the config file). Never print the secret key, never write it to a file, and send credentials only to `api.cloud.crusoe.ai`.

## Official documentation

- API reference / signing: <https://docs.crusoecloud.com/reference/api/> — base URL `https://api.cloud.crusoe.ai`, current version `/v1`, signature version `1.0`.
- API keys: <https://docs.crusoecloud.com/identity-and-security/managing-api-keys>
- Full OpenAPI schema: <https://api.crusoecloud.com/v1/openapi.json> (needs a browser `User-Agent`; Cloudflare returns error 1010 without any UA header).
- The MCP package `@crusoeai/cloud-mcp` (v0.1.6, 48 tools, all read-only) implements the same signing; its `list_capacities` params are `{location?: string[], product_name?: string[]}`.

## Signing (the docs' algorithm, implemented and verified)

Payload = `api_version + request_path`, then the canonical query string, then the verb, then the timestamp — all `\n`-separated with a trailing `\n`. Canonical query: params sorted by name, joined with `&` (no URL-encoding beyond what the value already has; the docs' example passes values verbatim). Signature: `base64url_no_pad(hmac_sha256(payload, raw_urlsafe_b64_decode(secret_key)))`. Header: `Authorization: Bearer 1.0:<access_key_id>:<sig>` plus `X-Crusoe-Timestamp: <the same RFC3339 UTC timestamp>` and a `User-Agent` (missing UA → Cloudflare 403 error 1010, observed).

Config parsing gotcha confirmed: values are **single-quoted** in `~/.crusoe/config` (`secret_key = '...'`); a naive `[^"]*` regex picks up the quote characters and produces a 401. The script handles it.

## The script

Run as one command; it takes `LOCATION` and `TYPE` as arguments, reads credentials from the environment first (`CRUSOE_ACCESS_KEY_ID`/`CRUSOE_SECRET_KEY`), then `~/.crusoe/config`, and prints the deduplicated capacity entry. Exit 0 with `quantity >= 1` (a presence flag: `0` = none, `1` = some capacity exists — see provision.md Phase 1 step d.3); exit 1 with a clear message otherwise. `num_slices` feeds the quota check (provision.md Phase 1 step f); multi-node stock depth is not provable from this API.

```bash
SKILL_DIR="<path-to>/skills/deploy-osmo-crusoe"   # set once per shell; paths below are skill-relative
python3 "$SKILL_DIR/scripts/check_capacities.py" "$LOCATION" "$TYPE"
```

The script ([scripts/check_capacities.py](../scripts/check_capacities.py)) carries the config-quote parsing, the signing recipe and the presence-flag gate.

**`quantity` semantics:** `quantity` is a capacity-presence flag, not a unit count: `0` = none, `1` = some capacity exists. Measured: every L40s size variant (`.1x`–`.10x`) read `quantity=1` in the same location at the same moment (a slice count would differ by size), and H100 read `quantity=1` immediately after its whole IB reservation was consumed (a free-unit count would have read 0). The OpenAPI spec documents `num_slices` ("number of slices that make up the resource") but leaves `quantity` undocumented. **Gate: `quantity >= 1`** for the whole order; multi-node stock depth is not provable from this API — the create is the real test. If the semantics ever look off, cross-check one known-good location before trusting a stop decision.

## Quotas

`GET /v1/projects/{project_id}/quotas` (project UUID, not name — a name returns 400). Same signing; response items carry `type`, `programmatic_name`, `category`, `max`, `used`, `available` (all strings). Example verified response: `l40s` → `max 999 / used 0 / available 999`. Org-level quotas (`/organizations/{id}/quotas`) have no GPU entries — do not look for them there.

## What no surface can tell you (as of CLI v1.0.9, MCP 0.1.6, docs)

- A static per-location type catalog: no `/products`, `/compute/products` or `/vmTypes` endpoint exists (all 404); absence-from-capacities is the only signal, and it is weak.
- Future availability, ETA or waitlist for out-of-stock types.
- Real-time semantics beyond `quantity`; and the check is not a reservation — a create can still race.
- L40S telemetry: excluded from VM Telemetry docs by name ("all GPU instances except L40S") — irrelevant here, but do not expect VM telemetry for L40s nodes.
- `crusoe reservations list` remains forbidden (tool-routing.md).

## Source and provenance

Sources: the signing recipe from the API reference above; the response shape verified (see the quantity-semantics paragraph); MCP tool list from the `@crusoeai/cloud-mcp` 0.1.6 package source.
