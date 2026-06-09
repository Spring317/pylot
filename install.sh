#!/bin/bash
set -e

if [ -z "$PYLOT_HOME" ] ; then
    PYLOT_HOME=$(pwd)
    echo "WARNING: \$PYLOT_HOME is not set; Setting it to ${PYLOT_HOME}"
else
    echo "INFO: \$PYLOT_HOME is set to ${PYLOT_HOME}"
fi

###############################################################################
# Conda environment setup
###############################################################################
# Conda provides python, cmake, compilers, llvm, and system libraries
# all without sudo — perfect for HPC clusters.
###############################################################################

CONDA_ENV_NAME="pylot"

# Try to initialize conda if it's not already available.
# `conda` is a shell function injected by `conda init` (via ~/.bashrc),
# which doesn't run in non-interactive shells (e.g. `bash install.sh`).
# Auto-detect the conda installation and initialize it.
if ! command -v conda &> /dev/null; then
    # Search common locations for the conda binary
    for _conda_bin in \
        "$CONDA_EXE" \
        "$HOME/miniconda3/bin/conda" \
        "$HOME/miniforge3/bin/conda" \
        "$HOME/anaconda3/bin/conda" \
        "$(find /storage/$(whoami) -maxdepth 3 -name conda -path "*/bin/conda" 2>/dev/null | head -1)"
    do
        if [ -x "$_conda_bin" ]; then
            eval "$("$_conda_bin" shell.bash hook)"
            break
        fi
    done
    unset _conda_bin
fi

# Check that conda is available
if ! command -v conda &> /dev/null; then
    echo "ERROR: 'conda' is not available."
    echo "Install Miniconda (no sudo needed) from:"
    echo "  https://docs.conda.io/en/latest/miniconda.html"
    echo ""
    echo "Quick install:"
    echo "  wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    echo "  bash Miniconda3-latest-Linux-x86_64.sh -b -p \$HOME/miniconda3"
    echo "  eval \"\$(\$HOME/miniconda3/bin/conda shell.bash hook)\""
    exit 1
fi

# Create the conda environment if it doesn't exist
if ! conda env list | grep -qw "$CONDA_ENV_NAME"; then
    echo "=== Creating conda environment '${CONDA_ENV_NAME}' ==="
    conda env create -f "${PYLOT_HOME}/environment.yml"
else
    echo "=== Conda environment '${CONDA_ENV_NAME}' already exists ==="
    echo "=== Updating conda environment '${CONDA_ENV_NAME}' ==="
    conda env update -f "${PYLOT_HOME}/environment.yml"
fi

# Activate the conda environment
eval "$(conda shell.bash hook)"
conda activate "$CONDA_ENV_NAME"
echo "INFO: Using python at $(which python3) ($(python3 --version))"
echo "INFO: Using cmake at $(which cmake) ($(cmake --version | head -1))"

# nvcc strictly looks for 'gcc' and 'g++' in the PATH (ignoring CC/CXX).
# If the system gcc is too new (e.g., GCC 14), nvcc will reject it.
# We symlink conda's gcc-7 to 'gcc' and 'g++' in the conda bin directory.
if [ -x "$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-cc" ]; then
    ln -sf "$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-cc" "$CONDA_PREFIX/bin/gcc"
    ln -sf "$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-c++" "$CONDA_PREFIX/bin/g++"
    echo "INFO: Symlinked conda's GCC to 'gcc' and 'g++' for nvcc compatibility."
fi

# Disable conda's compiler_compat/ld globally for all native builds.
# This linker has hardcoded references to /lib64/libpthread.so.0 which
# doesn't exist on modern glibc (>=2.34, where libpthread merged into libc).
# All setup.py / pip install builds that compile C extensions will fail
# without this. The cmake-based planner builds are unaffected (they use
# the cross-toolchain linker directly).
if [ -f "$CONDA_PREFIX/compiler_compat/ld" ] && [ ! -f "$CONDA_PREFIX/compiler_compat/ld.bak" ]; then
    mv "$CONDA_PREFIX/compiler_compat/ld" "$CONDA_PREFIX/compiler_compat/ld.bak"
    echo "INFO: Disabled compiler_compat/ld (modern glibc workaround)"
fi

# Set CUDA_HOME for PyTorch C++ / CUDA extensions (DCNv2, AnyNet, etc.).
# PyTorch's cpp_extension.py requires this to find nvcc and CUDA headers.
if [ -z "$CUDA_HOME" ]; then
    if [ -x "$CONDA_PREFIX/bin/nvcc" ]; then
        export CUDA_HOME="$CONDA_PREFIX"
    elif [ -d "/usr/local/cuda" ]; then
        export CUDA_HOME="/usr/local/cuda"
    fi
