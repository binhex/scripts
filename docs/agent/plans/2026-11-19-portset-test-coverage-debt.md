# Plan — close the portset.sh test-coverage debt

| Field | Value |
| ----- | ----- |
| Repository | `/data/scripts` (branch `master`) |
| Raised | 2026-11-19, during the `portset` residual-ledger run |
| Source | tech-debt Step 2 function-level audit (no bash coverage tool exists: `kcov`, `bashcov`, `shcov` all absent) |
| Scope decision | Deferred in full by explicit user decision on 2026-11-19; the run was playing the 9 findings in `docs/agent/reviews/2026-10-23-portset-incoming-port-residuals.md` |
| Measured | 24 of `portset.sh`'s 48 functions are never named by `tests/*.bats`, plus `main()` itself (25 uncovered in total); no percentage is claimed because nothing can measure one |

## Per-app adapters (17 functions)

Each needs stubs for the app's transport, not the app itself:

- `application_configure_incoming_port` — the dispatcher; stub the four per-app configure functions.
- qBittorrent: `qbittorrent_api_login`, `qbittorrent_api_config`, `qbittorrent_edit_config`, `qbittorrent_start`, `qbittorrent_verify_incoming_port` — stub `curl_with_retry` and use a temp `qbittorrent.conf`.
- Deluge: `deluge_api_config`, `deluge_start`, `deluge_verify_incoming_port` — stub the deluge console/HTTP calls and point `DELUGE_WEB_CONFIG_FILEPATH` at a temp file (the verify path greps that JSON for `"https": true`; there is no `core.conf`).
- Nicotine+: `nicotine_edit_parameters`, `nicotine_gluetun_incoming_port`, `nicotine_start`, `nicotine_verify_incoming_port` — the edit/verify pair only delegate to `edit_app_parameters`/`verify_app_parameters` with `--port`, so assert against a controlled `APP_PARAMETERS` array.
- slskd: `slskd_edit_parameters`, `slskd_gluetun_incoming_port`, `slskd_start`, `slskd_verify_incoming_port` — same shape with `--slsk-listen-port`; no config file is read and no API is probed.

## Generic helpers (7 functions)

- `show_help` — asserts the usage text lists every flag.
- `kill_process` — stub `kill`; assert the kill+wait path and the "No PID found" path. (It has
  no `pgrep` fallback: that lives in `check_process`.)
- `wait_for_port_to_be_listening` — stub `nc`; assert the timeout budget and the success path.
- `check_gluetun_cs_api` — stub `curl_with_retry`; assert reachable/unreachable verdicts.
- `start_process_background` — assert `nohup … &` is issued and `APPLICATION_PID` is set. (It
  never reports a start failure: there is no exit-status check to assert.)
- `edit_app_parameters` — assert the replace and append paths for a named parameter. (There is
  no `APP_NAME` dispatch here; the unknown-app `exec` fallback lives in `application_start`.)
- `verify_app_parameters` — assert the required-parameter rejection paths.

## Also uncovered

- `main` (portset.sh) — the suite sources the script under `PORTSET_TEST_MODE`, so the startup and steady-state loops are never driven end to end. Recorded as accepted trade-off 4 in the residual ledger; revisit only if the loop wiring itself needs a regression guard.

## Why this is deferred rather than fixed

The run's task was the 9 recorded review findings; those are verified. Closing this gap is unrelated work spanning four application adapters, and it needs a dedicated run with its own review loop. Explicit user decision: defer, and record it here by name so it is not lost with the session.
