#!/usr/bin/env python3
"""
train_yolo.py – Train a YOLOv8 model on a dataset produced by convert_carla_to_yolo.py.

Usage example:
    python scripts/train_yolo.py \
        --dataset data/yolo_dataset \
        --model yolov8s.pt \
        --epochs 100 \
        --device 0
"""

import argparse
import os
import sys
from typing import Optional

# ── Argument parsing ──────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train a YOLOv8 model on a CARLA-derived YOLO dataset.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Dataset / model
    parser.add_argument(
        "--dataset",
        type=str,
        default="data/yolo_dataset",
        help="Path to the YOLO dataset directory (must contain dataset.yaml).",
    )
    parser.add_argument(
        "--model",
        type=str,
        default="yolov8n.pt",
        help=(
            "Base model to start from. Use a pretrained name "
            "(yolov8n.pt, yolov8s.pt, yolov8m.pt, …) or a path to a .pt "
            "file to resume / fine-tune."
        ),
    )

    # Training hyperparameters
    parser.add_argument(
        "--epochs",
        type=int,
        default=100,
        help="Total number of training epochs.",
    )
    parser.add_argument(
        "--imgsz",
        type=int,
        default=640,
        help="Input image size (square, in pixels).",
    )
    parser.add_argument(
        "--batch",
        type=int,
        default=16,
        help="Batch size. Pass -1 to enable Ultralytics auto-batch.",
    )
    parser.add_argument(
        "--lr0",
        type=float,
        default=0.01,
        help="Initial learning rate.",
    )
    parser.add_argument(
        "--patience",
        type=int,
        default=30,
        help="Early-stopping patience: number of epochs with no improvement before stopping.",
    )
    parser.add_argument(
        "--save_period",
        type=int,
        default=10,
        help="Save a checkpoint every N epochs. Set to -1 to disable periodic saves.",
    )

    # Hardware / I/O
    parser.add_argument(
        "--device",
        type=str,
        default="",
        help=(
            "Device to train on. "
            'Use "" for automatic selection, "0" (or "0,1") for specific GPU(s), '
            'or "cpu" to force CPU training.'
        ),
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=8,
        help="Number of DataLoader worker processes.",
    )
    parser.add_argument(
        "--project",
        type=str,
        default="runs/yolo_carla",
        help="Root directory where training run results are saved.",
    )
    parser.add_argument(
        "--name",
        type=str,
        default="train",
        help="Run name (creates a sub-directory inside --project).",
    )

    # Flags
    parser.add_argument(
        "--resume",
        action="store_true",
        default=False,
        help="Resume training from the last checkpoint of a previous run.",
    )
    parser.add_argument(
        "--no-val",
        dest="val",
        action="store_false",
        help="Disable per-epoch validation.",
    )
    parser.set_defaults(val=True)
    parser.add_argument(
        "--no-test",
        dest="test",
        action="store_false",
        help="Skip evaluation on the test split after training.",
    )
    parser.set_defaults(test=True)
    parser.add_argument(
        "--no-augment",
        dest="augment",
        action="store_false",
        help="Disable the default Ultralytics augmentation pipeline.",
    )
    parser.set_defaults(augment=True)

    return parser.parse_args()


# ── Validation helpers ────────────────────────────────────────────────────────


def validate_dataset(dataset_dir: str) -> str:
    """Return the absolute path to dataset.yaml or exit with a helpful message."""
    yaml_path = os.path.join(dataset_dir, "dataset.yaml")
    if not os.path.isfile(yaml_path):
        print(
            f"[ERROR] dataset.yaml not found in '{dataset_dir}'.\n"
            "Make sure --dataset points to the root of a YOLO dataset that contains:\n"
            "  images/train   images/val   images/test\n"
            "  labels/train   labels/val   labels/test\n"
            "  dataset.yaml\n"
            "Run convert_carla_to_yolo.py first if you haven't already.",
            file=sys.stderr,
        )
        sys.exit(1)
    return os.path.abspath(yaml_path)


def check_ultralytics() -> None:
    """Exit with install instructions if ultralytics is not available."""
    try:
        import ultralytics  # noqa: F401
    except ImportError:
        print(
            "[ERROR] The 'ultralytics' package is not installed.\n"
            "Install it with:\n"
            "    pip install ultralytics",
            file=sys.stderr,
        )
        sys.exit(1)


# ── Training ──────────────────────────────────────────────────────────────────


def train(args: argparse.Namespace, yaml_path: str):
    from ultralytics import YOLO

    print(f"[INFO] Loading model: {args.model}")
    model = YOLO(args.model)

    train_kwargs = dict(
        data=yaml_path,
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        lr0=args.lr0,
        patience=args.patience,
        save_period=args.save_period,
        device=args.device if args.device != "" else None,
        workers=args.workers,
        project=args.project,
        name=args.name,
        resume=args.resume,
        val=args.val,
        augment=args.augment,
        exist_ok=True,
    )

    print("[INFO] Starting training with the following settings:")
    for key, value in train_kwargs.items():
        print(f"       {key}: {value}")
    print()

    results = model.train(**train_kwargs)
    return model, results


# ── Test evaluation ───────────────────────────────────────────────────────────


def run_test(model, yaml_path: str) -> None:
    print("\n[INFO] Running evaluation on the test split …")
    metrics = model.val(data=yaml_path, split="test")
    print("[INFO] Test metrics:")
    # metrics_dict may be a Results object; print its dict representation if available.
    metrics_dict = getattr(metrics, "results_dict", None) or vars(metrics)
    for k, v in metrics_dict.items():
        print(f"       {k}: {v}")


# ── Best-weights helper ───────────────────────────────────────────────────────


def find_best_weights(project: str, name: str) -> Optional[str]:
    """Return the path to best.pt produced by the training run."""
    candidate = os.path.join(project, name, "weights", "best.pt")
    return candidate if os.path.isfile(candidate) else None


# ── Entry point ───────────────────────────────────────────────────────────────


def main() -> None:
    args = parse_args()

    # Pre-flight checks
    check_ultralytics()
    yaml_path = validate_dataset(args.dataset)

    model = None
    try:
        model, _ = train(args, yaml_path)
    except KeyboardInterrupt:
        print("\n[INFO] Training interrupted by user (KeyboardInterrupt).")

    # Test split evaluation
    if args.test and model is not None:
        try:
            run_test(model, yaml_path)
        except Exception as exc:
            print(f"[WARNING] Test evaluation failed: {exc}", file=sys.stderr)

    # Report best weights
    best = find_best_weights(args.project, args.name)
    if best:
        print(f"\n[INFO] Best weights saved to: {best}")
    else:
        # Fallback: last.pt
        last = os.path.join(args.project, args.name, "weights", "last.pt")
        if os.path.isfile(last):
            print(f"\n[INFO] Best weights not found; last checkpoint saved to: {last}")
        else:
            print(
                f"\n[WARNING] Could not locate saved weights in "
                f"'{os.path.join(args.project, args.name, 'weights')}'.",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
