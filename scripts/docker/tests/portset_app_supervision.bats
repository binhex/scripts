#!/usr/bin/env bats
#
# Tests for application supervision, VPN state recovery on startup, and the
# bounded port-verification retry counter in portset.sh.
#
# Observed production failure (2026-10-23):
#   qBittorrent v5.3.0 segfaulted in serialize(BitTorrent::Torrent const&)
#   while serving /api/v2/sync/maindata (upstream issue qBittorrent#23833).
#   portset.sh then read the resulting "port unreachable" as a VPN fault and
#   cycled the gluetun VPN forever, never restarting the dead application.
#   When the container was restarted mid-cycle it died inside the 5 second
#   stopped window, leaving gluetun in {"status":"stopped"} with no tunnel,
#   and nothing in the startup path ever set the VPN back to running.
#
# Behaviour under test:
#   1. ensure_vpn_running() repairs a stuck 'stopped' VPN at startup.
#   2. ensure_application_running() restarts a dead application, bounded by
#      MAX_APP_RESTART_ATTEMPTS.
#   3. recover_unreachable_port() prefers restarting the application over
#      cycling the VPN, and only cycles the VPN when the app is alive.
#   4. Port-verification failures accumulate across loop iterations until a
#      successful verification resets them (the old counter was re-initialised
#      every iteration, so MAX_PORT_VERIFY_RETRIES could never fire).

