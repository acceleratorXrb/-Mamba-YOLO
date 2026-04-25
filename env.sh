#!/bin/bash
# 激活 Mamba-YOLO 训练环境
# 用法: source env.sh

source venv/bin/activate
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export LD_LIBRARY_PATH=$(python -c "import torch, os; print(os.path.join(os.path.dirname(torch.__file__), 'lib'))"):$LD_LIBRARY_PATH

echo "✓ 环境已激活，可以开始训练"
