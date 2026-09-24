#!/usr/bin/env bats
#
# Tests for the connectivity healthchecks in healthcheck.sh.
#
# Covers:
#   - check_app_logs: network-level evidence detection, host extraction,
#     time-window filtering and exclusion of non-connectivity errors
#     (notably 'Connection refused' from a decommissioned app such as Readarr)
#   - check_internet_connectivity: multi-target probe, majority rule,
#     HEALTHCHECK_HOSTNAME/HEALTHCHECK_HOSTNAMES override and per-attempt cache
#   - check_app_specific: log evidence only marks the container unhealthy when a
#     live connectivity probe confirms the loss
#
# The functions under test are called directly rather than through bats' `run`
# helper: `run` executes in a subshell, which would hide the APP_LOG_NET_ERROR_*
# globals the tests assert on.
#
# shellcheck disable=SC2034,SC2329
# SC2034: APP_LOG_FILE/CONNECTIVITY_PROBE_RESULT are read by the sourced script.
# SC2329: check_dns/check_https/check_app_logs/check_internet_connectivity are
#         replaced per test and invoked indirectly by the code under test.

setup() {
    export HEALTHCHECK_TEST_MODE=true
    export APP_LOG_CHECK_MINUTES=5
    export HEALTHCHECK_HOSTNAMES=
    export HEALTHCHECK_HOSTNAME=
    export HEALTHCHECK_MIN_REACHABLE_HOSTS=

    # check_app_specific/check_process read APPNAME from the image build info
    # file, point them at a temp file so tests control APPNAME.
    export IMAGE_BUILD_INFO_FILE
    IMAGE_BUILD_INFO_FILE=$(mktemp -t hc_build_info.XXXXXX)
    printf 'export APPNAME=prowlarr\n' > "${IMAGE_BUILD_INFO_FILE}"

    export LOG_FILE
    LOG_FILE=$(mktemp -t hc_log.XXXXXX)

    export PROBE_TRACKER
    PROBE_TRACKER=$(mktemp -t hc_probe.XXXXXX)

    export HC_OUT
    HC_OUT=$(mktemp -t hc_out.XXXXXX)
    HC_STATUS=0
    HC_OUTPUT=""

    # Network-level patterns as passed by check_app_specific.
    NET_PATTERNS=(
        'Network is unreachable'
        'No route to host'
        'Connection timed out'
        'Name or service not known'
        'Resource temporarily unavailable'
        'No data available'
        'HttpClient.Timeout'
    )
    export NET_PATTERNS

    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../healthcheck.sh"
}

teardown() {
    rm -f "${IMAGE_BUILD_INFO_FILE}" "${LOG_FILE}" "${PROBE_TRACKER}" "${HC_OUT}"
}

# Calls a healthcheck function in the current shell so that globals set by the
# function remain visible. Output and exit code are captured in HC_OUTPUT/HC_STATUS.
# The helper itself always succeeds because bats runs test bodies with errexit.
call() {
    HC_STATUS=0
    "$@" > "${HC_OUT}" 2>&1 || HC_STATUS=$?
    HC_OUTPUT=$(cat "${HC_OUT}")
    return 0
}

# Writes a supervisord-style log block: a timestamped line followed by
# continuation lines (exception headers, stack frames) at the given age.
write_log_block() {
    local minutes_ago="${1}"
    shift

    local timestamp
    timestamp=$(date -d "${minutes_ago} minutes ago" '+%Y-%m-%d %H:%M:%S,000')

    {
        printf "%s DEBG 'start-script' stdout output:\n" "${timestamp}"
        local line
        for line in "$@"; do
            printf '%s\n' "${line}"
        done
        printf '\n'
    } >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# check_app_logs
# ---------------------------------------------------------------------------

@test "check_app_logs: returns 0 when the log file does not exist" {
    call check_app_logs "${LOG_FILE}.missing" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ -z "${APP_LOG_NET_ERROR_HOSTS}" ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

@test "check_app_logs: ignores Connection refused from a decommissioned app" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Connection refused) (192.168.1.10:8787)' \
        ' ---> System.AggregateException: One or more errors occurred. (Connection refused)' \
        ' ---> System.Net.Sockets.SocketException (111): Connection refused'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ -z "${APP_LOG_NET_ERROR_HOSTS}" ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

@test "check_app_logs: ignores Connection refused to a local service" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Connection refused) (Connection refused) (localhost:8191)' \
        ' ---> System.Net.Sockets.SocketException (111): Connection refused'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