setup() {
    # Prevent portset.sh top-level code from running
    export PORTSET_TEST_MODE=true

    # Required env vars
    export APP_PARAMETERS=(/usr/bin/test)
    export GLUETUN_INCOMING_PORT=yes
    export APP_NAME=qbittorrent
    export WEBUI_PORT=8080
    export POLL_DELAY=1
    export MAX_APP_RESTART_ATTEMPTS=3
    export MAX_PORT_VERIFY_RETRIES=3
    # the stale-marker threshold is 2x this value; a zero default would make every
    # fresh marker look stale
    export GLUETUN_ESCALATION_COOLDOWN=300

    # Shared files for cross-subshell state
    CALL_TRACKER=$(mktemp -t portset_cnt.XXXXXX)
    VPN_STATE=$(mktemp -t portset_vpn.XXXXXX)
    APP_STATE=$(mktemp -t portset_app.XXXXXX)
    VPN_STOP_INTENT_FILE=$(mktemp -t portset_intent.XXXXXX)
    rm -f "${VPN_STOP_INTENT_FILE}"
    VPN_ESCALATION_LAST_FILE=$(mktemp -t portset_esc.XXXXXX)
    rm -f "${VPN_ESCALATION_LAST_FILE}"
    GLUETUN_ESCALATION_COOLDOWN_FILE=$(mktemp -t portset_cd.XXXXXX)
    rm -f "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    export CALL_TRACKER VPN_STATE APP_STATE VPN_STOP_INTENT_FILE
    export VPN_ESCALATION_LAST_FILE GLUETUN_ESCALATION_COOLDOWN_FILE

    {
        echo "vpn_restart=0"
        echo "vpn_set=0"
        echo "app_start=0"
        echo "get_port=0"
    } > "${CALL_TRACKER}"

    # VPN reported by the mocked gluetun Control Server
    echo "running" > "${VPN_STATE}"
    # Application liveness reported by the mocked check_process
    echo "1" > "${APP_STATE}"

    # ---- mock external commands ----
    # shellcheck disable=SC2329 # invoked indirectly by the sourced production code
    sleep() { return 0; }
    export -f sleep

    # ---- source production code ----
    # shellcheck source=../utils.sh disable=SC1091
    source "${BATS_TEST_DIRNAME}/../utils.sh"
    # shellcheck source=../portset.sh disable=SC1091
    source "${BATS_TEST_DIRNAME}/../portset.sh"

    # ---- override portset functions AFTER sourcing ----
    eval '
    get_vpn_status() {
        cat "${VPN_STATE}" 2>/dev/null || echo "unknown"
    }
    '
    export -f get_vpn_status

    eval '
    set_vpn_status() {
        local desired="${1}"
        local c; c=$(grep "^vpn_set=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_set=.*/vpn_set=${c}/" "$CALL_TRACKER" 2>/dev/null
        echo "${desired}" > "${VPN_STATE}"
        return 0
    }
    '
    export -f set_vpn_status

    eval '
    check_process() {
        local state; state=$(cat "${APP_STATE}" 2>/dev/null || echo "1")
        if [ "${state}" = "1" ]; then
            return 0
        fi
        return 1
    }
    '
    export -f check_process

    eval '
    application_start() {
        local c; c=$(grep "^app_start=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^app_start=.*/app_start=${c}/" "$CALL_TRACKER" 2>/dev/null
        echo "1" > "${APP_STATE}"
        return 0
    }
    '
    export -f application_start

    REAL_RESTART_VPN_CONNECTION=$(declare -f restart_vpn_connection)
    REAL_GET_INCOMING_PORT=$(declare -f get_incoming_port)
    export REAL_RESTART_VPN_CONNECTION REAL_GET_INCOMING_PORT

    eval '
    restart_vpn_connection() {
        local c; c=$(grep "^vpn_restart=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_restart=.*/vpn_restart=${c}/" "$CALL_TRACKER" 2>/dev/null
        echo "VPN_RESTART_EXECUTED"
        return 0
    }
    '
    export -f restart_vpn_connection

    eval '
    get_incoming_port() {
        local c; c=$(grep "^get_port=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^get_port=.*/get_port=${c}/" "$CALL_TRACKER" 2>/dev/null
        INCOMING_PORT="5914"
        return 0
    }
    '
    export -f get_incoming_port
}

teardown() {
    rm -f "${CALL_TRACKER}" "${VPN_STATE}" "${APP_STATE}" "${VPN_STOP_INTENT_FILE}" \
        "${VPN_ESCALATION_LAST_FILE}" "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
}

tracker() {
    grep "^${1}=" "${CALL_TRACKER}" | cut -d= -f2
}

# ======================================================================
# 1. Startup VPN state recovery
# ======================================================================

@test "ensure_vpn_running requests 'running' after an interrupted restart" {
    echo "stopped" > "${VPN_STATE}"
    echo "12345" > "${VPN_STOP_INTENT_FILE}"

    run ensure_vpn_running
    echo "Output: $output"
    echo "vpn_set=$(tracker vpn_set)"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_set)" -ge 1 ]
    [ "$(cat "${VPN_STATE}")" = "running" ]
    [ ! -f "${VPN_STOP_INTENT_FILE}" ]
}

@test "ensure_vpn_running leaves an operator-requested stop untouched" {
    echo "stopped" > "${VPN_STATE}"
    # no stop-intent marker: the stop was not ours
    rm -f "${VPN_STOP_INTENT_FILE}"

    run ensure_vpn_running
    echo "Output: $output"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_set)" -eq 0 ]
    [ "$(cat "${VPN_STATE}")" = "stopped" ]
}

@test "restart_vpn_connection records the stop intent and clears it on success" {
    rm -f "${VPN_STOP_INTENT_FILE}"
    echo "running" > "${VPN_STATE}"

    # restore the production implementation for this test; it calls curl_with_retry
    # directly, so the HTTP layer is mocked (the Control Server accepts both PUTs)
    eval "${REAL_RESTART_VPN_CONNECTION}"
    # shellcheck disable=SC2329 # invoked indirectly by the restored production function
    curl_with_retry() {
        local c; c=$(grep "^vpn_set=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_set=.*/vpn_set=${c}/" "$CALL_TRACKER" 2>/dev/null
        # record the requested state carried in -d '{"status": "..."}'
        local state
        state=$(printf '%s' "$*" | sed -n 's/.*"status": *"\([a-z]*\)".*/\1/p')
        [ -n "${state}" ] && echo "${state}" >> "${VPN_STATE_REQUESTS}"
        return 0
    }

    VPN_STATE_REQUESTS=$(mktemp -t portset_req.XXXXXX)
    export VPN_STATE_REQUESTS

    rstatus=0; restart_vpn_connection || rstatus=$?
    echo "Status=${rstatus} requests=$(tr '\n' ',' < "${VPN_STATE_REQUESTS}")"

    [ "${rstatus}" -eq 0 ]
    # stopped followed by running were actually requested, marker cleaned up
    [ "$(sed -n '1p' "${VPN_STATE_REQUESTS}")" = "stopped" ]
    [ "$(sed -n '2p' "${VPN_STATE_REQUESTS}")" = "running" ]
    [ ! -f "${VPN_STOP_INTENT_FILE}" ]
    rm -f "${VPN_STATE_REQUESTS}"
}

@test "ensure_vpn_running does not touch a VPN that is already running" {
    echo "running" > "${VPN_STATE}"

    run ensure_vpn_running
    echo "Output: $output"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_set)" -eq 0 ]
}

@test "ensure_vpn_running returns 1 when the VPN never starts" {
    echo "stopped" > "${VPN_STATE}"
    echo "12345" > "${VPN_STOP_INTENT_FILE}"

    # every PUT is accepted but the tunnel never comes up
    eval '
    set_vpn_status() {
        local c; c=$(grep "^vpn_set=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_set=.*/vpn_set=${c}/" "$CALL_TRACKER" 2>/dev/null
        return 0
    }
    '
    export -f set_vpn_status

    run ensure_vpn_running
    echo "Status=$status Output: $output"

    [ "$status" -eq 1 ]
}

# ======================================================================
# 2. Application supervision
# ======================================================================

@test "ensure_application_running restarts a dead application" {
    echo "0" > "${APP_STATE}"

    run ensure_application_running
    echo "Output: $output"
    echo "app_start=$(tracker app_start)"

    [ "$status" -eq 0 ]
    [ "$(tracker app_start)" -ge 1 ]
}

@test "ensure_application_running leaves a running application alone" {
    echo "1" > "${APP_STATE}"

    run ensure_application_running
    echo "Output: $output"

    [ "$status" -eq 0 ]
    [ "$(tracker app_start)" -eq 0 ]
}

@test "ensure_application_running gives up after MAX_APP_RESTART_ATTEMPTS" {
    echo "0" > "${APP_STATE}"
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export MAX_APP_RESTART_ATTEMPTS=2

    # the restart does not bring the app back
    eval '
    application_start() {
        local c; c=$(grep "^app_start=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^app_start=.*/app_start=${c}/" "$CALL_TRACKER" 2>/dev/null
        return 0
    }
    '
    export -f application_start

    s1=0; ensure_application_running || s1=$?
    s2=0; ensure_application_running || s2=$?
    s3=0; ensure_application_running || s3=$?

    echo "s1=$s1 s2=$s2 s3=$s3 app_start=$(tracker app_start)"
    [ "$s1" -eq 1 ]
    [ "$s2" -eq 1 ]
    [ "$s3" -eq 1 ]
    [ "$(tracker app_start)" -eq 2 ]
}

# ======================================================================
# 3. Recovery attribution: app death is not a VPN fault
# ======================================================================

@test "recover_unreachable_port restarts the app and never cycles the VPN when the app is dead" {
    echo "0" > "${APP_STATE}"

    run recover_unreachable_port
    echo "Output: $output"
    echo "vpn_restart=$(tracker vpn_restart) app_start=$(tracker app_start)"

    [ "$status" -eq 0 ]
    [ "$(tracker app_start)" -ge 1 ]
    [ "$(tracker vpn_restart)" -eq 0 ]
}

@test "recover_unreachable_port cycles the VPN when the app is alive" {
    echo "1" > "${APP_STATE}"

    run recover_unreachable_port
    echo "Output: $output"
    echo "vpn_restart=$(tracker vpn_restart)"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_restart)" -ge 1 ]
}

@test "recover_unreachable_port returns 2 when the app cannot be restarted" {
    echo "0" > "${APP_STATE}"
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export MAX_APP_RESTART_ATTEMPTS=1

    eval '
    application_start() {
        local c; c=$(grep "^app_start=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^app_start=.*/app_start=${c}/" "$CALL_TRACKER" 2>/dev/null
        return 0
    }
    '
    export -f application_start

    s1=0; recover_unreachable_port || s1=$?
    s2=0; recover_unreachable_port || s2=$?

    echo "s1=$s1 s2=$s2 vpn_restart=$(tracker vpn_restart)"

    [ "$s1" -eq 1 ]
    [ "$s2" -eq 2 ]
    [ "$(tracker vpn_restart)" -eq 0 ]
}

# ======================================================================
# 4. Port verification retry counter must persist across iterations
# ======================================================================

@test "port verification failures accumulate until the retry cap is reached" {
    s1=0; record_port_verify_failure || s1=$?
    s2=0; record_port_verify_failure || s2=$?
    s3=0; record_port_verify_failure || s3=$?

    echo "s1=$s1 s2=$s2 s3=$s3 count=${PORT_VERIFY_RETRY_COUNT}"
    [ "$s1" -eq 1 ]
    [ "$s2" -eq 1 ]
    [ "$s3" -eq 0 ]
    [ "${PORT_VERIFY_RETRY_COUNT}" -eq 3 ]
}

@test "a successful verification resets the retry counter" {
    record_port_verify_failure || true
    record_port_verify_failure || true

    reset_port_verify_failures
    echo "count=${PORT_VERIFY_RETRY_COUNT}"
    [ "${PORT_VERIFY_RETRY_COUNT}" -eq 0 ]

    s1=0; record_port_verify_failure || s1=$?
    echo "s1=$s1 count=${PORT_VERIFY_RETRY_COUNT}"
    [ "$s1" -eq 1 ]
}

# ======================================================================
# 5. Review round 1 regressions
# ======================================================================

@test "restart budget is restored once the application is seen running again" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export MAX_APP_RESTART_ATTEMPTS=2
    echo "0" > "${APP_STATE}"

    # the restart never brings the app back, so the budget is consumed
    eval '
    application_start() {
        local c; c=$(grep "^app_start=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^app_start=.*/app_start=${c}/" "$CALL_TRACKER" 2>/dev/null
        return 0
    }
    '
    export -f application_start

    s1=0; recover_unreachable_port || s1=$?
    s2=0; recover_unreachable_port || s2=$?
    s3=0; recover_unreachable_port || s3=$?
    echo "s1=$s1 s2=$s2 s3=$s3 app_start=$(tracker app_start)"

    [ "$s1" -eq 1 ]
    [ "$s2" -eq 1 ]
    [ "$s3" -eq 2 ]
    [ "$(tracker app_start)" -eq 2 ]

    # the app comes back on its own: the next recovery takes the VPN branch and
    # must restore the restart budget for the following outage
    echo "1" > "${APP_STATE}"
    s4=0; recover_unreachable_port || s4=$?
    echo "s4=$s4 attempts=${APPLICATION_RESTART_ATTEMPTS}"
    [ "$s4" -eq 0 ]
    [ "${APPLICATION_RESTART_ATTEMPTS}" -eq 0 ]

    # a new outage may use the full budget again
    echo "0" > "${APP_STATE}"
    s5=0; recover_unreachable_port || s5=$?
    echo "s5=$s5 app_start=$(tracker app_start)"
    # a restart was tried again, so the budget was genuinely restored
    [ "$s5" -eq 1 ]
    [ "$(tracker app_start)" -eq 3 ]
}

@test "ensure_application_running reports failure when the start command fails" {
    echo "0" > "${APP_STATE}"

    eval '
    application_start() { return 1; }
    '
    export -f application_start

    run ensure_application_running
    echo "Status=$status Output: $output"
    [ "$status" -eq 1 ]
}

@test "recover_unreachable_port returns 1 when the VPN restart fails" {
    echo "1" > "${APP_STATE}"

    eval '
    restart_vpn_connection() { return 1; }
    '
    export -f restart_vpn_connection

    run recover_unreachable_port
    echo "Status=$status Output: $output"

    [ "$status" -eq 1 ]
    [ "$(tracker get_port)" -eq 0 ]
}

@test "validate_positive_integer keeps valid values and replaces invalid ones" {
    run --separate-stderr validate_positive_integer MAX_APP_RESTART_ATTEMPTS 5 3
    [ "$status" -eq 0 ]
    [ "$output" = "5" ]
    [ -z "$stderr" ]

    run --separate-stderr validate_positive_integer MAX_APP_RESTART_ATTEMPTS 0 3
    [ "$output" = "3" ]
    [[ "$stderr" == *"not a positive integer"* ]]

    run --separate-stderr validate_positive_integer MAX_APP_RESTART_ATTEMPTS "" 3
    [ "$output" = "3" ]

    run --separate-stderr validate_positive_integer MAX_APP_RESTART_ATTEMPTS "abc" 3
    [ "$output" = "3" ]
}

# ======================================================================
# 6. Review round 2 regressions
# ======================================================================

@test "vpn escalation is rate limited by the cooldown" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    VPN_ESCALATION_LAST_FILE=$(mktemp -t portset_esc.XXXXXX)
    export VPN_ESCALATION_LAST_FILE
    rm -f "${VPN_ESCALATION_LAST_FILE}"

    # no previous escalation: allowed
    run vpn_escalation_due
    [ "$status" -eq 0 ]

    # just escalated: not allowed, and the remaining time is reported
    mark_vpn_escalation
    run vpn_escalation_due
    [ "$status" -eq 1 ]
    run vpn_escalation_remaining
    [ "$output" -gt 0 ]

    # cooldown elapsed: allowed again
    echo "$(( $(date +%s) - 301 ))" > "${VPN_ESCALATION_LAST_FILE}"
    run vpn_escalation_due
    [ "$status" -eq 0 ]
}

@test "gluetun_escalation_pending tracks the Phase 4 cooldown file" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    rm -f "${GLUETUN_ESCALATION_COOLDOWN_FILE}"

    run gluetun_escalation_pending
    [ "$status" -eq 1 ]

    date +%s > "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    run gluetun_escalation_pending
    [ "$status" -eq 0 ]
    run gluetun_escalation_remaining
    [ "$output" -gt 0 ]

    # the pending window matches the healthcheck suppression window: twice the cooldown
    echo "$(( $(date +%s) - 301 ))" > "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    run gluetun_escalation_pending
    [ "$status" -eq 0 ]

    echo "$(( $(date +%s) - 601 ))" > "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    run gluetun_escalation_pending
    [ "$status" -eq 1 ]
}

@test "external_verify_incoming_port distinguishes unreachable from unverifiable" {
    # shellcheck disable=SC2034 # read by the sourced production function
    INCOMING_PORT=5000

    eval 'curl_with_retry() { echo "<html>rate limited</html>"; }'
    eval 'jq() { echo "null"; }'
    s=0; external_verify_incoming_port || s=$?
    echo "unusable s=$s"
    [ "$s" -eq 2 ]

    eval 'jq() { echo "false"; }'
    s=0; external_verify_incoming_port || s=$?
    echo "unreachable s=$s"
    [ "$s" -eq 1 ]

    eval 'jq() { echo "true"; }'
    s=0; external_verify_incoming_port || s=$?
    echo "reachable s=$s"
    [ "$s" -eq 0 ]
}

@test "escalation limiter still works when its state file is unwritable" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300 VPN_ESCALATION_LAST_FILE="/nonexistent-dir/portset_escalation_state"

    mark_vpn_escalation

    run vpn_escalation_due
    echo "due status=$status (expected 1: in-memory timestamp used)"
    [ "$status" -eq 1 ]
}

@test "a failed stop PUT keeps the stop-intent marker for the startup repair" {
    rm -f "${VPN_STOP_INTENT_FILE}"
    echo "running" > "${VPN_STATE}"

    # the Control Server rejects the transition
    eval "${REAL_RESTART_VPN_CONNECTION}"
    # shellcheck disable=SC2329 # invoked indirectly by the restored production function
    curl_with_retry() { return 1; }

    rstatus=0; restart_vpn_connection || rstatus=$?
    echo "Status=${rstatus} marker=$([[ -f ${VPN_STOP_INTENT_FILE} ]] && echo present || echo absent)"

    [ "${rstatus}" -ne 0 ]
    [ -f "${VPN_STOP_INTENT_FILE}" ]
}

@test "recover_unreachable_port respects the escalation cooldown" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    echo "1" > "${APP_STATE}"
    mark_vpn_escalation

    run recover_unreachable_port
    echo "Status=$status vpn_restart=$(tracker vpn_restart)"

    [ "$status" -eq 1 ]
    [ "$(tracker vpn_restart)" -eq 0 ]
}

