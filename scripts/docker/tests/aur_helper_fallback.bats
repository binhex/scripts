#!/usr/bin/env bats
#
# Tests for the AUR helper installation path in aur.sh.
#
# Covers:
#   - compile_using_makepkg: a failure returns to the caller instead of exiting
#     the whole script, so install_helper_and_compile can try the next helper
#   - install_helper_and_compile: paru-bin failure falls through to source paru,
#     and the all-helpers-failed terminal path reports failure
#   - compile_using_makepkg / compile_using_helper: an unresolvable pacman
#     dependency (or its target-not-found form) is not retried and is reported
#     with the dependency named
#   - compile_using_makepkg: the retry loop leaves the shell in a valid working
#     directory (it used to rm -rf the directory it was standing in), including
#     the PKGBUILD-edit failure exit
#   - compile_using_makepkg: a transient download failure is still retried
#   - main: a package failure is never swallowed (AOR and --use-makepkg paths)
#   - main: --package-path that is empty or resolves to / is rejected
#   - escape_sed_replacement / configure_makepkg_conf: drift-proof, idempotent,
#     metacharacter-safe makepkg.conf rewrites, including the append branch
#   - parse_args: flag mapping, --help, and unknown-argument rejection
#   - entry-point guard: the script runs when AUR_TEST_MODE is unset
#
# External commands (pacman, makepkg, rcurl.sh, tar, su, chown, sleep, git) are
# stubbed on PATH: the functions under test call them as children, so stubs are
# the only way to drive the failure modes without a real Arch build host.
#
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2329
# SC2016: the stub bodies are single-quoted on purpose, they are scripts in their
#         own right and must not expand in the test shell.
# SC2030/SC2031: env vars are exported for the subshell that runs the function
#         under test, which is the point.
# SC2034: PACKAGE_PATH/AUR_PACKAGE are read by the sourced script.
# SC2329: functions are invoked indirectly by the code under test.