@test "check_app_logs: ignores cancellations, protocol and per-indexer timeouts" {
    write_log_block 2 \
        ' ---> System.Net.Sockets.SocketException (125): Operation canceled'
    write_log_block 2 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: The SSL connection could not be established, see inner exception.'
    write_log_block 2 \
        '[v2.6.5.5623] System.Net.Http.HttpIOException: An HTTP/2 connection could not be established because the server did not complete the HTTP/2 handshake. (InvalidResponse)'
    write_log_block 2 \
        '[v2.6.5.5623] System.Net.WebException: Http request timed out'
    write_log_block 2 \
        '[v2.6.5.5623] System.Net.WebException: Failed to read complete http response'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

@test "check_app_logs: reports network-level errors with the failing host" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (Network is unreachable) (www.limetorrents.fun:443)' \
        ' ---> System.Net.Sockets.SocketException (101): Network is unreachable'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]
    [ "${APP_LOG_NET_ERROR_HOSTS}" = 'www.limetorrents.fun:443' ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 1 ]
    [[ "${HC_OUTPUT}" == *'www.limetorrents.fun:443'* ]]
}

@test "check_app_logs: reports a transient DNS resolver blip" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: Resource temporarily unavailable (uindex.org:443)' \
        ' ---> System.Net.Sockets.SocketException (00000001, 11): Resource temporarily unavailable'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]
    [ "${APP_LOG_NET_ERROR_HOSTS}" = 'uindex.org:443' ]
}

@test "check_app_logs: deduplicates hosts that fail more than once" {
    write_log_block 3 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (1337x.to:443)'
    write_log_block 2 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (1337x.to:443)'
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (apibay.org:443)'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 2 ]
    [[ "${APP_LOG_NET_ERROR_HOSTS}" == *'1337x.to:443'* ]]
    [[ "${APP_LOG_NET_ERROR_HOSTS}" == *'apibay.org:443'* ]]
}

@test "check_app_logs: ignores errors older than the check window" {
    write_log_block 30 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (1337x.to:443)'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

@test "check_app_logs: finds a network error hidden in a multi-line exception" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (bangumi.moe:443)' \
        ' ---> System.AggregateException: One or more errors occurred. (Network is unreachable)' \
        ' ---> System.Net.Sockets.SocketException (101): Network is unreachable' \
        '   at System.Net.Sockets.Socket.AwaitableSocketAsyncEventArgs.ConnectAsync(Socket socket)' \
        '   at NzbDrone.Common.Http.HappyEyeballs.HttpHappyEyeballs.ConnectSocket(IPAddress ipAddress, DnsEndPoint endPoint, CancellationToken cancellationToken) in ./NzbDrone.Common/Http/HappyEyeballs/HttpHappyEyeballs.cs:line 75'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]
    [ "${APP_LOG_NET_ERROR_HOSTS}" = 'bangumi.moe:443' ]
}

@test "check_app_logs: reports evidence without a resolvable host as unknown" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Threading.Tasks.TaskCanceledException: The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.'

    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]
    [ "${APP_LOG_NET_ERROR_HOSTS}" = 'unknown' ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 1 ]
}

