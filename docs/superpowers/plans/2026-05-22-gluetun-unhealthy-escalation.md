# Gluetun Unhealthy Escalation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a final escalation step in `ensure_incoming_port()` that attempts to trigger a gluetun container restart by stopping the VPN via the Control Server API, causing gluetun's Docker healthcheck to fail and the watchdog to restart the container with a fresh VPN connection and new port assignment.

**Architecture:** Three-phase escalation already exists in `ensure_incoming_port()` (retry → VPN restart → retry). Phase 4 adds: stop VPN via `PUT /v1/vpn/status` → gluetun health server returns 500 → Docker HEALTHCHECK (5s interval, 1 retry) marks unhealthy → watchdog restarts gluetun container → fresh VPN → new PIA port. A cooldown file prevents re-firing within 5 minutes. If escalation also fails, scripts fall through to "run without port" mode and healthcheck.sh respects a flag file to avoid marking qbittorrent unhealthy (preventing external restart loops).

**Tech Stack:** Bash, gluetun Control Server API (`PUT /v1/vpn/status`), bats (testing)

---

### Task 1: Add `set_vpn_status()` to utils.sh

**Files:**
- Modify: `scripts/docker/utils.sh` (append before end-of-file)

- [ ] **Step 1: Add the function**

Append to `utils.sh` after the `get_gluetun_forwarded_port()` function:

```bash
# Set gluetun VPN status to a desired state (running or stopped).
# Uses the same auth/URL pattern as restart_vpn_connection() in portset.sh.
#
# Args: desired_state ("running" or "stopped")
# Env:  GLUETUN_CONTROL_SERVER_PORT (default: 8000)
#       GLUETUN_CONTROL_SERVER_USERNAME / GLUETUN_CONTROL_SERVER_PASSWORD (optional)
function set_vpn_status() {

  local desired_state="${1}"
  local control_server_url="http://127.0.0.1:${GLUETUN_CONTROL_SERVER_PORT:-8000}/v1"

  if [[ -z "${desired_state}" ]]; then
    echo "[ERROR] No desired state specified for set_vpn_status" >&2
    return 1
  fi

  local auth=""
  if [[ -n "${GLUETUN_CONTROL_SERVER_USERNAME}" ]]; then
    auth="-u ${GLUETUN_CONTROL_SERVER_USERNAME}:${GLUETUN_CONTROL_SERVER_PASSWORD}"
  fi

  local json="{\"status\": \"${desired_state}\"}"

  if ! curl_with_retry "${control_server_url}/vpn/status" 3 2 -k -s ${auth} -X PUT \
    -H "Content-Type: application/json" -d "${json}"; then
    echo "[ERROR] Failed to set VPN status to '${desired_state}'" >&2
    return 1
  fi

  echo "[info] VPN status set to '${desired_state}'" >&2
  return 0
}
```

Note: the `# shellcheck disable=SC2086` for `${auth}` follows the same pattern used throughout portset.sh (auth may be empty or multi-word string).

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/docker/utils.sh`
Expected: no errors

- [ ] **Step 3: Run shellcheck on the new function**

Run: `shellcheck --exclude=SC1090,SC1091 scripts/docker/utils.sh`
Expected: no new warnings (the SC2086 on `${auth}` is intentional)

- [ ] **Step 4: Commit**

```bash
git add scripts/docker/utils.sh
git commit -m "feat: add set_vpn_status() shared function for gluetun API status control"
```

---

### Task 2: Add Phase 4 escalation to `ensure_incoming_port()` in portset.sh

**Files:**
- Modify: `scripts/docker/portset.sh` (inside `ensure_incoming_port()`, after Phase 3)

- [ ] **Step 1: Add Phase 4 block to `ensure_incoming_port()`**

After the Phase 3 `echo "[ERROR] ..."; return 1` lines, add a Phase 4 before the closing `}`:

```bash
  # Phase 4: Final escalation — stop VPN to trigger gluetun container restart.
  # Stops the VPN via gluetun Control Server API. This causes gluetun's
  # Docker healthcheck (queries health server every 5s) to return 500,
  # marking the container unhealthy. The watchdog restarts gluetun,
  # giving us a fresh VPN connection and a new port from PIA.
  #
  # A cooldown file prevents this from firing more than once per 5 minutes,
  # avoiding repeated gluetun restarts in a tight loop.
  local cooldown_file="/tmp/gluetun_escalation_cooldown"
  local cooldown_seconds="${GLUETUN_ESCALATION_COOLDOWN:-300}"  # 5 minute default

  if [[ -f "${cooldown_file}" ]]; then
    local last_escalation
    last_escalation=$(cat "${cooldown_file}")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_escalation))
    if [[ ${elapsed} -lt ${cooldown_seconds} ]]; then
      echo "[WARN] Skipping Phase 4 escalation — cooldown active ($((cooldown_seconds - elapsed))s remaining)"
      echo "[ERROR] Incoming port not available after all escalation phases exhausted"
      return 1
    fi
  fi

  echo "[WARN] Phase 4: Stopping VPN to trigger gluetun container restart (final escalation)..."
  date +%s > "${cooldown_file}"

  # Signal to healthcheck.sh that escalation was attempted (to prevent qbittorrent restart loop)
  date +%s > /tmp/gluetun_escalation_attempted

  if ! set_vpn_status "stopped"; then
    echo "[ERROR] Phase 4 escalation failed — could not stop VPN via gluetun API"
    echo "[ERROR] Incoming port not available after all escalation phases exhausted"
    return 1
  fi

  echo "[WARN] VPN stopped via gluetun API. Waiting for Docker healthcheck to detect failure..."
  echo "[WARN] Watchdog should restart gluetun container with a fresh VPN connection."
  echo "[ERROR] Incoming port not available after all escalation phases exhausted"
  return 1
