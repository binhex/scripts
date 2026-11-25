# Plan — bash test-coverage debt, recorded as named scope

| Field | Value |
| ----- | ----- |
| Repository | `/data/scripts` (branch `master`) |
| Raised | 2026-11-25, tech-debt Step 2 during the `portset.sh` external-probe removal |
| Source | tech-debt Step 2 (improve test coverage, target 95%) |
| Scope decision | **User decision 2026-11-25:** record as named debt, continue chain |
| Target | 95% (tech-debt default; this repo configures no other threshold) |
| Supersedes | `2026-11-19-portset-test-coverage-debt.md` (counts only; stub recipes there) |

## Why there is no coverage number

No measurement was possible in the environments this repo is worked in, so the numbers below are a
**function-level proxy**, not line coverage.

| Tool | State |
| ---- | ----- |
| `kcov` | absent; the v42 static build fails with `libopcodes-2.38-system.so: cannot open shared object file` |
| `bashcov` | absent (Ruby gem, not installed) |
| `shcov` | absent |
| `apt-get` | not present in this environment, so no package can be installed |
| network | reachable (HTTP 200 from `deb.debian.org`), so the blocker is tooling, not connectivity |
| `bats` | present at `/usr/sbin/bats` — this is the only test tool the repo has |

Without a tracer there is no way to state line coverage, which is why this file exists: the gap is
recorded by function name so it cannot be lost, not measured by percentage.

## How the proxy was produced

For each runtime script, list the functions and check whether the name appears anywhere in
`scripts/docker/tests/*.bats`:

```bash
for f in $(grep -oP '^function \K[a-z_0-9]+' portset.sh); do
  grep -rqE "(^|[^a-z_0-9])${f}([^a-z_0-9]|$)" tests/*.bats || echo "UNCOVERED: $f"
done
```

A name appearing in a test is not proof the function is exercised correctly, so treat every
"covered" verdict as an upper bound.

## Measured state (2026-11-25)

| Script | Functions | Never named by a test | Proxy |
| ------ | --------- | --------------------- | ----- |
| `scripts/docker/portset.sh` | 43 | 24 | 44% |
| `scripts/docker/healthcheck.sh` | 9 | 3 | 66% |
| `scripts/docker/utils.sh` | 17 | 14 | 17% |
| **Total** | **69** | **41** | **41%** |

`portset.sh`'s `main()` is also never driven end to end: the suite sources the script under
`PORTSET_TEST_MODE`, so the startup loop and the steady-state loop never run as a whole. (A bare
`main` token does appear in `tests/aur_helper_fallback.bats`, but that is `aur.sh`'s `main`.) Treat
real coverage as lower than the table above.

## Named debt — `portset.sh` (24 functions)

Per-app adapters (17):

- `application_configure_incoming_port`
- `qbittorrent_api_login`, `qbittorrent_api_config`,
  `qbittorrent_edit_config`, `qbittorrent_start`,
  `qbittorrent_verify_incoming_port`
- `deluge_api_config`, `deluge_start`, `deluge_verify_incoming_port`
- `nicotine_edit_parameters`, `nicotine_gluetun_incoming_port`, `nicotine_start`, `nicotine_verify_incoming_port`
- `slskd_edit_parameters`, `slskd_gluetun_incoming_port`, `slskd_start`, `slskd_verify_incoming_port`

Generic helpers (7):

- `check_gluetun_cs_api`
- `start_process_background`
- `kill_process`
- `wait_for_port_to_be_listening`
- `edit_app_parameters`
- `verify_app_parameters`
- `show_help`

## Named debt — `healthcheck.sh` (3 functions)

- `check_incoming_port`
- `healthcheck_command`
- `healthcheck_action`

## Named debt — `utils.sh` (14 functions)

- `get_vpn_adapter_name`
- `get_vpn_adapter_ip_address`
- `process_env_var`
- `download_github_release_asset`
- `show_help_download_github_release_asset`
- `symlink`
- `show_help_symlink`
- `dos2unix`
- `show_help_dos2unix`
- `trim`
- `show_help_trim`
- `shlog`
- `show_help_shlog`
- `rotate_log_file`

## What closing this requires

1. A measurement tool that actually runs here. Options, cheapest first: build `kcov` from source
   (it needs the `binutils` dev library that the prebuilt binary expects), install `bashcov` plus a
   Ruby toolchain, or write a `BASH_XTRACEFD`/`PS4='+${BASH_SOURCE}:${LINENO}'` tracer that runs the
   whole `bats` suite and reports executed lines per script. Until one of these exists, any target
   number is unverifiable.
2. Tests for the 41 functions above, with transport stubs per application. The per-app stub recipes
   (which calls to fake for qBittorrent, Deluge, Nicotine+ and slskd, and what each generic helper
   needs) are already written out in `2026-11-19-portset-test-coverage-debt.md` — start there.
3. A regression guard for `portset.sh`'s startup and steady-state loops, which today have no test at
   all (the `PORTSET_TEST_MODE` gate is what makes that possible to fix without touching production
   behaviour).

Until then, the honest statement of this repo's test state is: the supervision and recovery
functions are covered by named tests; the per-application adapters, the port-listening helpers and
most of `utils.sh` are not.
