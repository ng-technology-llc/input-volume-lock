#!/bin/zsh
set -euo pipefail

readonly APP_ID="io.github.input-volume-lock"
readonly SCRIPT_DIR="${0:A:h}"
readonly APP_DIR="$HOME/Library/Application Support/InputVolumeLock"
readonly INSTALLED_BIN="$APP_DIR/input-volume-lock"
readonly PLIST="$HOME/Library/LaunchAgents/$APP_ID.plist"
readonly LOG="$HOME/Library/Logs/InputVolumeLock.log"
readonly DOMAIN="gui/$(id -u)"

build_binary() {
    mkdir -p "$SCRIPT_DIR/build"
    xcrun swiftc \
        -O \
        -framework AudioToolbox \
        -framework CoreAudio \
        "$SCRIPT_DIR/src/InputVolumeLock.swift" \
        -o "$SCRIPT_DIR/build/input-volume-lock"
}

stop_service() {
    launchctl bootout "$DOMAIN/$APP_ID" 2>/dev/null || true
}

install_service() {
    build_binary

    mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    local temporary_binary="$APP_DIR/input-volume-lock.temporary"
    cp "$SCRIPT_DIR/build/input-volume-lock" "$temporary_binary"
    chmod 755 "$temporary_binary"
    mv -f "$temporary_binary" "$INSTALLED_BIN"

    local temporary_plist="$APP_DIR/$APP_ID.plist.temporary"
    cp "$SCRIPT_DIR/$APP_ID.plist" "$temporary_plist"
    /usr/bin/plutil -replace 'ProgramArguments' -json \
        "[\"$INSTALLED_BIN\",\"--watch\"]" \
        "$temporary_plist"
    /usr/bin/plutil -replace 'StandardOutPath' -string "$LOG" "$temporary_plist"
    /usr/bin/plutil -replace 'StandardErrorPath' -string "$LOG" "$temporary_plist"
    mv -f "$temporary_plist" "$PLIST"
    chmod 644 "$PLIST"

    "$INSTALLED_BIN" --once
    stop_service
    launchctl enable "$DOMAIN/$APP_ID"
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl kickstart -k "$DOMAIN/$APP_ID"
    echo "Installed and started: $APP_ID"
}

status_service() {
    echo "Configured input volume:"
    osascript -e 'get volume settings'
    echo
    launchctl print "$DOMAIN/$APP_ID" 2>&1 | sed -n '1,28p'
    echo
    if [[ -f "$LOG" ]]; then
        echo "Recent log:"
        tail -n 12 "$LOG"
    fi
}

case "${1:-install}" in
    install)
        install_service
        ;;
    build)
        build_binary
        echo "Built: $SCRIPT_DIR/build/input-volume-lock"
        ;;
    status)
        status_service
        ;;
    pause)
        stop_service
        echo "Paused: input volume now follows macOS and apps"
        ;;
    resume)
        if [[ ! -x "$INSTALLED_BIN" || ! -f "$PLIST" ]]; then
            echo "Not installed. Run: $0 install" >&2
            exit 1
        fi
        launchctl enable "$DOMAIN/$APP_ID"
        if ! launchctl print "$DOMAIN/$APP_ID" >/dev/null 2>&1; then
            launchctl bootstrap "$DOMAIN" "$PLIST"
        fi
        launchctl kickstart -k "$DOMAIN/$APP_ID"
        echo "Running: input volume will return to 100%"
        ;;
    uninstall)
        stop_service
        rm -f "$PLIST" "$INSTALLED_BIN" "$LOG"
        rmdir "$APP_DIR" 2>/dev/null || true
        echo "Uninstalled: $APP_ID"
        ;;
    *)
        echo "Usage: $0 {install|build|status|pause|resume|uninstall}" >&2
        exit 2
        ;;
esac