@test "a stale stop-intent marker is discarded and never overrides an operator stop" {
    echo "stopped" > "${VPN_STATE}"
    echo "12345" > "${VPN_STOP_INTENT_FILE}"
    # backdate the marker beyond twice the escalation cooldown
    touch -d "2 hours ago" "${VPN_STOP_INTENT_FILE}"

    run ensure_vpn_running
    echo "Output: $output vpn_set=$(tracker vpn_set)"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_set)" -eq 0 ]
    [ "$(cat "${VPN_STATE}")" = "stopped" ]
    [ ! -f "${VPN_STOP_INTENT_FILE}" ]
}

@test "get_incoming_port succeeds when only the public IP lookup fails" {
    INCOMING_PORT=""
    eval '
    get_gluetun_forwarded_port() { GLUETUN_FORWARDED_PORT="44921"; return 0; }
    curl_with_retry() { return 1; }
    '
    export -f get_gluetun_forwarded_port curl_with_retry

    # exercise the production implementation, not the setup mock
    eval "${REAL_GET_INCOMING_PORT}"

    # called in-process: the port is assigned to a variable, not echoed
    is=0; get_incoming_port || is=$?
    echo "Status=${is} port=${INCOMING_PORT}"

    [ "${is}" -eq 0 ]
    [ "${INCOMING_PORT}" = "44921" ]
}