@test "check_app_logs: resets evidence from a previous run" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (1337x.to:443)'
    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 1 ]

    : > "${LOG_FILE}"
    call check_app_logs "${LOG_FILE}" "${NET_PATTERNS[@]}"
    [ "${HC_STATUS}" -eq 0 ]
    [ -z "${APP_LOG_NET_ERROR_HOSTS}" ]
    [ "${APP_LOG_NET_ERROR_COUNT}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# check_internet_connectivity
# ---------------------------------------------------------------------------

@test "check_internet_connectivity: healthy when all targets are reachable" {
    check_dns() { return 0; }
    check_https() { return 0; }

    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
}

@test "check_internet_connectivity: healthy when only some targets are unreachable" {
    check_dns() { return 0; }
    check_https() {
        [ "${1}" = 'cloudflare.com' ]
    }

    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
    [[ "${HC_OUTPUT}" == *"Host 'cloudflare.com' is reachable."* ]]
    [[ "${HC_OUTPUT}" == *"Host 'google.com' is not reachable."* ]]
}

@test "check_internet_connectivity: unhealthy when every target is unreachable" {
    check_dns() { return 0; }
    check_https() { return 1; }

    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 1 ]
    [[ "${HC_OUTPUT}" == *'Reachable connectivity hosts: 0/3'* ]]
}

@test "check_internet_connectivity: unhealthy when DNS fails for every target" {
    check_dns() { return 1; }
    check_https() { return 0; }

    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 1 ]
}

@test "check_internet_connectivity: HEALTHCHECK_HOSTNAME overrides the default targets" {
    check_dns() {
        echo "dns:${1}" >> "${PROBE_TRACKER}"
        return 0
    }
    check_https() {
        echo "https:${1}" >> "${PROBE_TRACKER}"
        return 0
    }

    HEALTHCHECK_HOSTNAME='example.com'
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
    [ "$(cat "${PROBE_TRACKER}")" = 'dns:example.com
https:example.com' ]
}

@test "check_internet_connectivity: HEALTHCHECK_HOSTNAMES accepts a comma separated list" {
    check_dns() {
        echo "dns:${1}" >> "${PROBE_TRACKER}"
        return 0
    }
    check_https() {
        echo "https:${1}" >> "${PROBE_TRACKER}"
        return 0
    }

    HEALTHCHECK_HOSTNAMES='one.example,two.example'
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
    [[ "$(cat "${PROBE_TRACKER}")" == *'dns:one.example'* ]]
    [[ "$(cat "${PROBE_TRACKER}")" == *'dns:two.example'* ]]
    [[ "$(cat "${PROBE_TRACKER}")" != *'dns:cloudflare.com'* ]]
}

@test "check_internet_connectivity: falls back to defaults for a malformed host list" {
    check_dns() {
        echo "dns:${1}" >> "${PROBE_TRACKER}"
        return 0
    }
    check_https() { return 0; }

    HEALTHCHECK_HOSTNAMES=' , ,'
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
    [[ "$(cat "${PROBE_TRACKER}")" == *'dns:cloudflare.com'* ]]
}

@test "check_internet_connectivity: HEALTHCHECK_MIN_REACHABLE_HOSTS raises the bar" {
    check_dns() { return 0; }
    check_https() {
        [ "${1}" = 'cloudflare.com' ]
    }

    HEALTHCHECK_MIN_REACHABLE_HOSTS=2
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 1 ]
}

@test "check_internet_connectivity: caches the probe result within a single attempt" {
    check_dns() {
        echo "dns:${1}" >> "${PROBE_TRACKER}"
        return 0
    }
    check_https() { return 0; }

    CONNECTIVITY_PROBE_RESULT=''
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]
    call check_internet_connectivity
    [ "${HC_STATUS}" -eq 0 ]

    # three default targets, probed once each despite two calls
    [ "$(wc -l < "${PROBE_TRACKER}")" -eq 3 ]
    [[ "${HC_OUTPUT}" == *'Reusing connectivity probe result'* ]]
}

@test "check_internet_connectivity: re-probes when the cached result is cleared" {
    check_dns() {
        echo "dns:${1}" >> "${PROBE_TRACKER}"
        return 0
    }
    check_https() { return 0; }

    CONNECTIVITY_PROBE_RESULT=''
    call check_internet_connectivity
    CONNECTIVITY_PROBE_RESULT=''
    call check_internet_connectivity
    [ "$(wc -l < "${PROBE_TRACKER}")" -eq 6 ]
}

