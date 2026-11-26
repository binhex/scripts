# Residual findings — portset.sh startup VPN repair (Phase 4 removal)

| Field | Value |
| ----- | ----- |
| Branch | `master` |
| `BASE_REF` | `HEAD` (`a52ff03 remove incoming port check, too fragile`) |
| Round reached | 4 of 10 (`CIRCUIT_BREAKER_ROUNDS=10`) |
| Loop exit | User-consented plateau stop (fix-induced counts 2, then 3 — not falling) |
| Reviewer models | `opencode-go/deepseek-v4.1-flash:max`, `opencode-go/glm-5.3-flash:max` |
| Change under review | `scripts/docker/portset.sh`, `scripts/docker/healthcheck.sh`, `scripts/docker/tests/portset_app_supervision.bats`, `scripts/docker/tests/healthcheck.bats`, deleted `scripts/docker/tests/portset_phase4.bats` |
| Final tree | `bats -r tests` → 116 ok, 0 not ok; `shellcheck portset.sh healthcheck.sh` and `shellcheck tests/*.bats` → exit 0 |

## Findings (round 4 — applied, not independently re-reviewed)

| Severity | Location | Description | Status |
| -------- | -------- | ----------- | ------ |
| MEDIUM | `scripts/docker/portset.sh:327-345` | The 900 s staleness floor could still be undercut by the script's own recovery cycle while the gluetun Control Server accepts connections but stalls (`curl_with_retry` `--max-time 30` × retries × attempts makes one cycle exceed the bound), so our own marker aged into "operator stop" and runtime repair turned itself off. | applied, not independently re-reviewed — marker ownership by PID (`$(cat marker) == $$` bypasses the age check) added with tests `restart_vpn_connection treats a marker naming this process as its own at any age` |
| MEDIUM | `scripts/docker/portset.sh:1626-1628` | Help's startup grace-window estimate was stale: the in-loop VPN repair adds the Control Server's timeout per failed pass, so in the degraded mode this change targets the `exec` fallback fires roughly 3× later than documented. | applied, not independently re-reviewed — added a sentence to the `MAX_STARTUP_RETRIES` stanza; `no executable reproduction` (help prose) |
| LOW | `scripts/docker/portset.sh:42`, `:345`, `:364` | Moving the marker into `/config` (a non-sticky, app-writable volume) meant a plain `>`/`touch` could follow a symlink planted at the marker path and overwrite its target. Severity lowered from the reviewer's MEDIUM: `portset.sh` runs as `nobody` (verified live: `ps -o user` → `nobody`, `/config` → `nobody:users 775`), so no privilege boundary is crossed; defence-in-depth only. | applied, not independently re-reviewed — `-L` guard in the stopped branch, `rm -f` + `set -o noclobber` for the write; tests `restart_vpn_connection does not follow a symlinked stop-intent marker` and `restart_vpn_connection refuses a symlinked marker while the VPN is stopped` |
| LOW | `scripts/docker/tests/portset_app_supervision.bats:33-35`, `:749` | Test comments described the pre-floor staleness rule (`2×cooldown`) after production became `max(900, 2×cooldown)`. | applied, not independently re-reviewed — both comments now state the floored bound; `no executable reproduction` (comments) |

## Provenance

```text
Round 1: 0 high, 3 medium, 3 low — 6 new, 0 fix-induced
  fixes: portset.sh:659-663 + :453-476 — rejected start PUT continues through remaining attempts, startup loop re-attempts the repair — evidence: RED `Status=1 vpn_set=1 state=stopped` -> GREEN `ensure_vpn_running keeps trying after a rejected start PUT`
  fixes: portset.sh:42/313-320 — stale stop-intent marker (>2x cooldown) discarded so a runtime restart respects an operator stop — evidence: RED `Status=0 puts=1 marker=absent` -> GREEN `restart_vpn_connection refuses to start a VPN stopped long after our own stop`
  fixes: portset.sh:630-637 + show_help — comment/help now state that a hand-stopped VPN is not durable — evidence: no executable reproduction (prose)
  fixes: portset.sh:334-338 — error text names the writable-/config precondition — evidence: no executable reproduction (prose)
  fixes: tests/portset_app_supervision.bats:33-34 — stale-marker comment replaced — evidence: no executable reproduction
  fixes: tests/healthcheck.bats teardown — legacy flag cleaned even when an assertion fails — evidence: `ls /tmp/gluetun_escalation_attempted` absent after the suite

Round 2: 0 high, 2 medium, 5 low — 5 new, 2 fix-induced
  fix-induced: portset.sh:323-336 — staleness bound discarded our own retained marker (mtime never refreshed)
  fix-induced: portset.sh:480-487 — startup-loop re-attempt had no test
  fixes: portset.sh:323-345 — marker refreshed on every repair attempt — evidence: RED `Status=1 marker_age=300s` -> GREEN `restart_vpn_connection refreshes its stop-intent marker on every repair attempt`
  fixes: tests/portset_app_supervision.bats:281-309 — test drives `main`'s startup loop — evidence: mutation (retry block removed) `not ok ... repairs=1` -> GREEN `main retries the VPN repair on every failed startup pass`
  fixes: portset.sh help/comment/log nits, tests/portset_app_supervision.bats formatting — evidence: no executable reproduction

Round 3: 0 high, 1 medium, 2 low — 1 new, 2 fix-induced
  fix-induced: portset.sh:326 — 2x cooldown bound could be shorter than the retry cadence
  fix-induced: portset.sh:489-498 — final startup pass repaired before the cap check, discarding the result
  fixes: portset.sh:327-337 + :486-500 — staleness bound floored at 900s, cap check moved above the repair — evidence: RED `Discarding stale stop-intent marker (age 120s)` -> GREEN `restart_vpn_connection tolerates a repair gap longer than the cooldown`; main test updated to `repairs == 2`
  fixes: tests/portset_app_supervision.bats:512 — test retitled away from "for the startup repair" — evidence: no executable reproduction

Round 4: 0 high, 2 medium, 2 low — 1 new, 3 fix-induced
  fix-induced: portset.sh:327-345 — stalled Control Server can outlast any fixed age bound
  fix-induced: portset.sh:1626-1628 — help grace-window estimate stale after the in-loop repair
  fix-induced: tests/portset_app_supervision.bats:33-35, :749 — comments state the pre-floor rule
  new: portset.sh:42/345/364 — symlink at the marker path is followed
  fixes: see the Findings table (all applied, none re-reviewed)
```

## Verification gap

The loop stopped by user consent at the round-4 plateau, so **round 4's four fixes were never
independently re-reviewed**. Rounds 1-3 fixes were each re-reviewed by the following round and
no longer produced findings. The final tree passes the suite (116 ok) and shellcheck (exit 0),
but the new marker-ownership, symlink-guard and help-text changes rest on the author's own tests
and this ledger's evidence only.

## Deferred findings

None added by this run. Both reviewers independently pointed at the pre-existing
`check_incoming_port` dependency on `https://ifconfig.co/port/N`
(`scripts/docker/healthcheck.sh:434-461`) and the leading-zero octal reading in
`validate_positive_integer`; both are already recorded in
`docs/agent/reviews/2026-11-25-portset-external-probe-deferred.md` and were not re-deferred here.

## Related historical record

The LOW row in `2026-11-25-portset-external-probe-deferred.md` that names
`tests/portset_phase4.bats` (tests writing real `/tmp` escalation state) is obsolete: that file
and the code it exercised were deleted by this change. The ledger row is left in place as a
point-in-time record.