@test "Phase 4 escalation records the stop intent before the VPN stop" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=1
    rm -f "${VPN_STOP_INTENT_FILE}" "${GLUETUN_ESCALATION_COOLDOWN_FILE}" /tmp/gluetun_escalation_attempted

    # gluetun never reports a port, the application is irrelevant here
    eval 'get_incoming_port() { INCOMING_PORT=""; return 1; }'
    eval 'restart_vpn_connection() { return 0; }'
    # record ordering: the marker must exist when the stop is requested
    eval '
    set_vpn_status() {
        if [ "${1}" = "stopped" ]; then
            [ -f "${VPN_STOP_INTENT_FILE}" ] && echo "marker_present_at_stop" >> "${CALL_TRACKER}"
        fi
        return 0
    }
    '
    export -f get_incoming_port restart_vpn_connection set_vpn_status

    s=0; ensure_incoming_port 1 || s=$?
    echo "Status=${s} marker=$([[ -f ${VPN_STOP_INTENT_FILE} ]] && echo present || echo absent)"

    [ "${s}" -eq 1 ]
    grep -q "marker_present_at_stop" "${CALL_TRACKER}"
    [ -f "${VPN_STOP_INTENT_FILE}" ]
    [ -f "${GLUETUN_ESCALATION_COOLDOWN_FILE}" ]

    rm -f /tmp/gluetun_escalation_attempted
}

