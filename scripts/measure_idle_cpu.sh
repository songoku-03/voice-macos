#!/usr/bin/env bash
set -e

# Defaults and Constants
APP_NAME="SoundsSource"
APP_BUNDLE="build/${APP_NAME}.app"
APP_DOMAIN="com.soundssource.app"
DEFAULT_TAPS=("com.spotify.client" "com.hnc.Discord" "com.google.Chrome" "com.google.antigravity")

# Arguments / Flags
TAPS_ARG="4"
POPOVER_MODE="closed" # closed, open, opened_then_closed
DURATION=30
WARMUP=5
PROFILE=false
NO_BUILD=false

usage() {
    echo "Usage: $0 [options] [0|1|4]"
    echo ""
    echo "Options:"
    echo "  --taps <0|1|4|bundle_ids>   Tap count (0, 1, 4) or space/comma-separated bundle IDs (default: 4)"
    echo "  --popover                   Open popover during measurement"
    echo "  --popover-opened-then-closed Open popover for 10s then close before measuring"
    echo "  --duration <seconds>        Measurement duration in seconds (default: 30)"
    echo "  --warmup <seconds>          Steady state wait time in seconds (default: 5)"
    echo "  --profile                   Run sample 10s & check for forbidden RT-safety symbols on IO threads"
    echo "  --no-build                  Skip building app if build/SoundsSource.app exists"
    echo "  -h, --help                  Show this help message"
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --taps)
            TAPS_ARG="$2"; shift 2 ;;
        --popover)
            POPOVER_MODE="open"; shift ;;
        --popover-opened-then-closed)
            POPOVER_MODE="opened_then_closed"; shift ;;
        --duration)
            DURATION="$2"; shift 2 ;;
        --warmup)
            WARMUP="$2"; shift 2 ;;
        --profile)
            PROFILE=true; shift ;;
        --no-build)
            NO_BUILD=true; shift ;;
        -h|--help)
            usage ;;
        0|1|4)
            TAPS_ARG="$1"; shift ;;
        *)
            if [[ "$1" =~ ^- ]]; then
                echo "Unknown option: $1"
                usage
            else
                TAPS_ARG="$1"
                shift
            fi
            ;;
    esac
done

# Resolve requested taps array
REQUESTED_TAPS=()
case "$TAPS_ARG" in
    0)
        REQUESTED_TAPS=()
        ;;
    1)
        REQUESTED_TAPS=("${DEFAULT_TAPS[0]}")
        ;;
    4)
        REQUESTED_TAPS=("${DEFAULT_TAPS[@]}")
        ;;
    *)
        # Split string by space or comma
        IFS=', ' read -r -a REQUESTED_TAPS <<< "$TAPS_ARG"
        ;;
esac

echo "========================================="
echo " SoundsSource Idle CPU Measurement"
echo "========================================="
echo "Taps configuration : ${#REQUESTED_TAPS[@]} taps [${REQUESTED_TAPS[*]}]"
echo "Popover mode       : $POPOVER_MODE"
echo "Warmup duration    : ${WARMUP}s"
echo "Measure duration   : ${DURATION}s"
echo "Profile mode       : $PROFILE"
echo "========================================="

# Backup existing defaults domain
BACKUP_FILE=$(mktemp /tmp/soundssource_defaults_XXXXXX)
DEFAULTS_EXIST=false
if defaults read "$APP_DOMAIN" >/dev/null 2>&1; then
    defaults export "$APP_DOMAIN" "$BACKUP_FILE" 2>/dev/null || true
    DEFAULTS_EXIST=true
    echo "[+] Exported existing defaults to $BACKUP_FILE"
fi

APP_PID=""
PROFILE_VIOLATIONS_COUNT=0
CLEANUP_DONE=false

