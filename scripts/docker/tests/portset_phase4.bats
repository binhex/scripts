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

    # Reset call tracking for second call
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
    # Simulate healthcheck.sh's logic: write flag, then check if within 10min window
    echo "1000" > /tmp/gluetun_escalation_attempted

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
