# QA remediation ledger — portset.sh external-probe removal

| Field | Value |
| ----- | ----- |
| Repository | `/data/scripts` (branch `master`, `BASE_REF=HEAD`, change uncommitted) |
| Date | 2026-11-25 |
| Change under QA | `scripts/docker/portset.sh`, `scripts/docker/tests/portset_app_supervision.bats`, `scripts/docker/tests/portset_port_zero.bats`, `scripts/docker/tests/portset_phase4.bats` |
| Rounds run | 2 (the second left the same failing set, so the loop stopped) |
| Tooling | `shellcheck` 0.x, `bats` 1.14.0, `shfmt`, `pre-commit` (`/usr/sbin`), `markdownlint` |
| Upstream marker | `REVIEW_GATE_STATUS: CLEAN` (code review, 3 rounds) |

## Gate results (final tree)

| Gate | Result | Evidence |
| ---- | ------ | -------- |
| Bash lint | PASS | `shellcheck $(git diff --name-only HEAD -- '*.sh')` -> exit 0. The three changed `.bats` files are outside that glob and were linted per file: exit 0 (this change fixed their 12 pre-existing findings). |
| Bash format | NOT APPLICABLE | `shfmt` is installed but has never been adopted by this project: no `.editorconfig`, no `.shfmt`, not in `.pre-commit-config.yaml`, not referenced by any `.github/workflows` file. `shfmt -d .` reports 10,697 pre-existing diff lines repo-wide; the four changed files alone report 5,084. Measured HEAD vs working tree per file, the change does not add a new class of drift (`portset.sh` 3317 -> 3002 lines, `portset_app_supervision.bats` 1476 -> 1507 from the new tests, `portset_phase4.bats` 322 -> 294, `portset_port_zero.bats` 334 -> 281). Not a tool the project configures, so not a failed gate. |
| Bash tests | PASS | `bats -r .` -> `1..112`, 112 ok, 0 `not ok` |
| Coverage | NOT APPLICABLE | No bash coverage tool exists here: `kcov`, `bashcov`, `shcov` all absent and no coverage config has ever existed in the repo. Recorded in `docs/agent/plans/2026-11-25-bash-coverage-debt-named-scope.md` by explicit user decision. |
| Security — dependency audit | NOT APPLICABLE | No dependency manifest of any kind (`pyproject.toml`, `uv.lock`, `requirements*.txt`, `package.json`, `go.mod`, `Cargo.toml`, `Gemfile` all absent), so there is nothing to audit. |
| Security — secret scan | PASS (manual) | No scanner installed (`gitleaks`, `trufflehog`, `detect-secrets` all absent). Checklist over all 262 added diff lines: 0 hits for `password`, `passwd`, `secret`, `token`, `api[_-]?key`, `credential`, private-key markers, AWS/GitHub/Slack token shapes, and 0 base64-shaped blobs. The two new untracked docs were scanned too: the single hit is the English word "token" in the sentence "`main` token does appear in ...". |
| Pre-commit | **FAILED** | `pre-commit run --all-files` -> `end-of-file-fixer` fails on 13 files, none of them part of this change (see below). |

## Rounds

### Round 1 — the autofix was accepted

Ran `pre-commit run --all-files`. `trim trailing whitespace`, `check yaml` and `check added large files`
passed; `end-of-file-fixer` autofixed 13 unrelated files, each a single missing final newline:
`LICENSE`, `README.md`,
`scripts/apps/kodi/tvheadend/recording-fixer.sh`, `scripts/apps/plex/dbrepair.sh`,
`scripts/apps/qbittorrent/crud-cleaner.sh`, `scripts/docker/{cleanup,gh,github,python,testrunner,upd}.sh`,
`scripts/unraid/system/fan_control/fan_control.sh`, `scripts/unraid/system/no_ransom/no_ransom.sh`.

Re-ran every gate on the mutated tree. The autofix entered those 13 files into `git diff --name-only HEAD`, so
the lint gate command now covered them: `shellcheck` reported **~60 pre-existing findings**, including a real
defect
(`SC2154: pacman_confirm is referenced but not assigned` in `scripts/docker/upd.sh:136`) and legacy backticks in
`fan_control.sh`. Fixing those is a source change in unrelated files (one is a behaviour bug), which QA is not allowed
to make.

### Round 2 — autofix reverted, same failing set

Reverted all 13 files to HEAD (they had no other local modifications). Re-ran every gate on the scoped tree:

- `shellcheck` (`*.sh`) exit 0, (`*.bats`) exit 0 — PASS
- `bats -r .` -> 112 ok — PASS
- secret scan over 262 added lines -> 0 hits — PASS
- `pre-commit run --all-files` -> `end-of-file-fixer` fails again on the same 13 files (it re-applies the same autofix during the run, which was then reverted again)

No further round was attempted: a round that leaves the same failing set ends the loop.

## Remaining failure

`pre-commit run --all-files` fails on the project's own configured `end-of-file-fixer` hook:

```text
fix end of files.........................................................Failed
- hook id: end-of-file-fixer
- exit code: 1
- files were modified by this hook
Fixing scripts/docker/github.sh   ... (13 files)
```

This is pre-existing repo-wide debt, not caused by this change, and it is recorded here rather than fixed because
every available remedy needs a decision QA cannot take:

1. Keep the autofix (`13` files, one newline each). That makes the lint gate cover those files and surface ~60
   pre-existing `shellcheck` findings, including a real bug in `upd.sh` — i.e. accepting the hook means accepting a
   repo-wide source cleanup in the same branch.
2. Fix the whole repo in this branch: apply the newline autofix and remediate all ~60 `shellcheck` findings across the
   13 unrelated files (mechanical quoting/declare-assign plus the `pacman_confirm` defect).
3. Leave the hook red and proceed with the user's explicit override, disclosed in the QA summary and to `finalising`.

QA cannot pick between these: option 1 and 2 change unrelated production source, option 3 needs the user's
authorisation.

## User decision (2026-11-25)

Asked and answered explicitly: **override the gate, keep the diff scoped**. No unrelated file was changed and no
repo-wide cleanup was undertaken. The `pre-commit` gate therefore stays **FAILED** in the QA report, named with its
evidence, and the proceed-anyway decision belongs to the user; `finalising` must surface it rather than treat the run as
pre-commit-clean.

## Verification gap

The final scoped tree has passed every gate except the repo-wide pre-commit hook above; nothing in this change is
unverified. The 13 pre-existing newline defects were never applied and nothing else in this ledger is pending.