@test "should_cycle_forward only allows a cycle when nothing else acted" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    rm -f "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    # shellcheck disable=SC2034 # read by the sourced production helper
    VPN_RESTART_COUNT=2
    INCOMING_PORT="44921"

    # unchanged port, no restart during the escalation, no pending escalation
    run should_cycle_forward "44921" "2"
    [ "$status" -eq 0 ]

    # the escalation already cycled the VPN
    run should_cycle_forward "44921" "1"
    [ "$status" -eq 1 ]

    # a different port arrived
    run should_cycle_forward "40000" "2"
    [ "$status" -eq 1 ]

    # no usable port at all
    INCOMING_PORT=""
    run should_cycle_forward "" "2"
    [ "$status" -eq 1 ]

    # an escalation is in flight
    INCOMING_PORT="44921"
    date +%s > "${GLUETUN_ESCALATION_COOLDOWN_FILE}"
    run should_cycle_forward "44921" "2"
    [ "$status" -eq 1 ]
}

@test "cycle_vpn_for_broken_forward refuses while an escalation is pending" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    date +%s > "${GLUETUN_ESCALATION_COOLDOWN_FILE}"

    run cycle_vpn_for_broken_forward
    echo "Status=$status vpn_restart=$(tracker vpn_restart)"

    [ "$status" -eq 1 ]
    [ "$(tracker vpn_restart)" -eq 0 ]
}

