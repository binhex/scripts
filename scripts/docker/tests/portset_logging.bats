#!/usr/bin/env bats

setup() {
    export PORTSET_TEST_MODE=true
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../portset.sh" >/dev/null
}

@test "masks credential values while retaining other arguments" {
    run redact_app_parameters example-app --slsk-username example-user \
        --slsk-password 'fake password with spaces' --api-key=fake-key --web-port 5030 \
        '--APIKEY=fake inline key' --PassWd '--fake-dash-value' --pass '' \
        --web-key fake-web-key --Token fake-token --client-secret fake-secret
    [ "${status}" -eq 0 ]
    [ "${output}" = 'example-app --slsk-username example-user --slsk-password ***MASKED*** --api-key=***MASKED*** --web-port 5030 --APIKEY=***MASKED*** --PassWd ***MASKED*** --pass ***MASKED*** --web-key ***MASKED*** --Token ***MASKED*** --client-secret ***MASKED***' ]
}

@test "masks an empty inline credential without consuming the next argument" {
    run redact_app_parameters example-app --token= --web-port 5030
    [ "${status}" -eq 0 ]
    [ "${output}" = 'example-app --token=***MASKED*** --web-port 5030' ]
}

@test "portset logs masked values and exec receives the original arguments" {
    cat > "${BATS_TEST_TMPDIR}/example-app" <<'APP'
#!/bin/bash
printf '%s\0' "$@" > "${ARGV_FILE}"
APP
    chmod +x "${BATS_TEST_TMPDIR}/example-app"
    export ARGV_FILE="${BATS_TEST_TMPDIR}/actual"
    local args=(--slsk-username example-user --slsk-password 'fake password with spaces'
        --api-key=fake-key --web-port 5030)
    printf '%s\0' "${args[@]}" > "${BATS_TEST_TMPDIR}/expected"

    run env -u PORTSET_TEST_MODE bash "${BATS_TEST_DIRNAME}/../portset.sh" --gluetun-incoming-port no \
        --app-parameters "${BATS_TEST_TMPDIR}/example-app" "${args[@]}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'--slsk-username example-user --slsk-password ***MASKED*** --api-key=***MASKED*** --web-port 5030'* ]]
    [[ "${output}" != *'fake password with spaces'* ]]
    [[ "${output}" != *'fake-key'* ]]
    cmp "${BATS_TEST_TMPDIR}/expected" "${ARGV_FILE}"
}
