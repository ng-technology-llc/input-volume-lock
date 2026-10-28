#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly APP_ID="io.github.input-volume-lock"
readonly DOMAIN="gui/$(id -u)"
readonly LOG="$HOME/Library/Logs/InputVolumeLock.log"
readonly INSTALLED_BIN="$HOME/Library/Application Support/InputVolumeLock/input-volume-lock"
readonly BUILT_BIN="$SCRIPT_DIR/build/input-volume-lock"
readonly DEVICE_HELPER="$SCRIPT_DIR/build/audio-device-test-helper"
readonly WITH_DEVICE_SWITCH="${1:-}"

failures=0
original_device=""

cleanup() {
    if [[ -n "$original_device" && -x "$DEVICE_HELPER" ]]; then
        "$DEVICE_HELPER" select "$original_device" >/dev/null 2>&1 || true
    fi
    "$SCRIPT_DIR/install.sh" resume >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

current_volume() {
    "$DEVICE_HELPER" scalar
}

assert_volume() {
    local expected="$1"
    local actual
    actual="$(current_volume)"
    if [[ "$actual" == "$expected" ]]; then
        pass "input volume is $expected%"
    else
        fail "expected input volume $expected%, got $actual%"
    fi
}

wait_for_volume() {
    local expected="$1"
    local timeout_seconds="${2:-3}"
    local tries=$((timeout_seconds * 20))
    local actual=""
    for ((i = 0; i < tries; i++)); do
        actual="$(current_volume)"
        if [[ "$actual" == "$expected" ]]; then
            pass "input volume returned to $expected%"
            return 0
        fi
        sleep 0.05
    done
    fail "input volume did not return to $expected%; last value: ${actual:-unknown}%"
    return 1
}

assert_service_loaded() {
    if launchctl print "$DOMAIN/$APP_ID" >/dev/null 2>&1; then
        pass "LaunchAgent is loaded"
    else
        fail "LaunchAgent is not loaded"
    fi
}

log_entries_since_test() {
    tail -c +"$log_offset" "$LOG" 2>/dev/null || true
}

echo "Running input-volume-lock regression tests"
log_size="$(stat -f %z "$LOG" 2>/dev/null || echo 0)"
log_offset=$((log_size + 1))
xcrun swiftc \
    -O \
    -framework CoreAudio \
    "$SCRIPT_DIR/tests/AudioDeviceTestHelper.swift" \
    -o "$DEVICE_HELPER"
original_device="$("$DEVICE_HELPER" current | cut -f1)"
"$SCRIPT_DIR/install.sh" install
"$BUILT_BIN" --self-test
pass "self-test ran after the current binary was built and installed"
assert_service_loaded
assert_volume 100

if cmp -s "$BUILT_BIN" "$INSTALLED_BIN"; then
    pass "regression tests are running the installed binary"
else
    fail "installed binary differs from the current build"
fi

correction_log_offset=$(( $(stat -f %z "$LOG") + 1 ))
log_offset="$correction_log_offset"

echo "Test: event-driven correction from 37%"
"$DEVICE_HELPER" set-scalar 37
wait_for_volume 100 2

echo "Test: event-driven correction from 0%"
"$DEVICE_HELPER" set-scalar 0
wait_for_volume 100 2

if [[ "$WITH_DEVICE_SWITCH" == "--with-device-switch" ]]; then
    echo "Test: default input device switch and reattachment"
    if other_device="$("$DEVICE_HELPER" other-lockable)"; then
        other_id="${other_device%%$'\t'*}"
        other_name="${other_device#*$'\t'}"
        pass "other lockable input is available: $other_name"
        log_offset=$(( $(stat -f %z "$LOG") + 1 ))
        "$DEVICE_HELPER" select "$other_id"
        sleep 0.5
        new_entries="$(log_entries_since_test)"
        if grep -Fq "watching active input: $other_name" <<<"$new_entries"; then
            pass "guard followed $other_name"
            "$DEVICE_HELPER" set-scalar 41
            wait_for_volume 100 2
        else
            fail "guard did not follow $other_name"
        fi
    elif other_device="$("$DEVICE_HELPER" other-unlockable)"; then
        other_id="${other_device%%$'\t'*}"
        other_name="${other_device#*$'\t'}"
        pass "other input without volume is available: $other_name"
        log_offset=$(( $(stat -f %z "$LOG") + 1 ))
        "$DEVICE_HELPER" select "$other_id"
        sleep 0.5
        new_entries="$(log_entries_since_test)"
        if grep -Fq "skip: active input has no settable volume: $other_name" <<<"$new_entries"; then
            pass "guard skipped $other_name"
        else
            fail "guard did not skip $other_name"
        fi
    else
        fail "no other input device was available for the switch test"
    fi
    "$DEVICE_HELPER" select "$original_device"
    sleep 0.5
    "$DEVICE_HELPER" set-scalar 41
    wait_for_volume 100 2
    log_offset="$correction_log_offset"
fi

echo "Test: pause honors manual lower volume"
"$SCRIPT_DIR/install.sh" pause
if launchctl print "$DOMAIN/$APP_ID" >/dev/null 2>&1; then
    fail "LaunchAgent is still loaded after pause"
else
    pass "pause unloads the LaunchAgent"
fi
"$DEVICE_HELPER" set-scalar 33
sleep 6
assert_volume 33

echo "Test: resume restores 100%"
"$SCRIPT_DIR/install.sh" resume
wait_for_volume 100 3

echo "Test: service restart keeps enforcing"
launchctl kickstart -k "$DOMAIN/$APP_ID"
sleep 0.5
"$DEVICE_HELPER" set-scalar 45
wait_for_volume 100 2

new_entries="$(log_entries_since_test)"
if grep -Fq 'restored input volume' <<<"$new_entries"; then
    pass "correction events are logged"
else
    fail "correction events are missing from the current test run"
fi

if ((failures > 0)); then
    echo "$failures regression test(s) failed" >&2
    exit 1
fi

trap - EXIT
echo "All regression tests passed"
