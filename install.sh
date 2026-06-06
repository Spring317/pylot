#!/bin/bash
set -e

if [ -z "$PYLOT_HOME" ] ; then
    PYLOT_HOME=$(pwd)
    echo "WARNING: \$PYLOT_HOME is not set; Setting it to ${PYLOT_HOME}"
else
    echo "INFO: \$PYLOT_HOME is set to ${PYLOT_HOME}"
fi

###############################################################################
# Prerequisites check
###############################################################################
# The following system libraries are expected to be available on the cluster
# (e.g. via `module load` or pre-installed). The script will warn if key
# binaries are missing but will NOT attempt to install them.
echo "=== Checking prerequisites ==="
for cmd in git wget cmake unzip python3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: '$cmd' is not available. Please install or 'module load' it before running this script."
        exit 1
    fi
done
echo "All required binaries found."

###############################################################################
# Create and activate a Python virtual environment
###############################################################################
VENV_DIR="${PYLOT_HOME}/venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "=== Creating Python venv at ${VENV_DIR} ==="
    python3 -m venv "$VENV_DIR"
else
    echo "=== Reusing existing venv at ${VENV_DIR} ==="
fi

# Activate the venv — all pip installs below go into it
source "${VENV_DIR}/bin/activate"
echo "INFO: Using python at $(which python3) ($(python3 --version))"

# Upgrade pip inside the venv
python3 -m pip install --upgrade pip setuptools wheel

###############################################################################
# Install Python dependencies into the venv
###############################################################################
echo "=== Installing Python dependencies ==="
python3 -m pip install gdown
python3 -m pip install -r "${PYLOT_HOME}/requirements.txt"

###############################################################################
# Get models & code bases we depend on
###############################################################################
cd "$PYLOT_HOME/dependencies/"

###### Download the model weights ######
echo "[x] Downloading all model weights..."
cd "$PYLOT_HOME/dependencies/"
gdown https://drive.google.com/uc?id=1rQKFDxGDFi3rBLsMrJzb7oGZvvtwgyiL
unzip models.zip ; rm models.zip

#################### Download the code bases ####################
echo "[x] Compiling the planners..."

###### Build the FrenetOptimalTrajectory Planner ######
echo "[x] Compiling the Frenet Optimal Trajectory planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "frenet_optimal_trajectory_planner" ]; then
    git clone https://github.com/erdos-project/frenet_optimal_trajectory_planner.git
fi
cd frenet_optimal_trajectory_planner/
bash build.sh

###### Build the RRT* Planner ######
echo "[x] Compiling the RRT* planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "rrt_star_planner" ]; then
    git clone https://github.com/erdos-project/rrt_star_planner.git
fi
cd rrt_star_planner/
bash build.sh

###### Build the Hybrid A* Planner ######
echo "[x] Compiling the Hybrid A* planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "hybrid_astar_planner" ]; then
    git clone https://github.com/erdos-project/hybrid_astar_planner.git
fi
cd hybrid_astar_planner/
bash build.sh

###### Clone the Prediction Repository #####
echo "[x] Cloning the prediction code..."
cd "$PYLOT_HOME/pylot/prediction/"
if [ ! -d "prediction" ]; then
    git clone https://github.com/erdos-project/prediction.git
fi

###### Get DeepSORT and SORT tracker code bases ######
echo "[x] Cloning the object tracking code..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "nanonets_object_tracking" ]; then
    git clone https://github.com/ICGog/nanonets_object_tracking.git
fi
if [ ! -d "sort" ]; then
    git clone https://github.com/ICGog/sort.git
fi

###### Download the DaSiamRPN code ######
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "DaSiamRPN" ]; then
    git clone https://github.com/ICGog/DaSiamRPN.git
fi

###### Install CenterTrack ######
echo "[x] Installing the CenterTrack object tracking code..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "CenterTrack" ]; then
    git clone https://github.com/ICGog/CenterTrack
    cd CenterTrack/src/lib/model/networks/
    git clone https://github.com/CharlesShang/DCNv2/
    cd DCNv2
    # Set LLVM_CONFIG if llvm-config is available under a versioned name
    if command -v llvm-config &> /dev/null; then
        export LLVM_CONFIG=$(which llvm-config)
    elif command -v llvm-config-9 &> /dev/null; then
        export LLVM_CONFIG=$(which llvm-config-9)
    else
        echo "WARNING: llvm-config not found; DCNv2 build may fail."
    fi
    python3 setup.py build develop
fi

###### Install QDTrack ######
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "qdtrack" ]; then
    git clone https://github.com/mageofboy/qdtrack.git
fi
cd "$PYLOT_HOME/dependencies/qdtrack"
python3 -m pip install mmcv==1.3.10 mmdet==2.14.0
python3 -m pip install -e ./

##### Download the Lanenet code #####
echo "[x] Cloning the lanenet lane detection code..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "lanenet" ]; then
    git clone https://github.com/ICGog/lanenet-lane-detection.git
    mv lanenet-lane-detection lanenet
fi

###### Download the DRN segmentation code ######
echo "[x] Cloning the DRN segmentation code..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "drn" ]; then
    git clone https://github.com/ICGog/drn.git
fi

###### Download AnyNet depth estimation code #####
echo "[x] Cloning the AnyNet depth estimation code..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "AnyNet" ]; then
    git clone https://github.com/mileyan/AnyNet.git
fi
cd AnyNet/models/spn_t1/
python3 setup.py clean
python3 setup.py build

###### Download the Carla simulator ######
echo "[x] Downloading the CARLA 0.9.10.1 simulator..."
cd "$PYLOT_HOME/dependencies/"
if [ "$1" != 'challenge' ] && [ ! -d "CARLA_0.9.10.1" ]; then
    mkdir CARLA_0.9.10.1
    cd CARLA_0.9.10.1
    wget https://carla-releases.s3.eu-west-3.amazonaws.com/Linux/CARLA_0.9.10.1.tar.gz
    tar -xvf CARLA_0.9.10.1.tar.gz
    rm CARLA_0.9.10.1.tar.gz
fi

echo ""
echo "========================================"
echo " Installation complete!"
echo " To use pylot, activate the venv first:"
echo "   source ${VENV_DIR}/bin/activate"
echo "========================================"