fi
if [ -n "$CUDA_HOME" ]; then
    echo "INFO: CUDA_HOME=$CUDA_HOME (nvcc: $(command -v nvcc 2>/dev/null || echo 'not on PATH'))"
else
    echo "WARNING: CUDA_HOME not set and nvcc not found."
    echo "         CUDA extension builds (DCNv2, AnyNet) will fail."
    echo "         Install with:  conda install -c conda-forge cudatoolkit-dev"
fi

# PyTorch 1.4.0 does not recognize modern Ampere/Ada GPUs (compute capability 8.x/9.x).
# Explicitly set the CUDA arch list so it doesn't fail when querying the host GPU.
export TORCH_CUDA_ARCH_LIST="6.0;6.1;7.0;7.5"

###############################################################################
# Get models & code bases we depend on
###############################################################################
cd "$PYLOT_HOME/dependencies/"

###### Model weights ######
# NOTE: The original Google Drive model archive (id=1rQKFDxGDFi3rBLsMrJzb7oGZvvtwgyiL)
# is no longer available (HTTP 404). To use the YOLO-based obstacle detector instead:
#
#   1. Collect data from CARLA:
#        bash scripts/collect_yolo_data.sh /path/to/raw_data
#
#   2. Convert to YOLO format:
#        python scripts/convert_carla_to_yolo.py \
#            --data_dirs /path/to/raw_data/town01_start0,... \
#            --output_dir dependencies/datasets/yolo_dataset
#
#   3. Train YOLO:
#        python scripts/train_yolo.py \
#            --dataset dependencies/datasets/yolo_dataset \
#            --model yolov8s.pt --epochs 100
#
#   4. Copy best weights to the expected path:
#        mkdir -p dependencies/models/obstacle_detection/yolo
#        cp runs/yolo_carla/train/weights/best.pt \
#            dependencies/models/obstacle_detection/yolo/best.pt
#
#   5. Use --obstacle_detection with the YoloDetectionOperator by setting
#      --yolo_detection_model_path=dependencies/models/obstacle_detection/yolo/best.pt
#
# If you already have a compatible faster-rcnn TF saved_model directory, place it at:
#   dependencies/models/obstacle_detection/faster-rcnn/
echo "[x] Skipping model weight download (original archive unavailable)."
echo "    See install.sh comments for the YOLO training workflow."
mkdir -p "$PYLOT_HOME/dependencies/models/obstacle_detection/yolo"
mkdir -p "$PYLOT_HOME/dependencies/models/traffic_light_detection"
mkdir -p "$PYLOT_HOME/dependencies/models/segmentation/drn"
mkdir -p "$PYLOT_HOME/dependencies/models/depth_estimation"
mkdir -p "$PYLOT_HOME/dependencies/models/tracking"

#################### Download the code bases ####################
echo "[x] Compiling the planners..."

# Helper: build a planner with cmake using conda-provided deps (no sudo).
# The upstream build.sh scripts call `sudo apt-get install` which fails on
# HPC clusters. We skip them and run cmake directly.
#
# Qt5Gui's cmake config requires GL/gl.h under the Qt prefix include dir.
# Ensure it is available by symlinking from the CDT sysroot or the system.
_ensure_gl_headers() {
    local target="$CONDA_PREFIX/include/GL"
    if [ -f "$target/gl.h" ]; then
        return 0
    fi
    # Try conda CDT sysroot first
    local sysroot="$CONDA_PREFIX/x86_64-conda-linux-gnu/sysroot/usr/include/GL"
    if [ -f "$sysroot/gl.h" ]; then
        ln -sfn "$sysroot" "$target"
        echo "    Symlinked GL headers from conda sysroot."
        return 0
    fi
    # Fall back to system headers
    if [ -f "/usr/include/GL/gl.h" ]; then
        ln -sfn "/usr/include/GL" "$target"
        echo "    Symlinked GL headers from /usr/include."
        return 0
    fi
    echo "WARNING: GL/gl.h not found; Qt5-based planner builds may fail."
}