# ---------------------------------------------------------------------------
# check_app_specific
# ---------------------------------------------------------------------------

@test "check_app_specific: network log errors plus a failed probe mark unhealthy" {
    check_app_logs() {
        APP_LOG_NET_ERROR_HOSTS='1337x.to:443'
        APP_LOG_NET_ERROR_COUNT=1
        echo "[warn] Network connectivity errors found in recent application logs (1 host(s): ${APP_LOG_NET_ERROR_HOSTS})."
        return 1
    }
    check_internet_connectivity() { return 1; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 1 ]
    [[ "${HC_OUTPUT}" == *'1337x.to:443'* ]]
    [[ "${HC_OUTPUT}" == *'lost internet connectivity'* ]]
}

@test "check_app_specific: network log errors with a healthy probe stay healthy" {
    check_app_logs() {
        APP_LOG_NET_ERROR_HOSTS='1337x.to:443'
        APP_LOG_NET_ERROR_COUNT=1
        return 1
    }
    check_internet_connectivity() { return 0; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
    [[ "${HC_OUTPUT}" == *'transient or host specific'* ]]
}

@test "check_app_specific: service-down log errors never trigger a probe" {
    check_app_logs() { return 0; }
    check_internet_connectivity() {
        echo 'probe called' >> "${PROBE_TRACKER}"
        return 1
    }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
    [ ! -s "${PROBE_TRACKER}" ]
}

@test "check_app_specific: skips apps that are not supervised" {
    printf 'export APPNAME=nginx\n' > "${IMAGE_BUILD_INFO_FILE}"
    check_app_logs() { return 1; }
    check_internet_connectivity() { return 1; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
}

@test "check_app_specific: skips when APPNAME is not set" {
    printf 'export APPNAME=\n' > "${IMAGE_BUILD_INFO_FILE}"
    check_app_logs() { return 1; }
    check_internet_connectivity() { return 1; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
    [[ "${HC_OUTPUT}" == *'APPNAME is not defined'* ]]
}

@test "check_app_specific: end to end, a removed app (Readarr) stays healthy" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Connection refused) (192.168.1.10:8787)' \
        ' ---> System.Net.Sockets.SocketException (111): Connection refused'
    APP_LOG_FILE="${LOG_FILE}"
    check_internet_connectivity() {
        echo 'probe called' >> "${PROBE_TRACKER}"
        return 1
    }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
    [ ! -s "${PROBE_TRACKER}" ]
}

@test "check_app_specific: end to end, unreachable hosts plus a failed probe mark unhealthy" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (Network is unreachable) (1337x.to:443)' \
        ' ---> System.Net.Sockets.SocketException (101): Network is unreachable'
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: One or more errors occurred. (Network is unreachable) (apibay.org:443)'
    APP_LOG_FILE="${LOG_FILE}"
    check_internet_connectivity() { return 1; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 1 ]
    [[ "${HC_OUTPUT}" == *'1337x.to:443'* ]]
    [[ "${HC_OUTPUT}" == *'apibay.org:443'* ]]
}

@test "check_app_specific: end to end, unreachable hosts with a healthy probe stay healthy" {
    write_log_block 1 \
        '[v2.6.5.5623] System.Net.Http.HttpRequestException: Resource temporarily unavailable (uindex.org:443)' \
        ' ---> System.Net.Sockets.SocketException (00000001, 11): Resource temporarily unavailable'
    APP_LOG_FILE="${LOG_FILE}"
    check_internet_connectivity() { return 0; }

    call check_app_specific
    [ "${HC_STATUS}" -eq 0 ]
    [[ "${HC_OUTPUT}" == *'transient or host specific'* ]]
}

# ---------------------------------------------------------------------------
# sourcing guard
# ---------------------------------------------------------------------------

@test "sourcing the script does not run the healthcheck" {
    run bash -c "HEALTHCHECK_TEST_MODE=true source '${BATS_TEST_DIRNAME}/../healthcheck.sh' && echo sourced"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'sourced'* ]]
    [[ "${output}" != *'Health checking'* ]]
}
