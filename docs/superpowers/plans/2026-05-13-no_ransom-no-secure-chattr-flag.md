# `--no-secure-chattr` Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--no-secure-chattr` presence flag that skips chattr obfuscation (rename) and permission lock (chmod 700), falling back to `/usr/bin/chattr` directly.

**Architecture:** Introduce a `no_secure_chattr` variable (default `"no"`). When set to `"yes"` via the presence flag: `lock_chattr()` skips rename+chmod after verifying chattr exists; `process_files()` uses `/usr/bin/chattr` directly instead of the obfuscated path; `prereq()` errors if both `--secure-chattr` (non-default) and `--no-secure-chattr` are specified.

**Tech Stack:** Bash 4+, `chattr`, `shellcheck`

---

### Task 1: Add default variable and argument parsing

**Files:**
- Modify: `scripts/unraid/system/no_ransom/no_ransom.sh` — add variable initialization and case arm

- [ ] **Step 1: Add `no_secure_chattr` default variable**

After `debug="${defaultDebug}"` (line 30), insert:

```bash
readonly defaultNoSecureChattr="no"
no_secure_chattr="${defaultNoSecureChattr}"
```

- [ ] **Step 2: Add `-nsc|--no-secure-chattr` case to argument parser**

After the `-sc|--secure-chattr)` case block (after line 337), insert:

```bash
		-nsc|--no-secure-chattr)
			no_secure_chattr="yes"
			;;
```

This is a presence flag — it does NOT consume `$2` and does NOT add an extra `shift`. The single `shift` at the bottom of the while loop still applies.

- [ ] **Step 3: Verify flag is parseable**

Run:
```bash
bash -n scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no syntax errors.

- [ ] **Step 4: ShellCheck**

Run:
```bash
shellcheck scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no NEW warnings/errors from the changes. Pre-existing issues in unrelated lines are acceptable (note them, do not fix).

- [ ] **Step 5: Commit**

```bash
git add scripts/unraid/system/no_ransom/no_ransom.sh
git commit -m "feat: add --no-secure-chattr default variable and argument parsing"
```

---

### Task 2: Add conflict validation in prereq()

**Files:**
- Modify: `scripts/unraid/system/no_ransom/no_ransom.sh` — add mutual-exclusion check

- [ ] **Step 1: Add conflict check**

After the existing `media_shares` check in `prereq()` (after the `fi` on line 49, before the closing `}` on line 51), insert:

```bash

	if [[ "${secure_chattr}" != "${defaultSecureChattr}" && "${no_secure_chattr}" == "yes" ]]; then
		echo "[warn] --secure-chattr and --no-secure-chattr are mutually exclusive, exiting script..."
		exit 1
	fi
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no syntax errors.

- [ ] **Step 3: Manual conflict test**

Run (should error):
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --secure-chattr mychattr --no-secure-chattr --lock yes --media-shares test 2>&1
```
Expected output includes: `--secure-chattr and --no-secure-chattr are mutually exclusive`

- [ ] **Step 4: ShellCheck**

Run:
```bash
shellcheck scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no NEW warnings/errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/unraid/system/no_ransom/no_ransom.sh
git commit -m "feat: add --no-secure-chattr vs --secure-chattr conflict validation"
```

---

### Task 3: Add early return in lock_chattr()

**Files:**
- Modify: `scripts/unraid/system/no_ransom/no_ransom.sh` — add early-return block at top of `lock_chattr()`

- [ ] **Step 1: Add early return for --no-secure-chattr**

After the existing prerequisite check (the `if [[ ! -f ...` block ending at `fi` on line 57), insert **before** the `if [ -f '/usr/bin/chattr' ]` line:

```bash

	if [[ "${no_secure_chattr}" == "yes" ]]; then
		if [[ "${debug}" == "yes" ]]; then
			echo "[debug] --no-secure-chattr specified, skipping chattr obfuscation and chmod..."
		fi
		return
	fi
```

This preserves the original existence check (which runs first and validates either `/usr/bin/chattr` or the obfuscated binary exists) and then skips the rename+chmod when the flag is set.

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no syntax errors.

- [ ] **Step 3: Dry-run test (--no-secure-chattr with debug)**

Run:
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --no-secure-chattr --lock yes --media-shares nonexistent --debug yes 2>&1
```
Expected output includes: `--no-secure-chattr specified, skipping chattr obfuscation and chmod...`
Expected: script does NOT attempt to `mv` or `chmod` chattr (verified by debug output — no `Locking chattr...` message).

- [ ] **Step 4: Dry-run test (without flag — existing behavior preserved)**

Run:
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --lock yes --media-shares nonexistent --debug yes 2>&1
```
Expected output includes: `Locking chattr...` (as before, when running as root).

