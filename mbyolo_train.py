#!/usr/bin/env python3
"""
Mamba-YOLO Training & Evaluation Script for VisDrone-VID

Supports three model sizes:
  T (Tiny)  - 5.8M params,  13.2G FLOPs  (fastest, lowest VRAM)
  B (Base)  - 21.8M params,  49.7G FLOPs  (balanced)
  L (Large) - 57.6M params, 156.2G FLOPs  (best accuracy, highest VRAM)

Usage:
  # Train
  python mbyolo_train.py --model T --task train --epochs 300
  python mbyolo_train.py --model B --task train --epochs 300
  python mbyolo_train.py --model L --task train --epochs 300

  # Validate
  python mbyolo_train.py --model T --task val

  # Test
  python mbyolo_train.py --model L --task test
"""

import argparse
import os
import sys

ROOT = os.path.abspath(os.path.dirname(__file__)) + "/"

MODEL_CONFIGS = {
    "T": ROOT + "ultralytics/cfg/models/mamba-yolo/Mamba-YOLO-T.yaml",
    "B": ROOT + "ultralytics/cfg/models/mamba-yolo/Mamba-YOLO-B.yaml",
    "L": ROOT + "ultralytics/cfg/models/mamba-yolo/Mamba-YOLO-L.yaml",
}

MODEL_INFO = {
    "T": {"name": "Mamba-YOLO-Tiny", "params": "5.8M", "flops": "13.2G", "batch": 4},
    "B": {"name": "Mamba-YOLO-Base", "params": "21.8M", "flops": "49.7G", "batch": 2},
    "L": {"name": "Mamba-YOLO-Large", "params": "57.6M", "flops": "156.2G", "batch": 1},
}


def parse_opt():
    parser = argparse.ArgumentParser(description="Mamba-YOLO Training for VisDrone-VID")
    parser.add_argument("--model", type=str, default="T", choices=["T", "B", "L"],
                        help="Model size: T (Tiny), B (Base), L (Large)")
    parser.add_argument("--data", type=str,
                        default=ROOT + "ultralytics/cfg/datasets/VisDrone-VID.yaml",
                        help="Dataset YAML path")
    parser.add_argument("--task", type=str, default="train",
                        choices=["train", "val", "test"],
                        help="Task: train, val, or test")
    parser.add_argument("--weights", type=str, default=None,
                        help="Path to pretrained weights (.pt file)")
    parser.add_argument("--batch_size", type=int, default=None,
                        help="Batch size (auto-set per model size if not specified)")
    parser.add_argument("--imgsz", type=int, default=640,
                        help="Input image size")
    parser.add_argument("--epochs", type=int, default=300,
                        help="Number of training epochs")
    parser.add_argument("--device", type=str, default="0",
                        help="CUDA device (e.g., 0 or 0,1)")
    parser.add_argument("--workers", type=int, default=8,
                        help="DataLoader workers")
    parser.add_argument("--optimizer", type=str, default="SGD",
                        choices=["SGD", "Adam", "AdamW"],
                        help="Optimizer")
    parser.add_argument("--lr", type=float, default=0.01,
                        help="Initial learning rate")
    parser.add_argument("--amp", action="store_true", default=True,
                        help="Enable Automatic Mixed Precision")
    parser.add_argument("--no-amp", dest="amp", action="store_false",
                        help="Disable AMP")
    parser.add_argument("--project", type=str,
                        default=ROOT + "output_dir/VisDrone-VID",
                        help="Output project directory")
    parser.add_argument("--name", type=str, default=None,
                        help="Experiment name (auto-generated if not set)")
    parser.add_argument("--resume", action="store_true", default=False,
                        help="Resume from last checkpoint")
    parser.add_argument("--cos_lr", action="store_true", default=True,
                        help="Use cosine LR scheduler")
    parser.add_argument("--close_mosaic", type=int, default=10,
                        help="Disable mosaic augmentation in last N epochs")
    parser.add_argument("--patience", type=int, default=50,
                        help="Early stopping patience")
    parser.add_argument("--save_period", type=int, default=10,
                        help="Save checkpoint every N epochs")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed")

    return parser.parse_args()


def main():
    opt = parse_opt()

    model_size = opt.model.upper()
    model_cfg = MODEL_CONFIGS[model_size]
    info = MODEL_INFO[model_size]

    if opt.batch_size is None:
        batch_size = info["batch"]
    else:
        batch_size = opt.batch_size

    experiment_name = opt.name if opt.name else f"mamba_yolo_{model_size.lower()}"

    print(f"{'='*60}")
    print(f"  Model: {info['name']} ({info['params']} params, {info['flops']} FLOPs)")
    print(f"  Task:  {opt.task}")
    print(f"  Batch: {batch_size} | Image Size: {opt.imgsz} | Epochs: {opt.epochs}")
    print(f"  Device: {opt.device} | AMP: {opt.amp} | Optimizer: {opt.optimizer}")
    print(f"  Output: {opt.project}/{experiment_name}")
    print(f"{'='*60}")

    args = {
        "data": opt.data,
        "epochs": opt.epochs,
        "batch": batch_size,
        "imgsz": opt.imgsz,
        "device": opt.device,
        "workers": opt.workers,
        "optimizer": opt.optimizer,
        "lr0": opt.lr,
        "amp": opt.amp,
        "project": opt.project,
        "name": experiment_name,
        "exist_ok": True,
        "seed": opt.seed,
        "patience": opt.patience,
        "save_period": opt.save_period,
        "cos_lr": opt.cos_lr,
        "close_mosaic": opt.close_mosaic,
    }

    if opt.weights:
        args["weights"] = opt.weights

    if opt.resume:
        args["resume"] = True

    from ultralytics import YOLO

    if opt.task == "train":
        model = YOLO(model_cfg)
        if opt.weights:
            model = YOLO(opt.weights)
        model.train(**args)
    elif opt.task == "val":
        weights = opt.weights if opt.weights else f"{opt.project}/{experiment_name}/weights/best.pt"
        if not os.path.exists(weights):
            print(f"[ERROR] Weights not found: {weights}")
            print("Please train first or specify --weights path.")
            sys.exit(1)
        model = YOLO(weights)
        model.val(**{k: v for k, v in args.items()
                     if k in ["data", "batch", "imgsz", "device", "workers",
                               "project", "name", "exist_ok", "amp", "half"]})
    elif opt.task == "test":
        weights = opt.weights if opt.weights else f"{opt.project}/{experiment_name}/weights/best.pt"
        if not os.path.exists(weights):
            print(f"[ERROR] Weights not found: {weights}")
            print("Please train first or specify --weights path.")
            sys.exit(1)
        model = YOLO(weights)
        model.val(**{k: v for k, v in args.items()
                     if k in ["data", "batch", "imgsz", "device", "workers",
                               "project", "name", "exist_ok", "amp", "half"]})


if __name__ == "__main__":
    main()
