#!/bin/bash
# Auto-train Mamba-YOLO T/B/L on VisDrone, 5 minutes each
# GPU memory < 4GB constraint

set -e
source /home/xrb/桌面/mamba-yolo/venv/bin/activate
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd /home/xrb/桌面/mamba-yolo

echo "============================================================"
echo "  Mamba-YOLO 三模型自动训练 (每个5分钟)"
echo "  GPU: RTX 3070 8GB | 显存限制: <4GB"
echo "============================================================"

# T model: batch=4, ~3.5GB VRAM
echo ""
echo ">>> [1/3] Mamba-YOLO-Tiny (5.8M params, batch=4)"
timeout 300 python mbyolo_train.py \
    --model T --task train --epochs 300 --workers 4 --device 0 \
    --batch_size 4 --name mambayolo_T \
    2>&1 | grep -E "GPU_mem|Epoch|mAP|completed|Results saved|Error|error" || true
echo "<<< Tiny 5分钟训练完成"

# B model: batch=2, ~3.5GB VRAM
echo ""
echo ">>> [2/3] Mamba-YOLO-Base (21.8M params, batch=2)"
timeout 300 python mbyolo_train.py \
    --model B --task train --epochs 300 --workers 4 --device 0 \
    --batch_size 2 --name mambayolo_B \
    2>&1 | grep -E "GPU_mem|Epoch|mAP|completed|Results saved|Error|error" || true
echo "<<< Base 5分钟训练完成"

# L model: batch=1, ~3.5GB VRAM
echo ""
echo ">>> [3/3] Mamba-YOLO-Large (57.6M params, batch=1)"
timeout 300 python mbyolo_train.py \
    --model L --task train --epochs 300 --workers 4 --device 0 \
    --batch_size 1 --name mambayolo_L \
    2>&1 | grep -E "GPU_mem|Epoch|mAP|completed|Results saved|Error|error" || true
echo "<<< Large 5分钟训练完成"

echo ""
echo "============================================================"
echo "  训练全部完成！"
echo "  输出目录: output_dir/VisDrone/"
echo "============================================================"
ls -la output_dir/VisDrone/mambayolo_*/
