#!/bin/bash
set -e

# ============================================================
# Mamba-YOLO 一键环境配置脚本
# 执行: bash setup.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
DATASETS_DIR="$PROJECT_DIR/datasets"

echo "================================================"
echo "  Mamba-YOLO 环境配置"
echo "  项目目录: $PROJECT_DIR"
echo "================================================"

# ---------- 1. 检查 Python 版本 ----------
echo ""
echo "[1/7] 检查 Python 环境..."

PYTHON_BIN=""
for py in python3.12 python3.11 python3; do
    if command -v $py &>/dev/null; then
        VER=$($py --version 2>&1 | grep -oP '\d+\.\d+')
        MAJOR=$(echo $VER | cut -d. -f1)
        MINOR=$(echo $VER | cut -d. -f2)
        if [ "$MAJOR" -ge 3 ] && [ "$MINOR" -ge 11 ]; then
            PYTHON_BIN=$py
            echo "  ✓ 找到 $py ($VER)"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}错误: 需要 Python >= 3.11，未找到${NC}"
    echo "请安装 Python 3.11+ 后重试: sudo apt install python3.12 python3.12-venv"
    exit 1
fi

# ---------- 2. 检查 CUDA ----------
echo ""
echo "[2/7] 检查 CUDA 环境..."

CUDA_AVAILABLE=false
if command -v nvcc &>/dev/null; then
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K\d+\.\d+' || echo "")
    if [ -n "$CUDA_VER" ]; then
        echo "  ✓ nvcc 版本: $CUDA_VER"
        CUDA_AVAILABLE=true
    fi
fi

if [ "$CUDA_AVAILABLE" = false ]; then
    if [ -d "/usr/local/cuda/bin" ]; then
        echo "  nvcc 未在 PATH 中找到，但检测到 /usr/local/cuda"
        echo "  请运行: export PATH=/usr/local/cuda/bin:\$PATH"
    else
        echo -e "${YELLOW}  警告: 未检测到 CUDA Toolkit (nvcc)${NC}"
        echo "  selective_scan 编译需要 CUDA Toolkit"
        echo "  PyTorch GPU 训练也需要 CUDA"
        echo "  继续执行，但编译步骤可能失败..."
    fi
fi

if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${YELLOW}  警告: 未检测到 nvidia-smi，可能无 GPU${NC}"
else
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1
fi

# ---------- 3. 创建虚拟环境 ----------
echo ""
echo "[3/7] 创建 Python 虚拟环境..."

if [ -d "$VENV_DIR" ]; then
    echo "  虚拟环境已存在: $VENV_DIR"
    echo "  如需重建请先删除: rm -rf venv/"
else
    $PYTHON_BIN -m venv "$VENV_DIR"
    echo "  ✓ 虚拟环境创建完成"
fi

source "$VENV_DIR/bin/activate"
echo "  Python: $(python --version)"

# ---------- 4. 安装 PyTorch ----------
echo ""
echo "[4/7] 安装 PyTorch (CUDA 12.1)..."

# 检查 PyTorch 是否已安装
if python -c "import torch; print(torch.__version__)" &>/dev/null; then
    TORCH_VER=$(python -c "import torch; print(torch.__version__)")
    echo "  PyTorch 已安装: $TORCH_VER"
else
    echo "  正在安装 PyTorch 2.5.1+cu121..."
    pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu121
    echo "  ✓ PyTorch 安装完成"
fi

# 验证 CUDA 可用
if python -c "import torch; assert torch.cuda.is_available(), 'CUDA not available'"; then
    CUDA_VER=$(python -c "import torch; print(torch.version.cuda)")
    echo "  ✓ CUDA $CUDA_VER 可用, GPU: $(python -c 'import torch; print(torch.cuda.get_device_name(0))')"
else
    echo -e "${YELLOW}  警告: PyTorch CUDA 不可用，训练将使用 CPU（极慢）${NC}"
fi

# ---------- 5. 安装项目依赖 ----------
echo ""
echo "[5/7] 安装项目依赖..."

# 升级 pip
pip install --upgrade pip -q

# 安装 ultralytics 基础依赖（从 pyproject.toml）
echo "  安装 ultralytics 依赖..."
pip install -e "$PROJECT_DIR" -q 2>&1 | tail -1

# 安装额外依赖
echo "  安装额外依赖 (timm, einops, pycocotools)..."
pip install timm einops pycocotools -q
echo "  ✓ 依赖安装完成"

# ---------- 6. 编译 selective_scan CUDA 扩展 ----------
echo ""
echo "[6/7] 编译 selective_scan CUDA 扩展..."

SELECTIVE_SCAN_DIR="$PROJECT_DIR/selective_scan"

if python -c "import selective_scan_cuda_core" 2>/dev/null; then
    echo "  selective_scan 已安装，跳过编译"
