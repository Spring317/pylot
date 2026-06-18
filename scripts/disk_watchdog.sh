#!/bin/bash
# Disk safety watchdog for generation-only collection.
# Pauses the data_gatherer writer processes (SIGSTOP) when free space on the
# SSD drops below FLOOR_GB, and resumes them (SIGCONT) once the drainer has
# freed space back above RESUME_GB. CARLA runs in synchronous mode, so freezing
# the client cleanly halts the whole sim (and thus all disk writes) without
# losing the in-progress run. This makes generation self-throttle to the upload
# speed and prevents any disk-full crash.
#
#   $1  mount to watch     (default /mnt/storage)
#   $2  pause below N GB    (default 12)
#   $3  resume above N GB   (default 25)

MOUNT="${1:-/mnt/storage}"
FLOOR_GB="${2:-12}"
RESUME_GB="${3:-25}"
paused=0

free_gb() { df -BG --output=avail "$MOUNT" 2>/dev/null | tail -1 | tr -dc '0-9'; }
gatherer_pids() { pgrep -f 'python3 data_gatherer' 2>/dev/null; }

echo "$(date '+%F %H:%M:%S') [watchdog] watching $MOUNT  floor=${FLOOR_GB}G resume=${RESUME_GB}G"
while true; do
    avail=$(free_gb)
    [ -z "$avail" ] && { sleep 30; continue; }
    if [ "$paused" -eq 0 ] && [ "$avail" -lt "$FLOOR_GB" ]; then
        pids=$(gatherer_pids)
        if [ -n "$pids" ]; then
            echo "$(date '+%F %H:%M:%S') [watchdog] free ${avail}G < ${FLOOR_GB}G -> PAUSING generation"
            kill -STOP $pids 2>/dev/null
            paused=1
        fi
    elif [ "$paused" -eq 1 ] && [ "$avail" -gt "$RESUME_GB" ]; then
        echo "$(date '+%F %H:%M:%S') [watchdog] free ${avail}G > ${RESUME_GB}G -> RESUMING generation"
        kill -CONT $(gatherer_pids) 2>/dev/null
        paused=0
    fi
    sleep 30
done