cleanup() {
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true
    trap - EXIT INT TERM
    echo ""
    echo "[+] Cleanup: Restoring original defaults and terminating process..."
    if [[ -n "$APP_PID" ]]; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    killall "$APP_NAME" 2>/dev/null || true

    if [[ "$DEFAULTS_EXIST" == "true" && -f "$BACKUP_FILE" ]]; then
        defaults import "$APP_DOMAIN" "$BACKUP_FILE" 2>/dev/null || true
        echo "[+] Restored defaults from $BACKUP_FILE"
    else
        defaults delete "$APP_DOMAIN" desiredTappedBundleIDs 2>/dev/null || true
    fi

    rm -f "$BACKUP_FILE" 2>/dev/null || true
    rm -f /tmp/soundssource_sample_*.txt 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Build app if needed
if [[ "$NO_BUILD" == "false" || ! -d "$APP_BUNDLE" ]]; then
    echo "[+] Building SoundsSource (--debug)..."
    ./scripts/build_app.sh --debug
fi

# Kill any running instance before test
killall "$APP_NAME" 2>/dev/null || true
sleep 1

# Write requested tapped set to defaults
if [[ ${#REQUESTED_TAPS[@]} -eq 0 ]]; then
    defaults write "$APP_DOMAIN" desiredTappedBundleIDs -array
else
    # Format array arguments for defaults write
    DEFAULTS_ARGS=()
    for tap in "${REQUESTED_TAPS[@]}"; do
        DEFAULTS_ARGS+=("$tap")
    done
    defaults write "$APP_DOMAIN" desiredTappedBundleIDs -array "${DEFAULTS_ARGS[@]}"
fi
echo "[+] Set desiredTappedBundleIDs in $APP_DOMAIN"

# Launch app
echo "[+] Launching $APP_BUNDLE..."
open "$APP_BUNDLE"

# Wait for process to spawn
for i in {1..20}; do
    APP_PID=$(pgrep -x "$APP_NAME" || true)
    if [[ -n "$APP_PID" ]]; then
        break
    fi
    sleep 0.5
done

if [[ -z "$APP_PID" ]]; then
    echo "[-] Error: Failed to launch $APP_NAME process."
    exit 1
fi

echo "[+] App launched with PID: $APP_PID"

# Handle Popover Mode
if [[ "$POPOVER_MODE" == "open" ]]; then
    echo "[+] Opening popover..."
    sleep 2
    osascript -e 'tell application "System Events" to tell process "SoundsSource" to click menu bar item 1 of menu bar 1' || true
    sleep 1
elif [[ "$POPOVER_MODE" == "opened_then_closed" ]]; then
    echo "[+] Opening popover for 10 seconds then closing..."
    sleep 2
    osascript -e 'tell application "System Events" to tell process "SoundsSource" to click menu bar item 1 of menu bar 1' || true
    sleep 10
    echo "[+] Closing popover..."
    osascript -e 'tell application "System Events" to tell process "SoundsSource" to click menu bar item 1 of menu bar 1' || true
    sleep 1
fi

# Warmup to reach steady state
echo "[+] Waiting ${WARMUP}s for steady state..."
sleep "$WARMUP"

# Run Profile Mode if enabled
if [[ "$PROFILE" == "true" ]]; then
    SAMPLE_FILE="/tmp/soundssource_sample_${APP_PID}.txt"
    echo "[+] Profile Mode: Running sample $APP_PID 10..."
    sample "$APP_PID" 10 -file "$SAMPLE_FILE" >/dev/null 2>&1 || true

    echo "[+] Profile Mode: Auditing audio IO threads for forbidden RT-safety symbols..."
    PROFILE_OUTPUT=$(python3 -c '
import sys

sample_file = "'"$SAMPLE_FILE"'"
forbidden = [
    "_swift_getGenericMetadata",
    "__swift_instantiateCanonicalPrespecializedGenericMetadata",
    "swift_getTupleTypeMetadata",
    "LockingConcurrentMap"
]

in_io_thread = False
violations = []

try:
    with open(sample_file, "r", errors="ignore") as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                in_io_thread = False
                continue
            if stripped.startswith("Sort by top of stack:") or stripped.startswith("Binary Images:") or stripped.startswith("Sample analysis") or stripped.startswith("Process:"):
                in_io_thread = False
                continue
            if "Thread_" in line:
                in_io_thread = "com.apple.audio.IOThread.client" in line
            elif not line.startswith(" ") and not line.startswith("\t") and not line.startswith("+"):
                in_io_thread = False

            if in_io_thread:
                for sym in forbidden:
                    if sym in line:
                        violations.append((sym, line.strip()))
except Exception as e:
    print(f"Error reading sample file: {e}")

print(f"TOTAL_VIOLATIONS={len(violations)}")
for sym, line in violations:
    print(f"VIOLATION|{sym}|{line}")
')

    VIOLATION_COUNT=$(echo "$PROFILE_OUTPUT" | grep "^TOTAL_VIOLATIONS=" | cut -d= -f2)
    PROFILE_VIOLATIONS_COUNT=${VIOLATION_COUNT:-0}

    if [[ "$PROFILE_VIOLATIONS_COUNT" -gt 0 ]]; then
        echo "========================================="
        echo "[-] PROFILE FAILED: Found $PROFILE_VIOLATIONS_COUNT forbidden RT-safety symbol occurrence(s) on audio IO threads!"
        echo "========================================="
        echo "$PROFILE_OUTPUT" | grep "^VIOLATION|" | head -n 20
        if [[ $(echo "$PROFILE_OUTPUT" | grep -c "^VIOLATION|") -gt 20 ]]; then
            echo "... (and more)"
        fi
        echo "========================================="
    else
        echo "[+] PROFILE PASSED: No forbidden RT-safety symbols found on audio IO threads."
    fi
fi

# Measure CPU time delta
echo "[+] Measuring CPU usage over ${DURATION}s..."

CPU_RESULT=$(python3 -c '
import subprocess, time, sys

pid = '$APP_PID'
duration = '$DURATION'

def get_cputime(p):
    out = subprocess.check_output(["ps", "-p", str(p), "-o", "cputime="]).decode("utf-8").strip()
    days = 0
    if "-" in out:
        d_parts = out.split("-")
        days = int(d_parts[0])
        out = d_parts[1]
    parts = out.split(":")
    if len(parts) == 3:
        return days * 86400 + float(parts[0])*3600 + float(parts[1])*60 + float(parts[2])
    elif len(parts) == 2:
        return days * 86400 + float(parts[0])*60 + float(parts[1])
    else:
        return days * 86400 + float(parts[0])

try:
    t1 = get_cputime(pid)
    time.sleep(duration)
    t2 = get_cputime(pid)
    dt = t2 - t1
    pct = (dt / float(duration)) * 100.0
    print(f"T1={t1:.2f}")
    print(f"T2={t2:.2f}")
    print(f"DELTA_SEC={dt:.2f}")
    print(f"CPU_PCT={pct:.2f}")
except Exception as e:
    print(f"ERROR={e}")
')

T1=$(echo "$CPU_RESULT" | grep "^T1=" | cut -d= -f2)
T2=$(echo "$CPU_RESULT" | grep "^T2=" | cut -d= -f2)
DELTA_SEC=$(echo "$CPU_RESULT" | grep "^DELTA_SEC=" | cut -d= -f2)
CPU_PCT=$(echo "$CPU_RESULT" | grep "^CPU_PCT=" | cut -d= -f2)

if [[ $(echo "$CPU_RESULT" | grep -c "^ERROR=") -gt 0 || -z "$CPU_PCT" || ! "$CPU_PCT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "========================================="
    echo "[-] ERROR: CPU measurement failed!"
    echo "$CPU_RESULT"
    echo "========================================="
    exit 1
fi

echo "========================================="
echo " Measurement Summary"
echo "========================================="
echo "PID               : $APP_PID"
echo "Initial CPU Time  : ${T1}s"
echo "Final CPU Time    : ${T2}s"
echo "CPU Delta Time    : ${DELTA_SEC}s over ${DURATION}s window"
echo "Idle CPU Usage    : ${CPU_PCT}% of one core"
echo "========================================="

if [[ "$PROFILE" == "true" && "$PROFILE_VIOLATIONS_COUNT" -gt 0 ]]; then
    echo "[-] Profile audit failed due to RT-safety symbol violations."
    exit 1
fi

exit 0