# The planner source code uses #include <eigen3/Eigen/Dense>, expecting
# "eigen3/" to sit under a standard include path (e.g. /usr/include/).
# Conda's find_package(Eigen3) adds $CONDA_PREFIX/include/eigen3 as the
# include dir, so the compiler looks for eigen3/eigen3/Eigen/Dense — which
# doesn't exist. Fix: create a self-referencing symlink so both styles work.
_ensure_eigen_headers() {
    local eigen_dir="$CONDA_PREFIX/include/eigen3"
    if [ -d "$eigen_dir" ] && [ ! -e "$eigen_dir/eigen3" ]; then
        ln -s . "$eigen_dir/eigen3"
        echo "    Created eigen3 compatibility symlink."
    fi
}

build_planner() {
    local planner_dir="$1"
    _ensure_gl_headers
    _ensure_eigen_headers
    cd "$planner_dir"
    mkdir -p build
    cd build
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build . --target all -- -j 8
}

###### Build the FrenetOptimalTrajectory Planner ######
echo "[x] Compiling the Frenet Optimal Trajectory planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "frenet_optimal_trajectory_planner" ]; then
    git clone https://github.com/erdos-project/frenet_optimal_trajectory_planner.git
fi
build_planner "$PYLOT_HOME/dependencies/frenet_optimal_trajectory_planner"

###### Build the RRT* Planner ######
echo "[x] Compiling the RRT* planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "rrt_star_planner" ]; then
    git clone https://github.com/erdos-project/rrt_star_planner.git
fi
build_planner "$PYLOT_HOME/dependencies/rrt_star_planner"

###### Build the Hybrid A* Planner ######
echo "[x] Compiling the Hybrid A* planner..."
cd "$PYLOT_HOME/dependencies/"
if [ ! -d "hybrid_astar_planner" ]; then
    git clone https://github.com/erdos-project/hybrid_astar_planner.git
fi
build_planner "$PYLOT_HOME/dependencies/hybrid_astar_planner"

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
    # llvmdev from conda provides llvm-config
    if command -v llvm-config &> /dev/null; then
        export LLVM_CONFIG=$(which llvm-config)
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
# Remove empty leftover directory from a previously failed download
if [ -d "CARLA_0.9.10.1" ] && [ -z "$(ls -A CARLA_0.9.10.1 2>/dev/null)" ]; then
    rmdir CARLA_0.9.10.1
    echo "    Removed empty CARLA_0.9.10.1 directory from previous failed attempt."
fi
if [ "$1" != 'challenge' ] && [ ! -d "CARLA_0.9.10.1" ]; then
    mkdir CARLA_0.9.10.1
    cd CARLA_0.9.10.1
    wget -O CARLA_0.9.10.1.tar.gz https://carla-releases.s3.us-east-005.backblazeb2.com/Linux/CARLA_0.9.10.1.tar.gz
    tar -xvf CARLA_0.9.10.1.tar.gz
    rm CARLA_0.9.10.1.tar.gz
fi
# Install the CARLA Python API (.egg) into the conda environment.
# Modern pip cannot install .egg files, so we add it to PYTHONPATH
# via a conda activate.d hook script (runs automatically on `conda activate`).
CARLA_EGG="$PYLOT_HOME/dependencies/CARLA_0.9.10.1/PythonAPI/carla/dist/carla-0.9.10-py3.7-linux-x86_64.egg"
CARLA_API="$PYLOT_HOME/dependencies/CARLA_0.9.10.1/PythonAPI/carla"
if [ -f "$CARLA_EGG" ]; then
    mkdir -p "$CONDA_PREFIX/etc/conda/activate.d"
    cat > "$CONDA_PREFIX/etc/conda/activate.d/carla.sh" <<EOF
export PYTHONPATH="\$PYTHONPATH:$CARLA_EGG:$CARLA_API"
EOF
    # Also export it now for the rest of this script
    export PYTHONPATH="$PYTHONPATH:$CARLA_EGG:$CARLA_API"
    echo "    CARLA Python API added to PYTHONPATH (auto-loads on conda activate)"
else
    echo "WARNING: CARLA .egg not found at $CARLA_EGG"
fi

# Restore the compat linker now that all builds are done
if [ -f "$CONDA_PREFIX/compiler_compat/ld.bak" ]; then
    mv "$CONDA_PREFIX/compiler_compat/ld.bak" "$CONDA_PREFIX/compiler_compat/ld"
    echo "INFO: Restored compiler_compat/ld"
fi

echo "[x] Installing pylot into the conda environment..."
cd "$PYLOT_HOME"
python3 -m pip install -e .

echo ""
echo "========================================"
echo " Installation complete!"
echo " To use pylot, activate the conda env:"
echo "   conda activate ${CONDA_ENV_NAME}"
echo "========================================"
