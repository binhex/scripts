# Residual review findings — portset incoming-port recovery

| Field | Value |
| ----- | ----- |
| Repository | `/data/scripts` (branch `master`) |
| Base commit | `054cf3c make debug option stripping idempotent` (working tree uncommitted) |
| Files under review | `scripts/docker/portset.sh`, `scripts/docker/tests/portset_app_supervision.bats`, plus edits to `scripts/docker/utils.sh` and `scripts/docker/healthcheck.sh` |
| Round reached | 10 |
| Circuit-breaker cap | `CIRCUIT_BREAKER_ROUNDS = 10` |
| Reviewer A model | `opencode-go/deepseek-v4.1-flash:max` |
| Reviewer B model | `opencode-go/glm-5.3-flash:max` |

## Context

qBittorrent v5.3.0 segfaults in `serialize(BitTorrent::Torrent const&)` while serving
`/api/v2/sync/maindata` (upstream issue qBittorrent#23833) and the process dies. `portset.sh`
interpreted the resulting "forwarded port unreachable" as a VPN fault, cycled the gluetun VPN
indefinitely, and never restarted the dead application; a container restart inside the
`stopped`/`running` window left gluetun permanently stopped with no tunnel. This review covers
the fix series for that incident.

## Round-10 findings

Round 10 is the last round of the loop, so every fix below was applied **after** the final
reviewer pass and has not been re-reviewed.

| # | Severity | Location | Finding | Status |
| - | -------- | -------- | ------- | ------ |
| 1 | MEDIUM | `scripts/docker/portset.sh:607-630` → `644/665` | A failed in-loop port recovery could hand an **empty** `INCOMING_PORT` to the configure gate, which had no validity guard: qBittorrent would receive `"listen_port": ""`, Deluge `listen_ports (, )`, and nicotine/slskd would be killed and restarted with `--port ""`. | `applied, not independently re-reviewed` — the configure gate now requires a non-empty port and the misleading comment was corrected |
| 2 | MEDIUM | `scripts/docker/portset.sh:356-361` via `:532` | Runtime recovery force-started a deliberately stopped VPN: `restart_vpn_connection()` PUT `running` whenever it observed `stopped`, and consulted the stop-intent marker only on the startup path, so an operator/API/UI stop was silently overridden within one cooldown, repeatedly. | `applied, not independently re-reviewed` — `restart_vpn_connection()` now refuses to start a stopped VPN when no stop-intent marker exists |
| 3 | LOW | `scripts/docker/portset.sh:38-40`, `798-800` | The stop-intent marker was documented as *proof* the VPN was stopped, although it is written before the PUT and deliberately kept when the PUT fails; it records intent only. | `applied, not independently re-reviewed` — wording changed to "may have left the VPN stopped" / "records that the stop came from this script" |
| 4 | LOW | `scripts/docker/portset.sh:1459` | The `WebUI\Username` **append** branch wrote the raw username while the replace branch escaped sed metacharacters, so a username containing `\`, `&` or `~` was mangled or broke sed exactly when the key was absent. | `applied, not independently re-reviewed` — `safe_username` is built once and used in both branches |
| 5 | LOW | `scripts/docker/tests/portset_app_supervision.bats` | Nothing exercised the new 1-65535 forwarded-port rejection. | `applied, not independently re-reviewed` — added "get_incoming_port rejects unusable forwarded ports" (`0`, `70000`, `abc`, empty) |
| 6 | LOW | `scripts/docker/portset.sh:887-889` | `ensure_application_running()` treated a non-zero `application_start` status (for qBittorrent/Deluge that is the 30 s WebUI port wait) as proof the app was dead, burning a restart attempt for a slow-binding but alive application. | `applied, not independently re-reviewed` — the status now logs a warning and falls through to the `check_process` liveness decision |
| 7 | LOW | `scripts/docker/tests/portset_app_supervision.bats:698-700` | Duplicated `# shellcheck disable=SC2030,SC2031` directive. | `applied, not independently re-reviewed` — deduplicated |
| 8 | LOW | `scripts/docker/portset.sh:656-658` | The configure-gate restart path had no settle wait after a successful `ensure_application_running`, unlike `recover_unreachable_port`, so a just-restarted app could spend the port-verify budget on startup latency. | `applied, not independently re-reviewed` — a 10 s settle now follows a successful restart there too |
| 9 | LOW | `scripts/docker/portset.sh:988-990` | `recover_unreachable_port()`'s app-alive → `cycle_vpn_for_broken_forward()` branch is unreachable from production call sites (both guard on `! check_process` immediately before), so one bats test certifies a branch production never takes. | `not fixed` — retained deliberately as a race-path guard; the production cycle path is `should_cycle_forward()` in the cap branch. Consolidating the two would remove a tested branch, so it is left for a follow-up decision |

## Accepted trade-offs (not defects)

1. After the startup retry budget is exhausted the script still execs the application without VPN
   port configuration — an explicit operator decision taken during the debugging gate.
2. `mark_vpn_escalation()` may be recorded after a recovery that only re-queried the port,
   consuming one cooldown window (conservative under-cycling).
3. `kill -0` alone can be fooled by PID reuse (pre-existing); the `pgrep` fallback covers the
   opposite direction. The matching `kill_process`/`pgrep` seam is latent for daemonizing apps.
4. `main()` control flow is tested through helpers rather than by driving the loops.
5. `healthcheck.sh` duplicates the 300 s default; `/tmp/gluetun_escalation_attempted` stays
   hardcoded because `healthcheck.sh` consumes it at that path.
6. `qbittorrent_api_config` force-sets `bypass_local_auth: true` (pre-existing).
7. gluetun credentials still reach curl as `-u user:pass` argv (pre-existing shared pattern).
8. A permanently missing WebUI credential logs a repeating WARN rather than a terminal ERROR.
9. Phase 4 refreshes the healthcheck suppression flag on each cooldown-gated attempt; no maximum
   escalation count is tracked (a watchdog that never acts is outside this script's control).
10. An app-side listen-port mismatch can still cost one bounded VPN cycle before the configure
    gate corrects it.
11. While the third-party reachability verifier stays unusable, no recovery is driven for the
    port (verdict 2 defers); recovery requires evidence.

## Verification gap

Round 10's fixes (items 1-8) were written after the last reviewer pass and have **never been
re-reviewed**. They were verified only by the local suite (`bats scripts/docker/tests/` → 74/74
passing) and `shellcheck` (clean on `portset.sh` and the new test file) at the time of writing.
Treat items 1-8 as applied-but-unverified by an independent reviewer, and item 9 as open.
