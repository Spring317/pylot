#!/bin/bash
# $1 final destination for the data (e.g. a slow/near-full network mount).
# $2 local scratch directory used while collecting (fast local disk).
#    data_gatherer writes here; once a run finishes it is rsynced to $1.

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before sourcing this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <remote_output_dir> <local_scratch_dir>"
    exit 1
fi

REMOTE_DIR="$1"
LOCAL_DIR="$2"

start_player_nums=(1 10 20 30 40)
towns=(1 2 3 4 5)

mkdir -p "$REMOTE_DIR" "$LOCAL_DIR"

cd $PYLOT_HOME
for pn in ${start_player_nums[@]}; do
    for town in ${towns[@]}; do
        echo "[x] Driving in town $town from start position $pn"
        echo "[x] Starting the CARLA simulator"
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -RenderOffScreen -ResX=1920 -ResY=1080 -carla-server -world-port=33333 -benchmark -fps=10 &
        sleep 10
        run_name=town0${town}_start${pn}
        out_dir=$LOCAL_DIR/$run_name/
        mkdir -p "$out_dir"
        python3 data_gatherer.py --flagfile=configs/data_gatherer.conf --simulator_spawn_point_index=${pn} --simulator_port=33333 --data_path=${out_dir} --simulator_town=${town} &
        data_gatherer_pid=$!
        # Collect data for an hour.
        sleep 4800
        # Ask data_gatherer to shut down gracefully so it stops cleanly
        # (lets in-flight writes finish) instead of being killed mid-write.
        echo "[x] Stopping data gathering..."
        kill -SIGINT $data_gatherer_pid
        wait $data_gatherer_pid 2>/dev/null
        # Flush OS write buffers before tearing down Carla.
        sync
        pkill -9 -f -u $USER CarlaUE4
        sleep 5

        # Move the run off local scratch onto the (slow/near-full) remote.
        # --remove-source-files deletes each file locally only after it has
        # been copied, so if the remote runs out of space mid-transfer,
        # whatever didn't fit simply stays on local disk for a later retry
        # instead of being lost.
        echo "[x] Syncing $run_name to $REMOTE_DIR..."
        mkdir -p "$REMOTE_DIR/$run_name"
        if rsync -a --remove-source-files "$out_dir" "$REMOTE_DIR/$run_name/"; then
            find "$out_dir" -depth -type d -empty -delete
            echo "[x] $run_name fully synced and cleared from local scratch."
        else
            echo "[!] WARNING: sync of $run_name to $REMOTE_DIR did not complete" \
                 "(remote may be out of space). Remaining files are still in $out_dir" \
                 "-- rerun: rsync -a --remove-source-files $out_dir $REMOTE_DIR/$run_name/"
        fi
    done
done
