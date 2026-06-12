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

if [ -z "$1" ]; then
    echo "Usage: $0 <output_dir>"
    exit 1
fi

start_player_nums=(1 10 20 30 40)
towns=(1 2 3 4 5)

mkdir -p "$1"

cd $PYLOT_HOME
for pn in ${start_player_nums[@]}; do
    for town in ${towns[@]}; do
        echo "[x] Driving in town $town from start position $pn"
        echo "[x] Starting the CARLA simulator"
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -RenderOffScreen -ResX=1920 -ResY=1080 -carla-server -world-port=33333 -benchmark -fps=10 &
        sleep 10
        out_dir=$1/town0${town}_start${pn}/
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
    done
done