setup() {
    export AUR_TEST_MODE=1

    # one temp root for everything; BATS_TEST_TMPDIR only exists in bats-core >= 1.5
    if [[ -n "${BATS_TEST_TMPDIR}" ]]; then
        TEST_TMP="${BATS_TEST_TMPDIR}"
        TEST_TMP_CREATED=""
    else
        TEST_TMP=$(mktemp -d)
        TEST_TMP_CREATED="yes"
    fi

    STUB_BIN="${TEST_TMP}/bin"
    mkdir -p "${STUB_BIN}"
    CALL_LOG="${TEST_TMP}/calls.log"
    RCURL_COUNT_FILE="${TEST_TMP}/rcurl.count"
    # never let the suite write the real /etc/sudoers.d rule
    SUDOERS_FILE="${TEST_TMP}/sudoers-yay"
    : > "${CALL_LOG}"
    : > "${RCURL_COUNT_FILE}"
    export STUB_BIN CALL_LOG RCURL_COUNT_FILE SUDOERS_FILE

    # pacman is stubbed; removing the helper must make verify_helper_installed() false
    make_stub pacman '
        echo "pacman $*" >> "${CALL_LOG}"
        if [[ "${1}" == "-Rns" ]]; then
            rm -f "${STUB_BIN}/paru"
        fi
        exit 0
    '
    make_stub git 'exit 0'
    make_stub chown 'exit 0'
    make_stub sleep 'exit 0'
    # shadows any real paru on the host PATH; pacman -Rns removes it again
    make_stub paru 'exit 0'

    # su is how compile_using_helper runs paru. AUR_TEST_HELPER_BROKEN makes the
    # first texlive-dummy probe fail, so the helper counts as installed but broken
    # and install_helper_and_compile enters its install loop.
    make_stub su '
        echo "su $*" >> "${CALL_LOG}"
        if [[ -n "${AUR_TEST_SU_FAIL}" ]]; then
            exit 1
        fi
        if [[ -n "${AUR_TEST_SU_DEP_ERROR}" ]]; then
            echo ":: unable to satisfy dependency libssl.so=4-64 required by paru-bin" >&2
            exit 1
        fi
        if [[ "$*" == *texlive-dummy* && -n "${AUR_TEST_HELPER_BROKEN}" && ! -f "${STUB_BIN}/.helper-rebuilt" ]]; then
            exit 1
        fi
        exit 0
    '

    # makepkg records the directory it was run from, then fails or succeeds. The paru
    # stub created in setup() is removed by `pacman -Rns`; only a successful source
    # build of 'paru' re-creates it, so the fallback must genuinely rebuild the helper.
    make_stub makepkg '
        echo "makepkg ${PWD}" >> "${CALL_LOG}"
        fail_now=1
        if [[ -n "${AUR_TEST_FAIL_PACKAGE}" && "${PWD}" != *"${AUR_TEST_FAIL_PACKAGE}"* ]]; then
            fail_now=0
        fi
        if [[ "${fail_now}" -eq 1 ]]; then
            if [[ -n "${AUR_TEST_MAKEPKG_DEP_ERROR}" ]]; then
                echo ":: unable to satisfy dependency libssl.so=4-64 required by paru-bin" >&2
                exit 1
            fi
            if [[ -n "${AUR_TEST_MAKEPKG_TARGET_NOT_FOUND}" ]]; then
                echo "error: target not found: libssl4" >&2
                exit 1
            fi
            if [[ -n "${AUR_TEST_MAKEPKG_CONFLICT}" ]]; then
                echo "error: failed to prepare transaction (conflicting dependencies)" >&2
                exit 1
            fi
            exit "${AUR_TEST_MAKEPKG_STATUS:-0}"
        fi
        if [[ "${PWD##*/}" == "paru" ]]; then
            printf "#!/bin/bash\nexit 0\n" > "${STUB_BIN}/paru"
            chmod +x "${STUB_BIN}/paru"
            : > "${STUB_BIN}/.helper-rebuilt"
        fi
        exit 0
    '

    # rcurl.sh records its invocation and creates the requested output file;
    # AUR_TEST_RCURL_FAIL_ATTEMPTS controls how many calls fail first
    make_stub rcurl.sh '
        echo "rcurl $(pwd -P 2>/dev/null || echo CWD_INVALID)" >> "${CALL_LOG}"
        count=$(( $(cat "${RCURL_COUNT_FILE}") + 1 ))
        echo "${count}" > "${RCURL_COUNT_FILE}"
        if [[ "${count}" -le "${AUR_TEST_RCURL_FAIL_ATTEMPTS:-0}" ]]; then
            echo "rcurl: network failure" >&2
            exit 1
        fi
        if [[ "${1}" == "-o" ]]; then
            : > "${2}"
        fi
        exit 0
    '

    # tar creates the extracted PKGBUILD directory that makepkg is run from
    make_stub tar '
        archive=""
        dest=""
        while [[ "$#" -gt 0 ]]; do
            case "${1}" in
                -C) dest="${2}"; shift ;;
                -*) ;;
                *) archive="${1}" ;;
            esac
            shift
        done
        package=$(basename "${archive}" .tar.gz)
        mkdir -p "${dest}/${package}"
        : > "${dest}/${package}/PKGBUILD"
        exit 0
    '

    PATH="${STUB_BIN}:${PATH}"
    export PATH

    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../aur.sh"

    # the sourced script resets these to its defaults
    PACKAGE_PATH="${TEST_TMP}/pkg"
    mkdir -p "${PACKAGE_PATH}"
    AUR_PACKAGE="jackett-bin"
    PKGBUILD_EDIT=""
}

teardown() {
    if [[ -n "${TEST_TMP_CREATED}" ]]; then
        rm -rf "${TEST_TMP}"
    fi
}

make_stub() {
    local name="${1}"
    local body="${2}"
    printf '#!/bin/bash\n%s\n' "${body}" > "${STUB_BIN}/${name}"
    chmod +x "${STUB_BIN}/${name}"
}

