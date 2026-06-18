#!/bin/bash
# Background drainer for generation-only collection.
# Periodically uploads COMPLETED local runs to Drive and deletes them from the
# SSD, so the disk never fills while collect_data_local.sh keeps generating.
#
#   $1  local output dir   (default /mnt/storage/pylot)
#   $2  rclone destination (default drive:carla_yolo)
#
# Safety: only touches start positions 10/20/30/40 (the runs
# collect_data_local.sh produces), leaving the start1 recovery/drain jobs
# alone. A run is uploaded only when "stable" -- no file modified in the last
# 10 minutes -- so the run currently being collected is never touched.

OUT_ROOT="${1:-/mnt/storage/pylot}"
DEST="${2:-drive:carla_yolo}"

while true; do
    for d in "$OUT_ROOT"/town0*_start{10,20,30,40}/; do
        [ -d "$d" ] || continue
        run=$(basename "$d")
        # Must contain collected frames.
        [ -d "$d/center" ] && [ -n "$(ls -A "$d/center" 2>/dev/null)" ] || continue
        # Stable? Skip if anything was written in the last 10 minutes.
        if [ -n "$(find "$d" -type f -newermt '-10 min' 2>/dev/null | head -1)" ]; then
            continue
        fi
        echo "$(date '+%F %H:%M:%S') [drain] uploading $run -> $DEST/$run ..."
        if rclone move "$d" "$DEST/$run" --delete-empty-src-dirs \
                --transfers=16 --checkers=16 --retries=10 --stats=60s; then
            echo "$(date '+%F %H:%M:%S') [drain] $run uploaded and cleared from SSD."
        else
            echo "$(date '+%F %H:%M:%S') [drain] $run upload FAILED; will retry next pass."
        fi
    done
    sleep 300
done
