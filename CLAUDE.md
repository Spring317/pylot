# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Pylot is a modular autonomous-vehicle platform (ERDOS-based dataflow) for
perception, prediction, planning, and control, running on top of the CARLA
0.9.10.1 simulator (or real-world cars, e.g. Lincoln MKZ). Each component
(detection, tracking, lane detection, segmentation, prediction, planning,
control) is implemented as one or more ERDOS operators connected via streams.

## Environment setup

- Uses a conda environment (Python 3.7) defined in `environment.yml`. Run
  `./install.sh` to create/update the `pylot` conda env, build the planners
  (Frenet, RRT*, Hybrid A*), clone tracking/segmentation/depth dependencies
  into `dependencies/`, and `pip install -e .` the project.
- Activate with `conda activate pylot` before running anything.
- `export CARLA_HOME=$PYLOT_HOME/dependencies/CARLA_0.9.10.1/` and source
  `scripts/set_pythonpath.sh` before running pylot.
- The original Faster-RCNN/EfficientDet model archive download is broken
  (404). The YOLO obstacle detector (`--obstacle_detector_model=yolo`) is the
  supported path for new model training — see "YOLO training workflow" below.

## Running Pylot

Start the simulator first (separate terminal):
```console
./scripts/run_simulator.sh
```

Then run a pipeline via flagfile-based configs in `configs/`:
```console
python3 pylot.py --flagfile=configs/detection.conf
python3 pylot.py --flagfile=configs/demo.conf          # full pipeline + driving policy
python3 pylot.py --flagfile=configs/yolo_detection.conf
```
`configs/scenarios/` contains configs for specific CARLA scenarios (used with
`scenario_runner.py`). Visualization is enabled with
`--visualize_detected_obstacles` (requires X forwarding / pygame).

Entry point is `pylot.py`: `driver()` wires together the dataflow graph by
calling into `pylot/component_creator.py` (decides *which* sub-pipelines to
build based on flags) and `pylot/operator_creator.py` (creates the individual
ERDOS operators and connects streams). `lincoln.py` is the analogous driver
for the real Lincoln MKZ vehicle.

## Tests

```console
pytest tests/
```
Individual checks: `tests/check_canny_lane_detection.py`,
`tests/check_lanenet_lane_detection.py`, `tests/check_3d_2d_conversions.py`,
`tests/test_point_cloud.py`, `tests/test_sensor_setup.py`,
`tests/test_transforms.py`. `tests/mocked_carla.py` provides a mocked CARLA
module so tests don't need a running simulator.
`tests/test_determinism.sh` runs full scenario-based determinism experiments
against a live simulator (not a unit test).

## Code style

Formatted with yapf using `.style.yapf` (pep8-based,
`allow_split_before_dict_value=False`, `join_multiple_lines=False`).

## Architecture: dataflow / flags / components

- **`pylot/flags.py`** defines the global absl flags (imports per-module
  flags from `pylot/{control,debug,perception,planning,prediction,simulation}/flags.py`).
  Almost all behavior is controlled by `--flagfile=configs/*.conf` combined
  with command-line flag overrides — there is no other config mechanism.
- **`pylot/component_creator.py`** is the high-level decision layer: each
  `add_<component>(...)` function reads flags (e.g. `FLAGS.obstacle_detection`,
  `FLAGS.obstacle_detector_model`, `FLAGS.planning_type`) and decides which
  operators to wire up, returning the output stream(s).
- **`pylot/operator_creator.py`** is the low-level layer: each `add_<operator>`
  function builds an `erdos.OperatorConfig` and calls `erdos.connect(...)` to
  instantiate a specific operator class and wire its input/output streams.
  Operator implementations live in `pylot/<area>/*_operator.py` (e.g.
  `pylot/perception/detection/detection_operator.py`,
  `pylot/planning/planning_operator.py`).
- **`pylot.py:driver()`** assembles the full simulation pipeline by chaining
  component_creator calls in dependency order (sensors → detection → tracking
  → prediction → planning → control → visualization), then runs the ERDOS
  graph with `erdos.run_async`.
- **`dependencies/`** contains vendored/cloned third-party code (CenterTrack,
  DaSiamRPN, SORT, nanonets DeepSORT, qdtrack, planners) — these are separate
  git repos cloned by `install.sh`, not part of the pylot package itself.
  Planner C++ code (Frenet, RRT*, Hybrid A*) is built via CMake and exposed to
  Python through `dependencies/*/setup.py` bindings.

## YOLO training workflow

Since the original detection model weights are unavailable, the supported way
to get an obstacle detector working is:
1. `bash scripts/collect_yolo_data.sh /path/to/raw_data` — collect CARLA data
   (requires `$PYLOT_HOME`, `$CARLA_HOME`, and a running simulator).
2. `python scripts/convert_carla_to_yolo.py --data_dirs <dirs> --output_dir <out>`
   — converts CARLA bbox JSON annotations into YOLO format + `dataset.yaml`.
3. `python scripts/train_yolo.py --dataset <out> --model yolov8s.pt --epochs 100`
   — trains via Ultralytics YOLOv8; best weights land in
   `runs/yolo_carla/train/weights/best.pt`.
4. Copy `best.pt` to `dependencies/models/obstacle_detection/yolo/best.pt` and
   run with `--obstacle_detection_model=yolo
   --yolo_detection_model_path=dependencies/models/obstacle_detection/yolo/best.pt`
   (see `configs/yolo_detection.conf`).
