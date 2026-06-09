#!/bin/bash
# Collect YOLO training data from CARLA across multiple towns and spawn points.
#
# Usage:
#   bash scripts/collect_yolo_data.sh <output_dir> [collect_seconds] [carla_wait_seconds]
#
# Arguments:
#   output_dir        Where to save the data (required).
#   collect_seconds   How long to collect per run, default 1800 (30 min).
#                     Use a larger value to gather more data per run.
#   carla_wait_seconds  How long to wait for CARLA to finish loading before
#                     launching data_gatherer, default 60 s.
#
# Examples:
#   bash scripts/collect_yolo_data.sh data/yolo_raw           # 30 min per run
#   bash scripts/collect_yolo_data.sh data/yolo_raw 3600      # 60 min per run
#   bash scripts/collect_yolo_data.sh data/yolo_raw 7200 90   # 2 h per run, 90 s wait

if [ -z "$PYLOT_HOME" ]; then
    echo "Please set \$PYLOT_HOME before running this script"
    exit 1
fi

if [ -z "$CARLA_HOME" ]; then
    echo "Please set \$CARLA_HOME before running this script"
    exit 1
fi

OUTPUT_DIR="${1:?Usage: $0 <output_dir> [collect_seconds] [carla_wait_seconds]}"
COLLECT_SECS="${2:-1800}"    # default: 30 minutes per run
CARLA_WAIT="${3:-60}"        # default: 60 s for CARLA to load

spawn_points=(0 25)
towns=(1 2 3 4 5)

# Approximate frame yield: simulator runs ~20 fps, log_every_nth_message=5 → ~4 fps
# but CARLA's synchronous pipeline is slower; observed ~28 frames/min on this machine.
APPROX_FRAMES=$(( COLLECT_SECS * 28 / 60 ))

echo "========================================"
echo " YOLO data collection"
echo " Output : $OUTPUT_DIR"
echo " Per run: ${COLLECT_SECS}s (~${APPROX_FRAMES} frames)"
echo " Runs   : ${#towns[@]} towns x ${#spawn_points[@]} spawn points = $(( ${#towns[@]} * ${#spawn_points[@]} )) runs"
TOTAL_SECS=$(( (COLLECT_SECS + CARLA_WAIT + 15) * ${#towns[@]} * ${#spawn_points[@]} ))
echo " Est. total time: $(( TOTAL_SECS / 3600 ))h $(( (TOTAL_SECS % 3600) / 60 ))m"
echo "========================================"

cd "$PYLOT_HOME"
for town in "${towns[@]}"; do
    for sp in "${spawn_points[@]}"; do
        echo ""
        echo "[x] Town $town, spawn point $sp  (${COLLECT_SECS}s collection window)"
        echo "[x] Starting the CARLA simulator"
        SDL_VIDEODRIVER=offscreen "${CARLA_HOME}/CarlaUE4.sh" \
            -opengl "/Game/Carla/Maps/Town0${town}" \
            -windowed -ResX=1280 -ResY=720 \
            -carla-server -benchmark -fps=10 &

        echo "[x] Waiting ${CARLA_WAIT}s for CARLA to finish loading..."
        sleep "$CARLA_WAIT"

        mkdir -p "$OUTPUT_DIR/town0${town}_start${sp}/"
        echo "[x] Starting data_gatherer"
        python3 data_gatherer.py \
            --flagfile=configs/yolo_data_gatherer.conf \
            --simulator_spawn_point_index="${sp}" \
            --data_path="$OUTPUT_DIR/town0${town}_start${sp}/" \
            --simulator_town="${town}" &

        # Collect for the requested window, then tear down.
        sleep "$COLLECT_SECS"

        echo "[x] Stopping data_gatherer and CARLA"
        pkill -9 -f -u "$USER" data_gatherer
        pkill -9 -f -u "$USER" CarlaUE4
        sleep 5

        # Report what was collected in this run.
        N=$(ls "$OUTPUT_DIR/town0${town}_start${sp}/center/" 2>/dev/null | wc -l)
        echo "    Collected $N frames in town0${town}_start${sp}"
    done
done

echo ""
echo "========================================"
echo " Collection complete."
TOTAL_FRAMES=$(find "$OUTPUT_DIR" -name "center-*.png" 2>/dev/null | wc -l)
echo " Total frames across all runs: $TOTAL_FRAMES"
echo " Next step:"
echo "   DATA_DIRS=\$(ls -d $OUTPUT_DIR/*/ | tr '\\n' ',' | sed 's/,\$//')"
echo "   python3 scripts/convert_carla_to_yolo.py --data_dirs \"\$DATA_DIRS\" \\"
echo "       --output_dir data/yolo_dataset --include_traffic_lights"
echo "========================================"
