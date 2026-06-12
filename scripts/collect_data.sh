#!/bin/bash
# $1 path where to save the data.

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before sourcing this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

start_player_nums=(1 10 20 30 40)
towns=(1 2 3 4 5)

# Wait until a directory's total size stops changing, i.e. all buffered
# writes have actually been flushed to the (possibly slow/networked) mount.
# Polls every $2 seconds and requires $3 consecutive stable readings.
wait_for_flush() {
    local dir="$1"
    local interval="${2:-10}"
    local stable_needed="${3:-3}"
    local stable_count=0
    local last_size=-1
    echo "[x] Waiting for $dir to finish flushing to disk..."
    while [ $stable_count -lt $stable_needed ]; do
        sleep "$interval"
        local size=$(du -sb "$dir" 2>/dev/null | cut -f1)
        if [ "$size" == "$last_size" ]; then
            stable_count=$((stable_count + 1))
        else
            stable_count=0
        fi
        last_size=$size
    done
    echo "[x] $dir is fully flushed (size stable at ${last_size} bytes)."
}

cd $PYLOT_HOME
for pn in ${start_player_nums[@]}; do
    for town in ${towns[@]}; do
        echo "[x] Driving in town $town from start position $pn"
        echo "[x] Starting the CARLA simulator"
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -windowed -ResX=1920 -ResY=1080 -carla-server -benchmark -fps=10 &
        sleep 10
        out_dir=$1/town0${town}_start${pn}/
        mkdir "$out_dir"
        python3 data_gatherer.py --flagfile=configs/data_gatherer.conf --simulator_spawn_point_index=${pn} --data_path=${out_dir} --simulator_town=${town} &
        data_gatherer_pid=$!
        # Collect data for an hour.
        sleep 4800
        # Ask data_gatherer to shut down gracefully so it stops cleanly
        # (lets in-flight writes finish) instead of being killed mid-write.
        echo "[x] Stopping data gathering..."
        kill -SIGINT $data_gatherer_pid
        wait $data_gatherer_pid 2>/dev/null
        # Flush OS write buffers, then wait for the (slow/networked) output
        # directory to stop growing before tearing down Carla.
        sync
        wait_for_flush "$out_dir"
        # Kill Carla now that all data has been written out.
        pkill -9 -f -u $USER CarlaUE4
        sleep 5
    done
done