@test "compile_using_makepkg returns instead of exiting when retries are exhausted" {
    export AUR_TEST_MAKEPKG_STATUS=1

    # called without `run` on purpose: `exit 1` inside the function would end
    # this test's shell, which is exactly the defect under test
    compile_using_makepkg "paru-bin" "AUR" "--install" || true

    # six attempts happen, then the function hands control back to the caller
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 6 ]
    echo alive >> "${CALL_LOG}"
    grep -q alive "${CALL_LOG}"
}

@test "install_helper_and_compile falls back to source paru and succeeds" {
    # a broken helper is pre-installed, paru-bin cannot install (unresolvable
    # dependency), and only the source paru build can restore a working helper
    export AUR_TEST_HELPER_BROKEN=1
    export AUR_TEST_FAIL_PACKAGE=paru-bin
    export AUR_TEST_MAKEPKG_DEP_ERROR=1

    run install_helper_and_compile

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Attempting to install AUR helper package 'paru-bin'"* ]]
    [[ "${output}" == *"Attempting to install AUR helper package 'paru'"* ]]
    grep -q 'makepkg .*/paru-bin' "${CALL_LOG}"
    grep -q 'makepkg .*/paru$' "${CALL_LOG}"
    # pacman -Rns removed the broken helper and only the source build re-created it
    [ -x "${STUB_BIN}/paru" ]
    grep -q 'pacman -Rns' "${CALL_LOG}"
    # the sudoers rule went to the test path, not to /etc
    [ -f "${SUDOERS_FILE}" ]
}

@test "compile_using_makepkg does not retry an unresolvable dependency failure" {
    export AUR_TEST_MAKEPKG_DEP_ERROR=1

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [ "${status}" -eq 1 ]
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 1 ]
}

@test "compile_using_makepkg names the unresolvable dependency when it gives up" {
    export AUR_TEST_MAKEPKG_DEP_ERROR=1

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [[ "${output}" == *"libssl.so=4-64"* ]]
    [[ "${output}" == *"unresolvable"* ]]
}

@test "compile_using_makepkg leaves the shell in a valid working directory across retries" {
    export AUR_TEST_MAKEPKG_STATUS=1

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [ "${status}" -eq 1 ]
    # a deleted CWD makes every child process fail with a getcwd error
    [[ "${output}" != *"cannot access parent directories"* ]]
    [[ "${output}" != *"getcwd"* ]]
    # and directly: every child resolved its working directory successfully
    [ "$(grep -c 'CWD_INVALID' "${CALL_LOG}")" -eq 0 ]
}

@test "compile_using_makepkg still retries a transient download failure" {
    export AUR_TEST_RCURL_FAIL_ATTEMPTS=2

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [ "${status}" -eq 0 ]
    [ "$(cat "${RCURL_COUNT_FILE}")" -eq 3 ]
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 1 ]
}

@test "main exits non-zero when an AOR package fails to compile" {
    export AUR_TEST_MAKEPKG_STATUS=1
    AOR_PACKAGE="qbittorrent"
    AUR_PACKAGE=""
    # init edits /etc/makepkg.conf and /usr/bin/makepkg; not the subject here
    init() { mkdir -p "${PACKAGE_PATH}"; }

    run main

    [ "${status}" -eq 1 ]
}

@test "main exits non-zero when a --use-makepkg AUR package fails to compile" {
    export AUR_TEST_MAKEPKG_STATUS=1
    USE_MAKEPKG=true
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    init() { mkdir -p "${PACKAGE_PATH}"; }

    run main

    [ "${status}" -eq 1 ]
}

