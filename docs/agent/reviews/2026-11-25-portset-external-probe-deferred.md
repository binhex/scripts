# Deferred findings — portset.sh external-probe removal

| Field | Value |
| ----- | ----- |
| Branch | `master` |
| Base ref | `HEAD` (`1d200a9 fix aur script, minor change to portset`) |
| Round reached | 3 of 10 (round 3 reported no gating findings) |
| Reviewer models | `opencode-go/deepseek-v4.1-flash:max`, `opencode-go/glm-5.3-flash:max` |
| Why deferred | Every item below is in a file this change did not touch, so fixing it would widen the diff beyond the review scope set (`portset.sh` + three bats files). The Scope Gate was not invoked for an edit because no edit was made; these are recorded so they are not lost. |

## Findings

| Severity | Location | Description | Status |
| -------- | -------- | ----------- | ------ |
| MEDIUM | `scripts/docker/healthcheck.sh:434-461`, `:495-520` | `check_incoming_port()` still asks the same third party this change stopped trusting (`https://ifconfig.co/port/N`) and turns a `false` verdict into a container-unhealthy signal, which the watchdog answers with a container restart. The unusable/timeout branch is handled, so a false `false` is the residual risk. This is the last consumer of the removed probe. Reported by both reviewers in all three rounds. | not fixed — outside this change |
| LOW | `scripts/docker/portset.sh:871-880` | `validate_positive_integer` accepts leading-zero values, which arithmetic later reads as octal (`APP_VERIFY_INTERVAL_PASSES=010` yields 8). Pre-existing helper, newly reachable through the new knob; bounded and consistent with the other five numeric knobs. | not fixed — outside this change |
| LOW | `tests/portset_port_zero.bats`, `tests/portset_phase4.bats` | Phase 4 tests write the real `/tmp/portset_vpn_stop_intent`, `/tmp/gluetun_escalation_cooldown` and `/tmp/gluetun_escalation_attempted` instead of injecting temp paths, leaving state on the machine. No current failure: every consumer cleans up in its own setup. | not fixed — outside this change |

## Verification gap

None for this ledger's items: they were never applied, so there is nothing to re-review.
The change under review itself completed on a clean round (round 3: 0 gating,
2 low, both fixed and covered by the existing suite).
