#!/bin/bash
# Generation-ONLY data collection (no Drive upload). Writes each run straight
# to a local directory; uploading to Google Drive is left for a separate step
# (e.g. `rclone move <dir> drive:carla_yolo/<run>`), so generation is never
# blocked waiting on the network.
#
#   $1  local output dir (e.g. /mnt/storage/pylot or a dedicated data dir).
#
# Covers the runs NOT yet collected: start positions 10,20,30,40 x towns 1-5.
# (start position 1 was already collected.) Edit the arrays below to change.

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before running this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <local_output_dir>"
    exit 1
fi

OUT_ROOT="$1"

start_player_nums=(10 20 30 40)
towns=(1 2 3 4 5)

mkdir -p "$OUT_ROOT"

cd $PYLOT_HOME
for pn in ${start_player_nums[@]}; do
    for town in ${towns[@]}; do
        run_name=town0${town}_start${pn}
        out_dir=$OUT_ROOT/$run_name/
        # Skip runs that already have data (lets you resume after a stop).
        if [ -d "$out_dir/center" ] && [ "$(ls -A "$out_dir/center" 2>/dev/null)" ]; then
            echo "[x] $run_name already has data, skipping."
            continue
        fi
        echo "[x] Driving in town $town from start position $pn"
        echo "[x] Starting the CARLA simulator"
        # Headless + low quality + capped VRAM so the GPU stays usable.
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -RenderOffScreen -ResX=1280 -ResY=720 -carla-server -world-port=33333 -benchmark -fps=10 -quality-level=Low &
        sleep 10
        mkdir -p "$out_dir"
        # Minimal YOLO config (center/, bboxes/, tl-bboxes/) at 1280x720.
        TF_FORCE_GPU_ALLOW_GROWTH=true python3 data_gatherer.py --flagfile=configs/yolo_data_gatherer.conf --simulator_spawn_point_index=${pn} --simulator_port=33333 --data_path=${out_dir} --simulator_town=${town} &
        data_gatherer_pid=$!
        # Collect data for an hour.
        sleep 4800
        # Graceful shutdown so in-flight writes finish, then tear down Carla.
        echo "[x] Stopping data gathering..."
        kill -SIGINT $data_gatherer_pid
        wait $data_gatherer_pid 2>/dev/null
        sync
        pkill -9 -f -u $USER CarlaUE4
        sleep 5
        echo "[x] $run_name done ($(du -sh "$out_dir" 2>/dev/null | cut -f1))."
    done
done
echo "[x] All remaining runs generated under $OUT_ROOT."
