# Modular autonomous-driving pipeline

A full self-driving stack assembled from **one flagfile per module**. Each stage
is self-contained and swappable; the master flagfile (`av_modular.conf`) just
composes them. This mirrors Pylot's ERDOS component design — every module is an
independent operator (or set of operators) connected by streams.

## The modules (dependency order)

| File | Module | Implementation | Torch? | Swap to |
|------|--------|----------------|--------|---------|
| `10_simulator.conf` | Simulator / sensors | CARLA + perfect depth | no | real depth (AnyNet/lidar) |
| `20_perception_detection.conf` | Perception · detection | **YOLOv8** (your model) | via ultralytics | efficientdet / faster-rcnn |
| `30_perception_tracking.conf` | Perception · tracking | **SORT** | no | deep_sort / da_siam_rpn / center_track |
| `40_prediction.conf` | Prediction | **linear** | no | r2p2 |
| `50_planning.conf` | Planning | **Frenet** | no | rrt_star / hybrid_astar / waypoint |
| `60_control.conf` | Control | **PID** | no | mpc |

Data flow:

```
detect (YOLO) -> track (SORT) -> predict (linear) -> plan (Frenet) -> control (PID)
```

The only module that touches PyTorch is YOLO detection (through Ultralytics).
Every other stage is torch-free, so this pipeline runs on the torch 1.13 env
without depending on the legacy neural operators (CenterTrack/AnyNet/R2P2/DRN).

## Run it

```bash
# 1. start the simulator (separate terminal)
./scripts/run_simulator.sh

# 2. run the modular pipeline from $PYLOT_HOME
python3 pylot.py --flagfile=configs/modular/av_modular.conf
```

Prerequisites:
- Trained YOLO weights at `dependencies/models/obstacle_detection/yolo/best.pt`
  (path set in `20_perception_detection.conf`).
- An env with `ultralytics` + torch 1.13 (see project notes on the torch upgrade).

## Swap a module

Modularity is the point: to change one stage, touch only its file. Examples —

```bash
# use the neural tracker instead of SORT
#   edit 30_perception_tracking.conf:  --tracker_type=center_track

# use RRT* instead of Frenet
#   edit 50_planning.conf:             --planning_type=rrt_star

# use MPC instead of PID
#   edit 60_control.conf:              --control=mpc
```

Or compose a different system on the command line (absl reads multiple
flagfiles left-to-right, later values win):

```bash
python3 pylot.py \
    --flagfile=configs/modular/10_simulator.conf \
    --flagfile=configs/modular/20_perception_detection.conf \
    --flagfile=configs/modular/30_perception_tracking.conf \
    --flagfile=configs/modular/40_prediction.conf \
    --flagfile=configs/modular/50_planning.conf \
    --flagfile=configs/modular/60_control.conf
```

## Test each module in isolation

Because every stage is its own flagfile, you can bring the pipeline up
incrementally and confirm each module before adding the next:

```bash
python3 pylot.py --flagfile=configs/modular/10_simulator.conf \
                 --flagfile=configs/modular/20_perception_detection.conf
# add 30_, then 40_, then 50_, then 60_ one at a time
```