```

- [ ] **Step 2: Verify the new function inside `ensure_incoming_port`**

The complete function after additions should have this structure:
```
function ensure_incoming_port() {
  local max_retries="${1:-3}"
  local retry_count=0

  # Phase 1: retry
  while ...; done

  # Phase 2: restart VPN + try
  if ! restart_vpn_connection; ...; fi
  sleep 10
  if get_incoming_port; then return 0; fi

  # Phase 3: retry after restart
  while ...; done

  # Phase 4: final escalation (stop VPN)
  local cooldown_file="/tmp/gluetun_escalation_cooldown"
  ... (cooldown check)
  date +%s > "${cooldown_file}"
  date +%s > /tmp/gluetun_escalation_attempted
  if ! set_vpn_status "stopped"; then ...
  return 1
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/docker/portset.sh`
Expected: no errors

- [ ] **Step 4: Run shellcheck**

Run: `shellcheck --exclude=SC1090,SC1091 scripts/docker/portset.sh`
Expected: no new warnings

- [ ] **Step 5: Add a `GLUETUN_ESCALATION_COOLDOWN` default variable to portset.sh**

Add near the other readonly defaults (around line 23, after `defaultMaxPortVerifyRetries="3"`):

```bash
readonly defaultGluetunEscalationCooldown="300"
```

And in the env var resolution section (around line 35):

```bash
GLUETUN_ESCALATION_COOLDOWN="${GLUETUN_ESCALATION_COOLDOWN:-${defaultGluetunEscalationCooldown}}"
```

- [ ] **Step 6: Re-verify syntax after defaults addition**

Run: `bash -n scripts/docker/portset.sh`
Expected: no errors

- [ ] **Step 7: Commit**

```bash
git add scripts/docker/portset.sh
git commit -m "feat: add Phase 4 unhealthy escalation to ensure_incoming_port()"
```

---

### Task 3: Update healthcheck.sh to prevent qbittorrent restart loop

**Files:**
- Modify: `scripts/docker/healthcheck.sh` (inside `healthcheck_command()`, around the `check_incoming_port` call)

**Context:** Currently, when port=0, healthcheck.sh marks qbittorrent unhealthy after 12 retries. The watchdog then restarts qbittorrent, which doesn't fix the gluetun-level problem. After Phase 4 escalation has fired, we want healthcheck.sh to stop marking qbittorrent unhealthy to prevent the external restart loop.

- [ ] **Step 1: Add escalation flag check to the incoming port healthcheck block**

Modify the `check_incoming_port` block inside `healthcheck_command()` (around lines 370-385):

Replace:
```bash
        if ! check_incoming_port; then
          echo "[warn] Incoming port healthcheck failed"
          exit_code=1
        fi
```

With:
```bash
        # Check if portset.sh has already attempted gluetun-unhealthy escalation.
        # If so, don't mark this container unhealthy — the escalation either worked
        # (gluetun will restart) or it didn't, and repeatedly marking qbittorrent
        # unhealthy only triggers useless external restarts.
        if ! check_incoming_port; then
          if [[ -f "/tmp/gluetun_escalation_attempted" ]]; then
            local escalation_time
            escalation_time=$(cat /tmp/gluetun_escalation_attempted 2>/dev/null || echo "0")
            local now
            now=$(date +%s)
            local elapsed=$((now - escalation_time))
            # Within 10 minutes of escalation, don't mark unhealthy (allows gluetun
            # time to restart from watchdog without triggering qbittorrent restarts)
            if [[ ${elapsed} -lt 600 ]]; then
              echo "[info] Incoming port unavailable but escalation attempted ${elapsed}s ago — deferring to gluetun restart"
            else
              echo "[warn] Incoming port healthcheck failed (escalation cooldown expired)"
              exit_code=1
            fi
          else
            echo "[warn] Incoming port healthcheck failed"
            exit_code=1
          fi
        fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/docker/healthcheck.sh`
Expected: no errors

- [ ] **Step 3: Run shellcheck**

Run: `shellcheck --exclude=SC1090,SC1091 scripts/docker/healthcheck.sh`
Expected: no new warnings

- [ ] **Step 4: Commit**

```bash
git add scripts/docker/healthcheck.sh
git commit -m "feat: prevent qbittorrent restart loop by respecting gluetun escalation flag in healthcheck"
```

---

### Task 4: Write tests for Phase 4 escalation

**Files:**
- Create: `scripts/docker/tests/portset_phase4.bats`
- Modify: `scripts/docker/tests/portset_port_zero.bats` (no changes needed, existing tests should still pass)

- [ ] **Step 1: Create the test file**

Create `scripts/docker/tests/portset_phase4.bats`:

```bash
#!/usr/bin/env bats
#
# Tests for Phase 4 escalation in ensure_incoming_port().
# Phase 4 fires after Phases 1-3 exhaust their retries and:
#   - Stops the VPN via gluetun API
#   - Writes a cooldown file to prevent re-firing within 5 minutes
#   - Writes an escalation-attempted flag for healthcheck.sh
#   - Returns 1 (still fails to get a port)

setup() {
    export PORTSET_TEST_MODE=true
    export APP_PARAMETERS=(/usr/bin/test)
    export GLUETUN_INCOMING_PORT=yes
    export APP_NAME=qbittorrent
    export WEBUI_PORT=8080
    export POLL_DELAY=1
    export GLUETUN_ESCALATION_COOLDOWN=1  # Fast for tests (1 second)

    # Temp files for tracking
    export CALL_TRACKER=$(mktemp -t portset_cnt.XXXXXX)
    echo "vpn_restart=0"  > "${CALL_TRACKER}"
    echo "get_port=0"    >> "${CALL_TRACKER}"
    echo "vpn_stopped=0" >> "${CALL_TRACKER}"

    # Clean up any previous flag files
    rm -f /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted

    # ---- mock external commands ----
    curl() {
        if [[ "$*" == *"v1/portforward"* || "$*" == *"v1/openvpn/portforwarded"* ]]; then
            echo '{"port":0,"ports":[]}'
            return 0
        fi
        if [[ "$*" == *"v1/vpn/status"* ]]; then
            if [[ "$*" == *"-X PUT"* ]]; then
                # Track PUT (set_vpn_status call)
                local c; c=$(grep "^vpn_stopped=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
                c=$((c + 1))
                sed -i "s/^vpn_stopped=.*/vpn_stopped=${c}/" "$CALL_TRACKER" 2>/dev/null
                echo '{"outcome":"stopped"}'
                return 0
            fi
            echo '{"status":"running"}'
            return 0
        fi
        if [[ "$*" == *"ifconfig.co/port"* ]]; then
            echo '{"reachable":false}'
            return 0
        fi
        return 0
    }
    export -f curl

    jq() {
        if [[ "$*" == *".port"* ]]; then echo "0"; return 0; fi
        if [[ "$*" == *".reachable"* ]]; then echo "false"; return 0; fi
        echo "test-value"; return 0
    }
    export -f jq

    ifconfig() { echo "tun0: flags=... mtu 1500"; echo "        inet 10.0.0.2"; }
    export -f ifconfig
    nslookup() { return 0; }; export -f nslookup
    pgrep()    { echo "1234"; return 0; }; export -f pgrep
    command()  { [[ "$*" == *"-v"* && "$*" == *"jq"* ]] && return 0; return 1; }; export -f command
    nc()       { return 0; }; export -f nc
    sleep()    { return 0; }; export -f sleep
    date()     { echo "1000"; return 0; }; export -f date  # Fixed timestamp for deterministic tests

    # Source production code
    source "${BATS_TEST_DIRNAME}/../utils.sh"
    source "${BATS_TEST_DIRNAME}/../portset.sh"

    # Override get_incoming_port to always fail (port=0)
    eval '
    get_incoming_port() {
        local c; c=$(grep "^get_port=" "$CALL_TRACKER" 2>/dev/null || echo "0")
        c=$((c + 1))
        sed -i "s/^get_port=.*/get_port=${c}/" "$CALL_TRACKER" 2>/dev/null
        INCOMING_PORT=""
        return 1
    }
    '
    export -f get_incoming_port

    # Override restart_vpn_connection to track calls
    eval '
    restart_vpn_connection() {
        local c; c=$(grep "^vpn_restart=" "$CALL_TRACKER" 2>/dev/null || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_restart=.*/vpn_restart=${c}/" "$CALL_TRACKER" 2>/dev/null
        return 0
    }
    '
    export -f restart_vpn_connection
}

teardown() {
    rm -f "${CALL_TRACKER}" /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted
}

@test "Phase 4: set_vpn_status function exists" {
    run type set_vpn_status
    [ "$status" -eq 0 ]
}

@test "Phase 4: ensure_incoming_port writes cooldown and flag files on escalation" {
    rm -f /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted

    run ensure_incoming_port

    # Both files should exist
    [ -f /tmp/gluetun_escalation_cooldown ]
    [ -f /tmp/gluetun_escalation_attempted ]
}

@test "Phase 4: ensure_incoming_port stops VPN via API (vpn_stopped > 0)" {
    echo "vpn_stopped=0" > "$CALL_TRACKER"
    rm -f /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted

    run ensure_incoming_port

    local stopped
    stopped=$(grep "^vpn_stopped=" "$CALL_TRACKER" | cut -d= -f2)
    echo "vpn_stopped=$stopped"
    [ "$stopped" -ge 1 ]
}

@test "Phase 4: cooldown prevents re-firing within window" {
    rm -f /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted

    # First call — should fire Phase 4
    echo "vpn_stopped=0" > "$CALL_TRACKER"
    run ensure_incoming_port
    local first_stopped
    first_stopped=$(grep "^vpn_stopped=" "$CALL_TRACKER" | cut -d= -f2)

    # Reset flag file for tracking second call
    echo "vpn_stopped=0" > "$CALL_TRACKER"
    # Second call — cooldown file exists, should NOT fire Phase 4
    run ensure_incoming_port
    local second_stopped
    second_stopped=$(grep "^vpn_stopped=" "$CALL_TRACKER" | cut -d= -f2)

    echo "First call: vpn_stopped=$first_stopped"
    echo "Second call: vpn_stopped=$second_stopped"
    [ "$first_stopped" -ge 1 ]
    [ "$second_stopped" -eq 0 ]
}

@test "Phase 4: ensure_incoming_port returns 1 after all phases exhausted" {
    rm -f /tmp/gluetun_escalation_cooldown /tmp/gluetun_escalation_attempted

    run ensure_incoming_port
    [ "$status" -eq 1 ]
}

@test "Phase 4: escalation flag file prevents healthcheck marking unhealthy" {
    # Simulate healthcheck.sh's logic
    date +%s > /tmp/gluetun_escalation_attempted

    local escalation_time
    escalation_time=$(cat /tmp/gluetun_escalation_attempted)
    local now
    now=$(date +%s)
    local elapsed=$((now - escalation_time))

    # Within 10 minutes (600s), should suppress unhealthy
    if [[ ${elapsed} -lt 600 ]]; then
        echo "Escalation ${elapsed}s ago — suppressing unhealthy (PASS)"
    else
        echo "Escalation ${elapsed}s ago — would mark unhealthy"
    fi

    # Since date returns 1000, elapsed = 0, which is < 600
    [ "${elapsed}" -lt 600 ]
}
```

- [ ] **Step 2: Ensure existing tests still pass**

Run: `bats scripts/docker/tests/portset_port_zero.bats`
Expected: 8/8 pass

- [ ] **Step 3: Run the new tests**

Run: `bats scripts/docker/tests/portset_phase4.bats`
Expected: all tests pass

- [ ] **Step 4: Run all bats tests**

Run: `bats -r scripts/docker/tests/`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add scripts/docker/tests/portset_phase4.bats
git commit -m "test: add Phase 4 escalation tests for ensure_incoming_port()"
```

---

### Task 5: Final verification

- [ ] **Step 1: Syntax check all modified files**

```bash
bash -n scripts/docker/utils.sh scripts/docker/portset.sh scripts/docker/healthcheck.sh
```
Expected: no errors

- [ ] **Step 2: Run shellcheck on all modified files**

```bash
shellcheck scripts/docker/utils.sh scripts/docker/portset.sh scripts/docker/healthcheck.sh
```
Expected: only pre-existing warnings (SC1090, SC1091, SC2086 on `${auth}`)

- [ ] **Step 3: Run full bats test suite**

```bash
bats -r scripts/docker/tests/
```
Expected: all tests pass

- [ ] **Step 4: Verify the diff is clean and scoped**

```bash
git diff --stat
```
Expected: only the 4 planned files changed (`utils.sh`, `portset.sh`, `healthcheck.sh`, `tests/portset_phase4.bats`)

- [ ] **Step 5: Commit final adjustments if any**

```bash
git add -A
git commit -m "chore: final verification and cleanup for gluetun escalation"
```
