#!/usr/bin/env bats
#
# TDD test for port=0 escalation bug.
#
# When gluetun returns {"port":0,"ports":[]}, the portset.sh steady-state loop
# hits `check()` → fails → sleep 60 → continue. The VPN restart recovery code
# in the inner loop is structurally unreachable.
#
# The fix:
#   1. Add `ensure_incoming_port()` that escalates to restart_vpn_connection()
#      when get_incoming_port() fails with port=0.
#   2. Restructure the steady-state loop to call ensure_incoming_port()
#      instead of just sleep+continue.

setup() {
    # Prevent portset.sh top-level code from running
    export PORTSET_TEST_MODE=true

    # Required env vars
    export APP_PARAMETERS=(/usr/bin/test)
    export GLUETUN_INCOMING_PORT=yes
    export APP_NAME=qbittorrent
    export WEBUI_PORT=8080
    export POLL_DELAY=1

    # Shared file for call-count tracking across subshells
    export CALL_TRACKER=$(mktemp -t portset_cnt.XXXXXX)
    init_tracker

    # ---- mock external commands ----
    curl() {
        local pa; pa=$(grep "^port_available=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        if [[ "$*" == *"v1/portforward"* || "$*" == *"v1/openvpn/portforwarded"* ]]; then
            if [[ "${pa}" == "1" ]]; then
                echo '{"port":5914}'
            else
                echo '{"port":0,"ports":[]}'
            fi
            return 0
        fi
        if [[ "$*" == *"v1/vpn/status"* ]]; then
            if [[ "$*" == *"-X PUT"* ]]; then
                echo '{"outcome":"stopped"}'
                echo '{"outcome":"running"}'
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

    ifconfig() {
        echo "tun0: flags=4305<UP,POINTOPOINT,RUNNING,NOARP,MULTICAST>  mtu 1500"
        echo "        inet 10.0.0.2  netmask 255.255.255.252"
    }
    export -f ifconfig

    nslookup() { return 0; };       export -f nslookup
    pgrep()    { echo "1234"; return 0; }; export -f pgrep
    command()  { [[ "$*" == *"-v"* && "$*" == *"jq"* ]] && return 0; return 1; }; export -f command
    nc()       { return 0; };        export -f nc
    sleep()    { return 0; };        export -f sleep

    date() {
        if [[ "$*" == *"-d"* ]]; then echo "2026-05-19 12:00"; return 0; fi
        command date "$@"
    }
    export -f date

    # ---- source production code ----
    source "${BATS_TEST_DIRNAME}/../utils.sh"
    source "${BATS_TEST_DIRNAME}/../portset.sh"

    # ---- override portset functions AFTER sourcing ----
    # All mocks use grep/CALL_TRACKER directly (not helper functions) so
    # they work inside `run` subshells without needing export -f on helpers.
    eval '
    get_incoming_port() {
        local c; c=$(grep "^get_port=" "$CALL_TRACKER" 2>/dev/null | cut -d= -f2 || echo "0")
        c=$((c + 1))
        sed -i "s/^get_port=.*/get_port=${c}/" "$CALL_TRACKER" 2>/dev/null
        local pa; pa=$(grep "^port_available=" "$CALL_TRACKER" | cut -d= -f2 2>/dev/null || echo "0")
        if [ "${pa}" = "1" ]; then
            INCOMING_PORT="5914"
            return 0
        fi
        INCOMING_PORT=""
        return 1
    }
    '
    export -f get_incoming_port

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
}

init_tracker() {
    echo "port_available=0" >  "${CALL_TRACKER}"
    echo "vpn_restart=0"    >> "${CALL_TRACKER}"
    echo "get_port=0"       >> "${CALL_TRACKER}"
}

teardown() {
    rm -f "${CALL_TRACKER}"
}

# ======================================================================
# RED tests — capture the bug before the fix
# ======================================================================

@test "[RED] check returns 1 when gluetun returns port 0" {
    run check
    [ "$status" -eq 1 ]
}

@test "[RED] check does NOT call restart_vpn_connection (the bug)" {
    run check
    [ "$status" -eq 1 ]
    local vpn
    vpn=$(grep "^vpn_restart=" "$CALL_TRACKER" | cut -d= -f2)
    echo "vpn_restart=$vpn"
    [ "$vpn" = "0" ]
    echo "BUG CONFIRMED: check() returned $status, vpn_restart=$vpn"
}

# ======================================================================
# ensure_incoming_port() behavior tests
# ======================================================================

@test "ensure_incoming_port exists" {
    run type ensure_incoming_port
    [ "$status" -eq 0 ]
}

@test "ensure_incoming_port calls restart_vpn_connection when port=0 persists" {
    run ensure_incoming_port
    local vpn
    vpn=$(grep "^vpn_restart=" "$CALL_TRACKER" | cut -d= -f2)
    echo "Output: $output"
    echo "vpn_restart=$vpn"
    [[ "$output" == *"VPN_RESTART_EXECUTED"* ]]
    [ "$vpn" -ge 1 ]
}

@test "ensure_incoming_port returns 1 when port=0 persists after VPN restart" {
    run ensure_incoming_port
    echo "Status=$status"
    [ "$status" -eq 1 ]
}

@test "ensure_incoming_port returns 0 when port becomes available after VPN restart" {
    # Custom mock: succeeds after restart_vpn_connection has been called
    eval '
    get_incoming_port() {
        local c; c=$(grep "^get_port=" "$CALL_TRACKER" | cut -d= -f2 2>/dev/null || echo "0")
        c=$((c + 1))
        sed -i "s/^get_port=.*/get_port=${c}/" "$CALL_TRACKER" 2>/dev/null
        local vr; vr=$(grep "^vpn_restart=" "$CALL_TRACKER" | cut -d= -f2 2>/dev/null || echo "0")
        if [ "${vr}" -ge 1 ]; then
            INCOMING_PORT="5914"
            return 0
        fi
        INCOMING_PORT=""
        return 1
    }
    '
    export -f get_incoming_port

    run ensure_incoming_port
    local vpn; vpn=$(grep "^vpn_restart=" "$CALL_TRACKER" | cut -d= -f2)
    echo "Status=$status vpn_restart=$vpn"
    [ "$status" -eq 0 ]
    [ "$vpn" -ge 1 ]
}

@test "ensure_incoming_port calls get_incoming_port at least once" {
    run ensure_incoming_port
    local g; g=$(grep "^get_port=" "$CALL_TRACKER" | cut -d= -f2)
    echo "get_port=$g"
    [ "$g" -ge 1 ]
}

# ======================================================================
# Integration: steady-state loop recovery
# ======================================================================

@test "steady-state loop recovery path works via ensure_incoming_port" {
    # check() still returns 1 when port=0
    run check
    [ "$status" -eq 1 ]

    # But the loop now calls ensure_incoming_port instead of sleep+continue
    run ensure_incoming_port
    local vpn; vpn=$(grep "^vpn_restart=" "$CALL_TRACKER" | cut -d= -f2)
    echo "vpn_restart=$vpn"
    [ "$vpn" -ge 1 ]
}
