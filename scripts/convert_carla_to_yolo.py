#!/usr/bin/env python3
"""
Convert CARLA simulator data collected by Pylot into YOLO dataset format.

Reads center RGB frames and bounding-box annotation JSON files from one or more
run directories, shuffles/splits into train/val/test, and writes:

  {output_dir}/
    images/train/   images/val/   images/test/
    labels/train/   labels/val/   labels/test/
    dataset.yaml

Annotation JSON format (per element in the bbox array):
  [label, detailed_label, id, [[xmin, ymin], [xmax, ymax]]]

Example
-------
python scripts/convert_carla_to_yolo.py \\
    --data_dirs data/town01_start0,data/town02_start25 \\
    --output_dir data/yolo_dataset \\
    --include_traffic_lights \\
    --train_ratio 0.70 \\
    --val_ratio 0.20
"""

import argparse
import glob
import json
import os
import random
import shutil
import sys
from collections import defaultdict

from PIL import Image

# ---
# Class definitions
# ---

BASE_CLASSES = ["person", "vehicle"]

TRAFFIC_LIGHT_CLASSES = [
    "red traffic light",
    "yellow traffic light",
    "green traffic light",
    "off traffic light",
]

SPLITS = ("train", "val", "test")


# ---
# Argument parsing
# ---


