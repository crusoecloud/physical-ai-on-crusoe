# Credentials — HF token, license gate, and the storage-key credentials (Phase 1 d–f2)

Load this reference when you reach Phase 1 step d. Everything here happens **before any
workflow is submitted**: without the license acceptance and both OSMO credentials, stage
submissions fail mid-run with errors that look like cluster problems.

## d. HF token — the user provides it as an environment variable

The Cosmos and GR00T checkpoints are gated on HF. The user supplies the token as the
`HF_TOKEN` environment variable in their own shell BEFORE this step; the skill never
asks for the token in chat and never echoes it.

**Validation gate (run this first — it fails loudly without exposing the value):**

```bash
: "${HF_TOKEN:?HF_TOKEN not set - export it in your shell first (hf_...); the skill will never print it}"
# Shape checks only: length + prefix. Never echo $HF_TOKEN itself.
[ "${#HF_TOKEN}" -ge 20 ] || { echo "HF_TOKEN looks too short (${#HF_TOKEN} chars) - an HF token is ~37+"; exit 1; }
case "$HF_TOKEN" in hf_[A-Za-z0-9_-]*) : ;; *) echo "HF_TOKEN does not start with hf_ (fine-grained tokens do); refusing to register it"; exit 1;; esac
echo "HF_TOKEN present: ${#HF_TOKEN} chars, hf_ prefix OK"
```

**Registration** — the token must never appear in `osmo`'s argv (visible in
`/proc/<pid>/cmdline` to any local `ps` for the lifetime of the call) — use
`--payload-file` from the env var, the same pattern as the storage key below:

```bash
(umask 077 && printf '%s' "$HF_TOKEN" > "$WORKDIR/.hf-token" && unset HF_TOKEN) && \
SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo credential set hf-token --type GENERIC --payload-file token="$WORKDIR/.hf-token" && \
  rm -f "$WORKDIR/.hf-token"
```

(or the UI's credentials page: add a generic credential named `hf-token` with payload key
`token`). **Never ask for the token in chat, never print it, never leave it in a file** —
the snippet deletes the temp file immediately (umask-077 so no other user can read it
even in flight).

## e. License gate — hard stop until accepted

While logged in to huggingface.co with the token's account, the user must accept the
NVIDIA Open Model License on
[nvidia/Cosmos-Predict2-2B-Video2World](https://huggingface.co/nvidia/Cosmos-Predict2-2B-Video2World)
and [nvidia/GR00T-N1.5-3B](https://huggingface.co/nvidia/GR00T-N1.5-3B), plus
[meta-llama/Llama-Guard-3-8B](https://huggingface.co/meta-llama/Llama-Guard-3-8B)
(Cosmos's guardrail dependency, gated `manual`) and
[nvidia/Cosmos-Guardrail1](https://huggingface.co/nvidia/Cosmos-Guardrail1)
(a FOURTH gated repo: the aug task's startup fetches it
unconditionally - restricted-access denial in the log - but the pipeline CONTINUES with
the guardrail disabled, so acceptance is optional for stage 2a, not a hard stop).
Check from the user's machine (or any machine with the token):

```bash
huggingface-cli download nvidia/Cosmos-Predict2-2B-Video2World model-480p-10fps.pt --local-dir /tmp/liccheck
```

If it 401/403s, the license is not accepted yet: stop and tell the user which repo.

## f. Data credentials — register the user-level DATA credential (hard requirement)

The submit-side data validation runs with the **submitting user's** DATA credential;
without one, submission fails with `NoCredentialsError: Unable to locate credentials` at
`Validating WRITE access for URI output` — the deploy install's service-side storage
config does **not** cover this: submission requires a user-level DATA credential, and
the service-side storage config does not cover submit-side validation. Register it
from the storage key the deploy created (key ID visible in the Crusoe console /
`crusoe storage tokens list`; the secret never enters chat — `--payload-file` with
`key=<path-to-file>` pairs, umask-077 temp files, values from the console or the user's
own shell):

```bash
SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo credential set crusoe-s3 --type DATA \
  --payload-file access_key_id="$WORKDIR/.cred-access_key_id" access_key="$WORKDIR/.cred-access_key" \
                endpoint="$WORKDIR/.cred-endpoint" region="$WORKDIR/.cred-region" \
                override_url="$WORKDIR/.cred-override_url" addressing_style="$WORKDIR/.cred-addressing_style"
```

(each payload file holds the raw value under `$WORKDIR`, umask-077; `endpoint=s3://$BUCKET`,
`override_url=https://object.$LOCATION.crusoecloudcompute.com`,
`addressing_style=path`.) Delete the payload files immediately. `osmo credential list`
must then show the DATA credential — it auto-applies at every submit. If the user
already has one, do not create a duplicate.

## f2. Data credentials — the `s3-keys` credential the tasks mount (required by the YAMLs)

Every stage's tasks mount the storage key as files under `/root/.s3keys/` and read them
with boto3 (the sidecar is distrusted — "Testing notes" rule 1); the mount references
the credential **by name**, and the name in the YAMLs is `s3-keys`. Register it from the
same storage key (the mounted file names must be exactly `access_key_id`, `access_key`,
`override_url` — the entry scripts `read()` those; `endpoint` may be included too but is
unused by the scripts, which take the endpoint from the `override_url` value):

```bash
SSL_CERT_FILE="$WORKDIR/combined-ca-bundle.crt" REQUESTS_CA_BUNDLE="$WORKDIR/combined-ca-bundle.crt" \
  osmo credential set s3-keys --type GENERIC \
  --payload-file access_key_id="$WORKDIR/.cred-access_key_id" access_key="$WORKDIR/.cred-access_key" override_url="$WORKDIR/.cred-override_url"
```

The two credentials serve different layers: `crusoe-s3` (DATA) satisfies the submit-side
validation; `s3-keys` (GENERIC) is what the running tasks mount. Both point at the same
bucket key; both payload sets are deleted immediately. If `osmo credential list` already
shows `s3-keys`, skip — if it shows `s3-keys` without an `override_url` payload,
re-register it (the merge and finetune scripts read `override_url` from the mount).

## Safety note (stated plainly — this is a requirement, not a preference)

The mounted key is **organization-scoped** — it reaches every bucket in the Crusoe
organization, not just this run's, and every task in the chain (which runs
third-party code from PyPI, GitHub and HuggingFace as root) can read it at
`/root/.s3keys/`. Crusoe offers **no bucket-scoped key** (the platform docs state
keys work "in all buckets in all projects within your organization"), so the
compensating controls are a dedicated key and a **bounded lifetime**.

**The default — required, not recommended**: register a dedicated
workload key with an expiry:

```bash
crusoe storage tokens create --alias osmo-workload-run --expires-at <RFC3339>
```

(a week out for a short campaign), and register THAT key in both credentials
below — never the deploy key. Registering the deploy key is acceptable in
exactly one case: the user explicitly chooses to reuse it, and only after you
have shown its expiry from `crusoe storage tokens list` and it carries one —
if the key they insist on reusing has no expiry, rotate it first (delete +
recreate with `--expires-at`) or refuse the run. A dedicated key keeps
revocation cheap: after the campaign, revoke the workload key without
touching the OSMO install's credential (Phase 6's cleanup list includes the
revocation).

Check the expiry with `crusoe storage tokens list` before registering; a key
with no expiry is an org-wide credential that outlives the campaign — never
register one.