@test "parse_args maps every flag to its global" {
    parse_args --aur-package 'jackett-bin' --aor-package 'qbittorrent' --use-makepkg \
        --package-path '/tmp/pkgx' --install-package --pkgbuild-edit 'true'

    [ "${AUR_PACKAGE}" = "jackett-bin" ]
    [ "${AOR_PACKAGE}" = "qbittorrent" ]
    [ "${USE_MAKEPKG}" = "true" ]
    [ "${PACKAGE_PATH}" = "/tmp/pkgx" ]
    [ "${INSTALL_PACKAGE}" = "true" ]
    [ "${PKGBUILD_EDIT}" = "true" ]
}

@test "parse_args prints the help text and exits 0 for --help" {
    run parse_args --help

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Syntax:"* ]]
    [[ "${output}" == *"--aur-package"* ]]
}

@test "parse_args rejects an unknown argument with exit 1 and the help text" {
    run parse_args --bogus

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unrecognised argument '--bogus'"* ]]
    [[ "${output}" == *"Syntax:"* ]]
}

@test "compile_using_makepkg does not retry a target-not-found failure" {
    export AUR_TEST_MAKEPKG_TARGET_NOT_FOUND=1

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [ "${status}" -eq 1 ]
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 1 ]
    [[ "${output}" == *"target not found"* ]]
    [[ "${output}" == *"unresolvable"* ]]
}

@test "the entry-point guard runs the script when AUR_TEST_MODE is unset" {
    run env -u AUR_TEST_MODE bash -c "source '${BATS_TEST_DIRNAME}/../aur.sh' --bogus"

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unrecognised argument '--bogus'"* ]]
}

@test "escape_sed_replacement escapes sed replacement metacharacters" {
    [ "$(escape_sed_replacement 'a&b~c\d')" = 'a\&b\~c\\d' ]
}

@test "configure_makepkg_conf rewrites every key whatever the shipped default is" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#BUILDDIR=/tmp/makepkg\n#PKGDEST=/home/packages\n#SRCDEST=/home/sources\n#SRCPKGDEST=/home/srcpackages\n' > "${conf}"

    configure_makepkg_conf "${conf}"

    [ "$(grep '^BUILDDIR=' "${conf}")" = "BUILDDIR=${PACKAGE_PATH}/build" ]
    [ "$(grep '^PKGDEST=' "${conf}")" = "PKGDEST=${PACKAGE_PATH}/pkgdest" ]
    [ "$(grep '^SRCDEST=' "${conf}")" = "SRCDEST=${PACKAGE_PATH}/srcdest" ]
    [ "$(grep '^SRCPKGDEST=' "${conf}")" = "SRCPKGDEST=${PACKAGE_PATH}/srcpkgdest" ]
}

@test "configure_makepkg_conf is idempotent" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#BUILDDIR=/tmp/makepkg\n#PKGDEST=/home/packages\n' > "${conf}"

    configure_makepkg_conf "${conf}"
    configure_makepkg_conf "${conf}"

    [ "$(grep -cE '^(BUILDDIR|PKGDEST|SRCDEST|SRCPKGDEST)=' "${conf}")" -eq 4 ]
    [ "$(grep '^PKGDEST=' "${conf}")" = "PKGDEST=${PACKAGE_PATH}/pkgdest" ]
}

@test "configure_makepkg_conf appends a key that is absent entirely" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#OPTIONS=(strip)\n' > "${conf}"

    configure_makepkg_conf "${conf}"

    [ "$(grep -cE '^(BUILDDIR|PKGDEST|SRCDEST|SRCPKGDEST)=' "${conf}")" -eq 4 ]
    # the appended value is the literal path, not a sed-escaped one
    [ "$(grep '^PKGDEST=' "${conf}")" = "PKGDEST=${PACKAGE_PATH}/pkgdest" ]
}

@test "configure_makepkg_conf does not glue a key onto a line without a newline" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#OPTIONS=(strip)' > "${conf}"

    configure_makepkg_conf "${conf}"

    # every key must start its own line, or makepkg never sees it
    [ "$(grep -cE '^(BUILDDIR|PKGDEST|SRCDEST|SRCPKGDEST)=' "${conf}")" -eq 4 ]
    [ "$(grep '^PKGDEST=' "${conf}")" = "PKGDEST=${PACKAGE_PATH}/pkgdest" ]
}