@test "cycle_vpn_for_broken_forward cycles the VPN when it is due" {
    # shellcheck disable=SC2030,SC2031 # every @bats test body runs in its own subshell
    export GLUETUN_ESCALATION_COOLDOWN=300
    # shellcheck disable=SC2030,SC2031 # subshell-local by design in this test
    rm -f "${GLUETUN_ESCALATION_COOLDOWN_FILE}" "${VPN_ESCALATION_LAST_FILE}"

    run cycle_vpn_for_broken_forward
    echo "Status=$status vpn_restart=$(tracker vpn_restart) get_port=$(tracker get_port)"

    [ "$status" -eq 0 ]
    [ "$(tracker vpn_restart)" -ge 1 ]
    [ "$(tracker get_port)" -ge 1 ]
}

@test "ensure_vpn_running reports success when the VPN starts on the last attempt" {
    echo "stopped" > "${VPN_STATE}"
    echo "12345" > "${VPN_STOP_INTENT_FILE}"

    # the tunnel only comes up on the third attempt
    eval '
    set_vpn_status() {
        local c; c=$(grep "^vpn_set=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^vpn_set=.*/vpn_set=${c}/" "$CALL_TRACKER" 2>/dev/null
        if [ "${c}" -ge 3 ]; then echo "running" > "${VPN_STATE}"; fi
        return 0
    }
    '
    export -f set_vpn_status

    rstatus=0; ensure_vpn_running || rstatus=$?
    echo "Status=${rstatus} vpn_state=$(cat "${VPN_STATE}") marker=$([[ -f ${VPN_STOP_INTENT_FILE} ]] && echo present || echo absent)"

    [ "${rstatus}" -eq 0 ]
    [ "$(cat "${VPN_STATE}")" = "running" ]
    [ ! -f "${VPN_STOP_INTENT_FILE}" ]
}

@test "get_incoming_port rejects unusable forwarded ports" {
    # exercise the production implementation, not the setup mock
    eval "${REAL_GET_INCOMING_PORT}"

    for bogus in 0 70000 abc ""; do
        INCOMING_PORT=""
        eval "
        get_gluetun_forwarded_port() { GLUETUN_FORWARDED_PORT='${bogus}'; return 0; }
        "
        export -f get_gluetun_forwarded_port

        is=0; get_incoming_port || is=$?
        echo "bogus='${bogus}' status=${is} port='${INCOMING_PORT}'"

        [ "${is}" -eq 1 ]
        [ -z "${INCOMING_PORT}" ]
    done
}

@test "restart_vpn_connection leaves an operator-requested stop in place" {
    rm -f "${VPN_STOP_INTENT_FILE}"
    echo "stopped" > "${VPN_STATE}"

    eval "${REAL_RESTART_VPN_CONNECTION}"
    export -f restart_vpn_connection
    VPN_STATE_REQUESTS=$(mktemp -t portset_req.XXXXXX)
    export VPN_STATE_REQUESTS
    # shellcheck disable=SC2329 # invoked indirectly by the restored production function
    curl_with_retry() {
        echo "PUT" >> "${VPN_STATE_REQUESTS}"
        return 0
    }

    rstatus=0; restart_vpn_connection || rstatus=$?
    echo "Status=${rstatus} puts=$(wc -l < "${VPN_STATE_REQUESTS}" | tr -d ' ')"

    # refused: no start was sent and the operator's stop stands
    [ "${rstatus}" -eq 1 ]
    [ "$(wc -l < "${VPN_STATE_REQUESTS}" | tr -d ' ')" -eq 0 ]
    [ "$(cat "${VPN_STATE}")" = "stopped" ]
    rm -f "${VPN_STATE_REQUESTS}"
}