def parse_args():
    """Parse and validate command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Convert CARLA/Pylot driving data to YOLO dataset format.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--data_dirs",
        required=True,
        type=str,
        help=(
            "Comma-separated list of run directories to process. "
            "Each must contain center/ and bboxes/ subdirectories."
        ),
    )
    parser.add_argument(
        "--output_dir",
        default="data/yolo_dataset",
        help="Root directory for the output YOLO dataset.",
    )
    parser.add_argument(
        "--include_traffic_lights",
        action="store_true",
        default=False,
        help=(
            "Include traffic-light annotations from tl-bboxes/ subdirectories. "
            "Adds 4 extra classes (red/yellow/green/off traffic light)."
        ),
    )
    parser.add_argument(
        "--train_ratio",
        type=float,
        default=0.70,
        help="Fraction of samples assigned to the training split.",
    )
    parser.add_argument(
        "--val_ratio",
        type=float,
        default=0.20,
        help="Fraction of samples assigned to the validation split.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducible shuffling and splitting.",
    )

    args = parser.parse_args()

    if not (0.0 < args.train_ratio < 1.0):
        parser.error("--train_ratio must be strictly between 0 and 1.")
    if not (0.0 < args.val_ratio < 1.0):
        parser.error("--val_ratio must be strictly between 0 and 1.")
    if args.train_ratio + args.val_ratio >= 1.0:
        parser.error(
            f"--train_ratio ({args.train_ratio}) + --val_ratio ({args.val_ratio}) "
            "must be less than 1.0 so the test split is non-empty."
        )

    return args


# ---
# Sample discovery
# ---


def discover_samples(data_dirs, include_tl):
    """Scan run directories for center PNG frames and match annotation files.

    For every ``center/center-{timestamp}.png`` image the corresponding
    ``bboxes/bboxes-{timestamp}.json`` must exist; frames without it are
    skipped with a warning.  If *include_tl* is True, the optional
    ``tl-bboxes/tl-bboxes-{timestamp}.json`` is also noted (its absence is
    silently tolerated — the frame is still included).

    Args:
        data_dirs: Ordered list of run-directory paths.
        include_tl: Whether to look for traffic-light annotation files.

    Returns:
        List of sample dicts with keys:
            run_index   – zero-based index into *data_dirs*
            timestamp   – timestamp string extracted from the filename
            image_path  – absolute path to the PNG
            bbox_path   – absolute path to the obstacle JSON
            tl_bbox_path – absolute path to the TL JSON, or None
    """
    samples = []

    for run_idx, run_dir in enumerate(data_dirs):
        center_pattern = os.path.join(run_dir, "center", "center-*.png")
        image_files = sorted(glob.glob(center_pattern))

        if not image_files:
            print(
                f"[WARNING] No center images found in {run_dir!r}. Skipping directory."
            )
            continue

        for img_path in image_files:
            # Filename: center-{timestamp}.png
            basename = os.path.basename(img_path)
            ts = basename[len("center-") : -len(".png")]

            bbox_path = os.path.join(run_dir, "bboxes", f"bboxes-{ts}.json")
            if not os.path.isfile(bbox_path):
                print(
                    f"[WARNING] Missing bbox file for timestamp {ts!r} in "
                    f"{run_dir!r}. Skipping frame."
                )
                continue

            tl_bbox_path = None
            if include_tl:
                candidate = os.path.join(run_dir, "tl-bboxes", f"tl-bboxes-{ts}.json")
                if os.path.isfile(candidate):
                    tl_bbox_path = candidate
                # A missing TL file is acceptable; frame is still processed.

            samples.append(
                {
                    "run_index": run_idx,
                    "timestamp": ts,
                    "image_path": img_path,
                    "bbox_path": bbox_path,
                    "tl_bbox_path": tl_bbox_path,
                }
            )

    return samples


# ---
# Annotation loading and normalisation
# ---


def load_annotations(sample, class_to_id):
    """Parse bbox JSON files and return YOLO-normalised annotations.

    Each entry in the JSON array has the form::

        [label, detailed_label, id, [[xmin, ymin], [xmax, ymax]]]

    Coordinates are clamped to the actual image dimensions before
    normalisation.  Zero-area boxes are skipped with a warning.  Labels
    absent from *class_to_id* are silently ignored.

    The image is opened via PIL only once, and only if at least one annotation
    passes the label filter.

    Args:
        sample: Sample dict as produced by :func:`discover_samples`.
        class_to_id: Mapping from class name to integer class index.

    Returns:
        List of ``(class_id, cx, cy, w, h)`` tuples with coordinates
        normalised to [0, 1] relative to image width and height.
    """
    # Lazy image dimension loader — avoids opening the file when no annotation
    # passes the label filter.
    _dims = {}

    def get_dims():
        if "wh" not in _dims:
            with Image.open(sample["image_path"]) as im:
                _dims["wh"] = im.size  # (width, height)
        return _dims["wh"]

    annotations = []
    json_paths = [sample["bbox_path"]]
    if sample["tl_bbox_path"] is not None:
        json_paths.append(sample["tl_bbox_path"])

    for json_path in json_paths:
        try:
            with open(json_path, "r") as fh:
                entries = json.load(fh)
        except (json.JSONDecodeError, OSError) as exc:
            print(f"[WARNING] Could not read {json_path!r}: {exc}. Skipping.")
            continue

        for entry in entries:
            label = entry[0]
            if label not in class_to_id:
                # Label is not in the requested class set; silently skip.
                continue

            # entry[3] = [[xmin, ymin], [xmax, ymax]]
            bbox_coords = entry[3]
            raw_xmin, raw_ymin = bbox_coords[0]
            raw_xmax, raw_ymax = bbox_coords[1]

            img_w, img_h = get_dims()

            # Clamp to [0, image_dimension] to handle out-of-bounds coordinates.
            xmin = max(0.0, min(float(raw_xmin), img_w))
            ymin = max(0.0, min(float(raw_ymin), img_h))
            xmax = max(0.0, min(float(raw_xmax), img_w))
            ymax = max(0.0, min(float(raw_ymax), img_h))

            box_w = xmax - xmin
            box_h = ymax - ymin

            if box_w <= 0.0 or box_h <= 0.0:
                print(
                    f"[WARNING] Zero-area box for label {label!r} in "
                    f"{json_path!r} "
                    f"(xmin={raw_xmin}, ymin={raw_ymin}, "
                    f"xmax={raw_xmax}, ymax={raw_ymax}). Skipping."
                )
                continue

            cx = (xmin + xmax) / 2.0 / img_w
            cy = (ymin + ymax) / 2.0 / img_h
            nw = box_w / img_w
            nh = box_h / img_h

            annotations.append((class_to_id[label], cx, cy, nw, nh))

    return annotations


# ---
# Dataset writing
# ---


def create_output_dirs(output_dir):
    """Create the full YOLO directory tree under *output_dir*."""
    for split in SPLITS:
        os.makedirs(os.path.join(output_dir, "images", split), exist_ok=True)
        os.makedirs(os.path.join(output_dir, "labels", split), exist_ok=True)


def write_sample(sample, annotations, split, output_dir):
    """Copy one image and write its YOLO label file.

    Images are renamed to ``{run_index}_{timestamp}.png`` to prevent filename
    collisions when multiple run directories are combined.

    An empty label file is written when *annotations* is empty so that YOLO
    training tooling always finds a matching ``.txt`` for every image.

    Args:
        sample: Sample dict as produced by :func:`discover_samples`.
        annotations: List of ``(class_id, cx, cy, w, h)`` tuples.
        split: One of ``'train'``, ``'val'``, or ``'test'``.
        output_dir: Root output directory.
    """
    stem = f"{sample['run_index']}_{sample['timestamp']}"

    # Copy image preserving metadata (timestamps, etc.)
    dst_img = os.path.join(output_dir, "images", split, stem + ".png")
    shutil.copy2(sample["image_path"], dst_img)

    # Write label file (empty file is valid YOLO for background images)
    dst_lbl = os.path.join(output_dir, "labels", split, stem + ".txt")
    with open(dst_lbl, "w") as fh:
        for cls_id, cx, cy, w, h in annotations:
            fh.write(f"{cls_id} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")


def write_dataset_yaml(output_dir, classes):
    """Write the ``dataset.yaml`` descriptor for YOLOv5 / YOLOv8.

    The ``path`` key is set to the absolute path of *output_dir* so the file
    can be consumed from any working directory.

    Args:
        output_dir: Root output directory (may be relative).
        classes: Ordered list of class name strings.

    Returns:
        Absolute path to the written YAML file.
    """
    abs_output = os.path.abspath(output_dir)
    yaml_path = os.path.join(output_dir, "dataset.yaml")

    # Written manually to avoid a PyYAML dependency and to control formatting.
    names_inline = "[" + ", ".join(repr(c) for c in classes) + "]"

    lines = [
        f"path: {abs_output}",
        "train: images/train",
        "val: images/val",
        "test: images/test",
        "",
        f"nc: {len(classes)}",
        f"names: {names_inline}",
        "",
    ]

    with open(yaml_path, "w") as fh:
        fh.write("\n".join(lines))

    return yaml_path


# ---
# Summary reporting
# ---


def print_summary(split_samples, class_annotation_counts, classes):
    """Print a human-readable conversion summary to stdout."""
    total = sum(len(v) for v in split_samples.values())
    sep = "=" * 62

    print(f"\n{sep}")
    print("  YOLO Dataset Conversion Summary")
    print(sep)
    print(f"  Total frames processed : {total}")
    for split in SPLITS:
        n = len(split_samples[split])
        pct = 100.0 * n / total if total else 0.0
        print(f"    {split:<8}: {n:>6} frames  ({pct:.1f} %)")
    print()
    print("  Annotations per class:")
    grand_total = 0
    for cls_name in classes:
        count = class_annotation_counts.get(cls_name, 0)
        grand_total += count
        print(f"    {cls_name:<32}: {count:>8}")
    print(f"    {'TOTAL':<32}: {grand_total:>8}")
    print(f"{sep}\n")


# ---
# Main entry point
# ---


def main():
    args = parse_args()

    # Parse comma-separated run directories, strip whitespace.
    data_dirs = [d.strip() for d in args.data_dirs.split(",") if d.strip()]
    if not data_dirs:
        sys.exit("[ERROR] --data_dirs produced an empty list after parsing.")

    for d in data_dirs:
        if not os.path.isdir(d):
            sys.exit(f"[ERROR] Run directory not found: {d!r}")

    # Build class list and reverse lookup
    classes = list(BASE_CLASSES)
    if args.include_traffic_lights:
        classes.extend(TRAFFIC_LIGHT_CLASSES)
    class_to_id = {name: idx for idx, name in enumerate(classes)}
    id_to_class = {idx: name for name, idx in class_to_id.items()}

    test_ratio = 1.0 - args.train_ratio - args.val_ratio
    print(f"Classes ({len(classes)}): {classes}")
    print(
        f"Split ratios  →  train: {args.train_ratio:.0%}  "
        f"val: {args.val_ratio:.0%}  "
        f"test: {test_ratio:.0%}  "
        f"(seed={args.seed})"
    )
    print(
        f"Scanning {len(data_dirs)} run "
        f"director{'y' if len(data_dirs) == 1 else 'ies'} ..."
    )

    # --- Discover samples
    all_samples = discover_samples(data_dirs, args.include_traffic_lights)
    if not all_samples:
        sys.exit(
            "[ERROR] No valid samples found. Check --data_dirs paths and subdirectory layout."
        )

    print(f"Found {len(all_samples)} valid frame(s).")

    # --- Shuffle and split
    rng = random.Random(args.seed)
    rng.shuffle(all_samples)

    n_total = len(all_samples)
    n_train = int(n_total * args.train_ratio)
    n_val = int(n_total * args.val_ratio)
    n_test = n_total - n_train - n_val  # remainder avoids rounding gaps

    split_samples = {
        "train": all_samples[:n_train],
        "val": all_samples[n_train : n_train + n_val],
        "test": all_samples[n_train + n_val :],
    }

    print(f"Split  →  train: {n_train}  val: {n_val}  test: {n_test}")

    # --- Create output directory tree
    create_output_dirs(args.output_dir)

    # --- Process every sample
    class_annotation_counts = defaultdict(int)
    total_written = 0

    for split, samples in split_samples.items():
        for sample in samples:
            annotations = load_annotations(sample, class_to_id)
            write_sample(sample, annotations, split, args.output_dir)
            for cls_id, *_ in annotations:
                class_annotation_counts[id_to_class[cls_id]] += 1
            total_written += 1

        print(f"  Wrote {len(samples)} {split} sample(s).")

    # --- Write dataset descriptor
    yaml_path = write_dataset_yaml(args.output_dir, classes)
    print(f"Wrote dataset.yaml → {yaml_path}")

    # --- Final summary
    print_summary(split_samples, class_annotation_counts, classes)


if __name__ == "__main__":
    main()