- [ ] **Step 5: ShellCheck**

Run:
```bash
shellcheck scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no NEW warnings/errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/unraid/system/no_ransom/no_ransom.sh
git commit -m "feat: skip chattr obfuscation and chmod when --no-secure-chattr"
```

---

### Task 4: Use direct chattr path in process_files()

**Files:**
- Modify: `scripts/unraid/system/no_ransom/no_ransom.sh` — replace hardcoded obfuscated path with dynamic selection

- [ ] **Step 1: Replace chattr_cmd block with dynamic path selection**

Replace these lines (~198-203):

```bash
	# if lock files then set chattr to +i, using obfuscated name
	if [[ "${lock}" == "yes" ]]; then
		chattr_cmd="/usr/bin/${secure_chattr} +i"
	else
		chattr_cmd="/usr/bin/${secure_chattr} -i"
	fi
```

With:

```bash
	# determine chattr binary path
	if [[ "${no_secure_chattr}" == "yes" ]]; then
		chattr_bin="/usr/bin/chattr"
	else
		chattr_bin="/usr/bin/${secure_chattr}"
	fi

	# if lock files then set chattr to +i
	if [[ "${lock}" == "yes" ]]; then
		chattr_cmd="${chattr_bin} +i"
	else
		chattr_cmd="${chattr_bin} -i"
	fi
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
bash -n scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no syntax errors.

- [ ] **Step 3: Verify default path (no flag)**

Run:
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --lock yes --media-shares nonexistent --debug yes 2>&1 | grep -o '/usr/bin/[^ ]*'
```
Expected: `/usr/bin/rttahc` (the default obfuscated name).

- [ ] **Step 4: Verify direct path (with --no-secure-chattr)**

Run:
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --no-secure-chattr --lock yes --media-shares nonexistent --debug yes 2>&1 | grep -o '/usr/bin/[^ ]*'
```
Expected: `/usr/bin/chattr` (direct path, not obfuscated).

- [ ] **Step 5: ShellCheck**

Run:
```bash
shellcheck scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no NEW warnings/errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/unraid/system/no_ransom/no_ransom.sh
git commit -m "feat: use direct chattr path in process_files when --no-secure-chattr"
```

---

### Task 5: Update show_help() documentation

**Files:**
- Modify: `scripts/unraid/system/no_ransom/no_ransom.sh` — add help entry and example

- [ ] **Step 1: Add flag documentation**

After the `--secure-chattr` help entry block (after `Defaults to '${defaultSecureChattr}' (chattr reversed).` and its trailing blank line), insert:

```bash
	-nsc or --no-secure-chattr
		Define whether to skip chattr obfuscation (rename) and permission lockdown (chmod 700).
		Use this flag if you want to keep chattr as-is on the host system.
		Mutually exclusive with --secure-chattr.
		Defaults to not set (obfuscation enabled).
```

- [ ] **Step 2: Add usage example**

After the last example block (after `Make all files and folders in a user share writeable with no exclusions and debug turned on:` example), insert:

```bash
	Make files in a user share read only without obfuscating chattr:
		${ourScriptName} --lock 'yes' --lock-type 'files' --media-shares 'Movies|TV' --no-secure-chattr
```

- [ ] **Step 3: Verify help output**

Run:
```bash
bash scripts/unraid/system/no_ransom/no_ransom.sh --help 2>&1
```
Expected: new flag documentation and example are present in output.

- [ ] **Step 4: ShellCheck**

Run:
```bash
shellcheck scripts/unraid/system/no_ransom/no_ransom.sh
```
Expected: no NEW warnings/errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/unraid/system/no_ransom/no_ransom.sh
git commit -m "docs: add --no-secure-chattr to help text and examples"
```

---

### Final verification checklist

After all tasks are committed, run these end-to-end checks:

- [ ] **Bash syntax:** `bash -n scripts/unraid/system/no_ransom/no_ransom.sh`
- [ ] **ShellCheck clean:** `shellcheck scripts/unraid/system/no_ransom/no_ransom.sh`
- [ ] **Help works:** `bash scripts/unraid/system/no_ransom/no_ransom.sh --help` — includes new flag
- [ ] **Default behavior preserved:** Running without `--no-secure-chattr` still obfuscates chattr (verified via debug output `Locking chattr...`)
- [ ] **Flag activates:** Running with `--no-secure-chattr` skips obfuscation (verified via debug output `skipping chattr obfuscation` and `/usr/bin/chattr` in find commands)
- [ ] **Conflict errors:** Running with both `--secure-chattr customname --no-secure-chattr` prints mutual-exclusion error and exits
