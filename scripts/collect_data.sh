#!/bin/bash
# Two-stage data collection:
#   $1  rclone destination for the finished data, e.g. "drive:carla_yolo".
#       This is an rclone remote:path, NOT a filesystem path -- do not point
#       it at the FUSE mount: rsync/writes into the rclone mount fail with
#       "Input/output error", so each run is uploaded with `rclone move`.
#   $2  local SSD scratch dir used while collecting; each finished run is
#       moved from here to $1 with rclone and cleared off the SSD.

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before sourcing this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <rclone_dest e.g. drive:carla_yolo> <local_ssd_scratch_dir>"
    exit 1
fi

RCLONE_DEST="$1"
LOCAL_DIR="$2"

start_player_nums=(1 10 20 30 40)
towns=(1 2 3 4 5)

mkdir -p "$LOCAL_DIR"

cd $PYLOT_HOME
for pn in ${start_player_nums[@]}; do
    for town in ${towns[@]}; do
        echo "[x] Driving in town $town from start position $pn"
        echo "[x] Starting the CARLA simulator"
        # -quality-level=Low keeps CARLA's UE4 VRAM footprint small so the GPU
        # stays usable for other work.
        SDL_VIDEODRIVER=offscreen ${CARLA_HOME}/CarlaUE4.sh -opengl /Game/Carla/Maps/Town0${town} -RenderOffScreen -ResX=1280 -ResY=720 -carla-server -world-port=33333 -benchmark -fps=10 -quality-level=Low &
        sleep 10
        run_name=town0${town}_start${pn}
        # Stage 1: data_gatherer writes to the fast local SSD scratch dir.
        out_dir=$LOCAL_DIR/$run_name/
        mkdir -p "$out_dir"
        # TF_FORCE_GPU_ALLOW_GROWTH stops TensorFlow from pre-allocating the
        # whole GPU; it only grows VRAM as needed.
        # Use the minimal YOLO config: logs only center RGB + obstacle/TL
        # bounding boxes (center/, bboxes/, tl-bboxes/) at 1280x720. This is
        # all convert_carla_to_yolo.py needs, and dropping the segmentation/
        # depth/lidar/stereo/tracker operators keeps the ERDOS lattice from
        # overflowing ("operator events queued in lattice" warning).
        TF_FORCE_GPU_ALLOW_GROWTH=true python3 data_gatherer.py --flagfile=configs/yolo_data_gatherer.conf --simulator_spawn_point_index=${pn} --simulator_port=33333 --data_path=${out_dir} --simulator_town=${town} &
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

        # Stage 2: upload the finished run to Google Drive with rclone talking
        # to the Drive API directly (NOT rsync into the FUSE mount, which fails
        # with "Input/output error"). `rclone move` deletes each local file
        # only after a verified upload, so an interrupted transfer just leaves
        # the rest on the SSD for a retry.
        echo "[x] Uploading $run_name to $RCLONE_DEST ..."
        if rclone move "$out_dir" "$RCLONE_DEST/$run_name/" \
                --transfers=4 --checkers=8 --retries=10 \
                --delete-empty-src-dirs --stats=30s; then
            echo "[x] $run_name uploaded to Google Drive and cleared from SSD."
        else
            echo "[!] WARNING: upload of $run_name to $RCLONE_DEST did not finish." \
                 "Remaining files are still in $out_dir -- retry with:" \
                 "rclone move $out_dir $RCLONE_DEST/$run_name/ --delete-empty-src-dirs"
        fi
    done
done
