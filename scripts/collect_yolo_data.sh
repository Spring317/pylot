#!/bin/bash
# $1 path where to save the YOLO training data.

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before sourcing this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

spawn_points=(0 25)
towns=(1 2 3 4 5)

cd $PYLOT_HOME
for town in ${towns[@]}; do
    for sp in ${spawn_points[@]}; do
        echo "[x] Driving in town $town from spawn point $sp"
        echo "[x] Starting the CARLA simulator"
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -windowed -ResX=1280 -ResY=720 -carla-server -benchmark -fps=10 &
        sleep 10
        mkdir -p $1/town0${town}_start${sp}/
        python3 data_gatherer.py --flagfile=configs/yolo_data_gatherer.conf --carla_spawn_point_index=${sp} --data_path=$1/town0${town}_start${sp}/ --simulator_town=${town} &
        # Collect data for 300 seconds (~120 frames per run at 2 fps).
        sleep 300
        # Kill data gathering script and Carla.
        pkill -9 -f -u $USER data_gatherer
        pkill -9 -f -u $USER CarlaUE4
        sleep 5
    done
done