@test "configure_makepkg_conf appends metacharacter paths literally" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#OPTIONS=(strip)\n' > "${conf}"
    PACKAGE_PATH='/tmp/a&b~c'

    configure_makepkg_conf "${conf}"

    # the value is shell-quoted for makepkg's sourcing, so assert the round-trip
    [ "$(bash -c "source '${conf}'; printf '%s' \"\${PKGDEST}\"")" = '/tmp/a&b~c/pkgdest' ]
}

@test "configure_makepkg_conf writes a package path containing ~ and & literally" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#PKGDEST=/home/packages\n' > "${conf}"
    PACKAGE_PATH='/tmp/a&b~c'

    configure_makepkg_conf "${conf}"

    # the value is shell-quoted for makepkg's sourcing, so assert the round-trip
    [ "$(bash -c "source '${conf}'; printf '%s' \"\${PKGDEST}\"")" = '/tmp/a&b~c/pkgdest' ]
}

@test "compile_using_makepkg returns instead of exiting when the PKGBUILD edit fails" {
    PKGBUILD_EDIT='false'

    # called without `run` on purpose: `exit 1` would end this test's shell, which is
    # exactly the defect under test, while `return 1` lets the assertions below run
    local edit_status=0
    compile_using_makepkg "paru-bin" "AUR" "--install" || edit_status=$?

    [ "${edit_status}" -eq 1 ]
    # the failure exit must leave the shell at / like the other exits (the extracted
    # directory still exists here, so a "directory exists" check would prove nothing)
    [ "$(pwd -P)" = "/" ]
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 0 ]
    echo "reached after the call" >> "${CALL_LOG}"
    grep -q 'reached after the call' "${CALL_LOG}"
}

@test "compile_using_helper does not retry an unresolvable dependency failure" {
    export AUR_TEST_SU_DEP_ERROR=1

    run compile_using_helper "jackett-bin"

    [ "${status}" -eq 1 ]
    [ "$(grep -c 'su ' "${CALL_LOG}")" -eq 1 ]
    [[ "${output}" == *"unresolvable dependencies"* ]]
}

@test "main exits non-zero when --package-path is empty" {
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    PACKAGE_PATH=""
    init() { :; }

    run main

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--package-path"* ]]
}

@test "main exits non-zero when --package-path resolves to the filesystem root" {
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    PACKAGE_PATH="/tmp/.."
    init() { :; }

    run main

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--package-path"* ]]
}

@test "main exits non-zero when --package-path is the filesystem root" {
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    PACKAGE_PATH="/"
    init() { :; }

    run main

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--package-path"* ]]
}

@test "the entry-point guard runs main when AUR_TEST_MODE is unset" {
    run env -u AUR_TEST_MODE bash -c "source '${BATS_TEST_DIRNAME}/../aur.sh' --aur-package ''"

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Running"* ]]
}

@test "install_helper_and_compile reports failure when every helper build fails" {
    # the probe keeps failing until a helper is rebuilt, and every build fails
    export AUR_TEST_HELPER_BROKEN=1
    export AUR_TEST_MAKEPKG_STATUS=1

    run install_helper_and_compile

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"All AUR helper installation attempts failed"* ]]
    grep -q 'makepkg .*/paru-bin' "${CALL_LOG}"
    grep -q 'makepkg .*/paru$' "${CALL_LOG}"
}

@test "main normalises a relative --package-path to an absolute path" {
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    USE_MAKEPKG="true"
    PACKAGE_PATH="pkg"
    init() { :; }
    compile_using_makepkg() { return 0; }

    main

    # a relative path would be reinterpreted against / by the compile loop's cd
    [[ "${PACKAGE_PATH}" == /* ]]
    [[ "${PACKAGE_PATH}" == */pkg ]]
}

@test "parse_args rejects --aur-package with no value" {
    run parse_args --aur-package

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires a value"* ]]
}