else
    if [ "$CUDA_AVAILABLE" = true ]; then
        echo "  正在编译...（需要 1-3 分钟）"
        cd "$SELECTIVE_SCAN_DIR"
        pip install ninja -q
        pip install . 2>&1 | tail -5
        cd "$PROJECT_DIR"

        if python -c "import selective_scan_cuda_core" 2>/dev/null; then
            echo "  ✓ selective_scan 编译安装成功"
        else
            echo -e "${YELLOW}  警告: 编译完成但 import 失败${NC}"
            echo "  请在训练前手动处理: cd selective_scan && pip install ."
        fi
    else
        echo -e "${YELLOW}  跳过: 需要 CUDA Toolkit (nvcc) 来编译 selective_scan${NC}"
        echo "  安装 CUDA Toolkit 后重新运行: bash setup.sh"
    fi
fi

# ---------- 7. 下载 VisDrone 数据集 ----------
echo ""
echo "[7/7] 准备 VisDrone2019 数据集..."

VISDRONE_DIR="$DATASETS_DIR/VisDrone2019"

# 先更新 VisDrone.yaml 中的路径为当前项目目录
python -c "
import re
yaml_path = '$PROJECT_DIR/ultralytics/cfg/datasets/VisDrone.yaml'
with open(yaml_path) as f:
    content = f.read()
content = re.sub(r'^path:.*$', f'path: $VISDRONE_DIR', content, flags=re.M)
with open(yaml_path, 'w') as f:
    f.write(content)
print('Updated VisDrone.yaml path to:', '$VISDRONE_DIR')
"

if [ -d "$VISDRONE_DIR/images/train" ] && [ -d "$VISDRONE_DIR/images/val" ]; then
    TRAIN_COUNT=$(find "$VISDRONE_DIR/images/train" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    VAL_COUNT=$(find "$VISDRONE_DIR/images/val" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    echo "  数据集已存在: 训练集 ${TRAIN_COUNT} 张, 验证集 ${VAL_COUNT} 张"
else
    echo "  数据集不存在，开始下载 (约 2.3GB)..."
    echo "  从 Ultralytics 镜像下载 YOLO 格式的 VisDrone 数据集"

    mkdir -p "$VISDRONE_DIR"

    python -c "
import os, sys, zipfile
from pathlib import Path
from tqdm import tqdm
from ultralytics.utils.downloads import download

visdrone_dir = Path('$VISDRONE_DIR')
base_url = 'https://github.com/ultralytics/yolov5/releases/download/v1.0'

# 下载三个子集
for name in ['VisDrone2019-DET-train', 'VisDrone2019-DET-val', 'VisDrone2019-DET-test-dev']:
    url = f'{base_url}/{name}.zip'
    print(f'  下载 {name}.zip ...')
    download([url], dir=visdrone_dir, curl=True, threads=4)
    print(f'  ✓ {name} 下载解压完成')

# 重命名目录为 YOLO 标准结构
for src, dst in [
    ('VisDrone2019-DET-train', 'images/train'),
    ('VisDrone2019-DET-val',   'images/val'),
    ('VisDrone2019-DET-test-dev', 'images/test'),
]:
    src_dir = visdrone_dir / src
    if src_dir.exists():
        # 移动 images
        dst_img = visdrone_dir / dst
        dst_img.mkdir(parents=True, exist_ok=True)
        for f in (src_dir / 'images').iterdir():
            f.rename(dst_img / f.name)
        # 移动 labels
        dst_lbl = visdrone_dir / dst.replace('images', 'labels')
        dst_lbl.mkdir(parents=True, exist_ok=True)
        lbl_src = src_dir / 'labels'
        if lbl_src.exists():
            for f in lbl_src.iterdir():
                f.rename(dst_lbl / f.name)
        # 清理空目录
        import shutil
        shutil.rmtree(src_dir)

print('✓ VisDrone 数据集下载完成')
print(f'  训练集: {len(list((visdrone_dir/\"images/train\").glob(\"*\")))} 张')
print(f'  验证集: {len(list((visdrone_dir/\"images/val\").glob(\"*\")))} 张')
print(f'  测试集: {len(list((visdrone_dir/\"images/test\").glob(\"*\")))} 张')
"

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}  自动下载失败，请手动下载:${NC}"
        echo "    1. 访问 https://github.com/ultralytics/yolov5/releases/tag/v1.0"
        echo "    2. 下载 VisDrone2019-DET-train.zip, VisDrone2019-DET-val.zip, VisDrone2019-DET-test-dev.zip"
        echo "    3. 解压到 $VISDRONE_DIR/"
        echo "    4. 按 USE.md 中的目录结构整理"
        echo "    5. 重新运行: bash setup.sh"
        exit 1
    fi
fi

# ============================================================
echo ""
echo "================================================"
echo -e "${GREEN}  环境配置完成!${NC}"
echo "================================================"
echo ""
echo "  快速开始训练:"
echo "    source venv/bin/activate"
echo "    export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
echo ""
echo "    # Tiny 模型 (推荐首选)"
echo "    python mbyolo_train.py --model T --task train --epochs 100"
echo ""
echo "    # Base 模型"
echo "    python mbyolo_train.py --model B --task train --epochs 200"
echo ""
echo "    # Large 模型"
echo "    python mbyolo_train.py --model L --task train --epochs 300 --batch_size 1"
echo ""
echo "  更多用法: cat USE.md"
echo "================================================"