@test "parse_args rejects --pkgbuild-edit with no value" {
    run parse_args --pkgbuild-edit

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires a value"* ]]
}

@test "compile_using_makepkg does not retry a conflicting-dependencies failure" {
    export AUR_TEST_MAKEPKG_CONFLICT=1

    run compile_using_makepkg "paru-bin" "AUR" "--install"

    [ "${status}" -eq 1 ]
    [ "$(grep -c 'makepkg ' "${CALL_LOG}")" -eq 1 ]
    [[ "${output}" == *"conflicting dependencies"* ]]
    [[ "${output}" == *"unresolvable"* ]]
}

@test "parse_args rejects --aor-package with no value" {
    run parse_args --aor-package

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires a value"* ]]
}

@test "parse_args rejects --package-path with no value" {
    run parse_args --package-path

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires a value"* ]]
}

@test "parse_args rejects a flag as a flag's value" {
    run parse_args --aur-package --use-makepkg

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"requires a value"* ]]
}

@test "main exits non-zero when --package-path cannot be resolved" {
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    PACKAGE_PATH="pkg"
    init() { :; }
    # a realpath that always fails drives the normalisation failure branch
    printf '#!/bin/bash\nexit 1\n' > "${STUB_BIN}/realpath"
    chmod +x "${STUB_BIN}/realpath"

    run main

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot be resolved"* ]]
}

@test "main exits non-zero when the helper path fails" {
    export AUR_TEST_HELPER_BROKEN=1
    export AUR_TEST_MAKEPKG_STATUS=1
    AUR_PACKAGE="jackett-bin"
    AOR_PACKAGE=""
    USE_MAKEPKG="false"
    init() { mkdir -p "${PACKAGE_PATH}"; }

    run main

    [ "${status}" -eq 1 ]
    [[ "${output}" == *"All AUR helper installation attempts failed"* ]]
}

@test "configure_makepkg_conf writes a path with spaces so bash sources it correctly" {
    local conf="${TEST_TMP}/makepkg.conf"
    printf '#PKGDEST=/home/packages\n' > "${conf}"
    PACKAGE_PATH='/mnt/my packages'

    configure_makepkg_conf "${conf}"

    [ "$(grep '^PKGDEST=' "${conf}")" = 'PKGDEST=/mnt/my\ packages/pkgdest' ]
    # makepkg sources this file, so the value must survive a round-trip
    [ "$(bash -c "source '${conf}'; printf '%s' \"\${PKGDEST}\"")" = '/mnt/my packages/pkgdest' ]
}

@test "compile_using_helper gives up after every retry with no dependency error" {
    export AUR_TEST_SU_FAIL=1

    run compile_using_helper "jackett-bin"

    [ "${status}" -eq 1 ]
    [ "$(grep -c 'su ' "${CALL_LOG}")" -eq 6 ]
    [[ "${output}" == *"after all retry attempts"* ]]
}

@test "compile_using_helper keeps a single quote in the package path intact" {
    PACKAGE_PATH="${TEST_TMP}/a'b"
    mkdir -p "${PACKAGE_PATH}"
    # record the exact -c string handed to su, then fail so the retry loop exits
    make_stub su '
        printf "%s" "${3}" > "${SU_ARGV_FILE}"
        exit 1
    '
    export SU_ARGV_FILE="${TEST_TMP}/su-cmd"

    run compile_using_helper "jackett-bin"

    # re-parse it the way the inner shell does and read the builddir token back
    local cmd
    cmd=$(cat "${SU_ARGV_FILE}")
    local parsed
    parsed=$(bash -c "set -- ${cmd}; for a in \"\$@\"; do case \"\$a\" in --builddir=*) printf '%s' \"\${a#--builddir=}\";; esac; done")
    echo "parsed builddir=[${parsed}]"
    [ "${parsed}" = "${PACKAGE_PATH}/snapshots" ]
}
