#!/bin/bash
# ============================================================
# Mamba-YOLO 一键环境配置脚本
# 执行: bash setup.sh
# 自动检查并安装所有缺失的依赖
# ============================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
DATASETS_DIR="$PROJECT_DIR/datasets"

echo "================================================"
echo "  Mamba-YOLO 环境配置"
echo "  项目目录: $PROJECT_DIR"
echo "================================================"

# ---------- 0. 检测系统 & 安装系统级依赖 ----------
echo ""
echo "[0/8] 安装系统级依赖..."

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${RED}无法检测操作系统${NC}"
        exit 1
    fi
    echo "  系统: $OS $OS_VERSION"
}

# 检测是否需要 sudo（容器环境通常以 root 运行，无 sudo）
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

detect_os

# 主动刷新 apt 包索引（新容器/新系统可能缓存为空）
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    echo "  → 更新 apt 包索引..."
    APT_OK=false
    for attempt in 1 2 3; do
        if $SUDO apt-get update -qq 2>&1; then
            echo "  ✓ apt 包索引已更新"
            APT_OK=true
            break
        else
            echo "  尝试 $attempt/3 失败，等待 5 秒后重试..."
            sleep 5
        fi
    done
    if [ "$APT_OK" = false ]; then
        echo -e "${RED}apt 包索引更新失败 (重试3次后仍失败)，请检查网络${NC}"
        exit 1
    fi
fi

install_pkg() {
    local pkg=$1
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        echo "    ✓ $pkg 已安装"
        return 0
    fi
    echo "    → 安装 $pkg..."
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        local _log="/tmp/apt_install_$$.log"
        if $SUDO apt-get install -y "$pkg" -qq >"$_log" 2>&1; then
            rm -f "$_log"
        else
            echo "    首次安装失败，更新缓存后重试..."
            cat "$_log" | tail -3
            rm -f "$_log"
            $SUDO apt-get update -qq 2>&1 | tail -1
            $SUDO apt-get install -y "$pkg" -qq || {
                echo -e "${RED}无法安装 $pkg，请检查网络或手动安装${NC}"
                exit 1
            }
        fi
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
        $SUDO yum install -y "$pkg" -q || {
            echo -e "${RED}无法安装 $pkg${NC}"
            exit 1
        }
    else
        echo -e "${RED}不支持的 OS: $OS${NC}"
        exit 1
    fi
}

# 基础编译工具
for pkg in build-essential git curl wget unzip; do
    install_pkg "$pkg"
done

# 1. 自动安装 Python 3.12（如缺少）
echo ""
echo "[1/8] 配置 Python 环境..."

PYTHON_BIN=""
find_python() {
    for py in python3.12 python3.11 python3; do
        if command -v $py &>/dev/null; then
            VER=$($py --version 2>&1 | grep -oP '\d+\.\d+')
            MAJOR=$(echo $VER | cut -d. -f1)
            MINOR=$(echo $VER | cut -d. -f2)
            if [ "$MAJOR" -ge 3 ] && [ "$MINOR" -ge 11 ]; then
                PYTHON_BIN=$py
                return 0
            fi
        fi
    done
    return 1
}

if find_python; then
    echo "  ✓ 找到 $PYTHON_BIN ($VER)"
else
    echo "  Python >= 3.11 未找到，自动安装 Python 3.12..."
    if [ "$OS" = "ubuntu" ]; then
        $SUDO apt-get update -qq 2>&1 | tail -1
        # Ubuntu 22.04 需要 deadsnakes PPA
        if [ "$OS_VERSION" = "22.04" ]; then
            install_pkg "software-properties-common"
            $SUDO add-apt-repository -y ppa:deadsnakes/ppa -qq 2>&1 | tail -1
            $SUDO apt-get update -qq 2>&1 | tail -1
        fi
        install_pkg "python3.12"
        install_pkg "python3.12-venv"
        install_pkg "python3.12-dev"
    elif [ "$OS" = "debian" ]; then
        $SUDO apt-get update -qq 2>&1 | tail -1
        install_pkg "python3"
        install_pkg "python3-venv"
        install_pkg "python3-dev"
    else
        install_pkg "python3"
        install_pkg "python3-devel"
    fi
    # 再次查找
    if ! find_python; then
        echo -e "${RED}Python 安装失败，请手动安装 Python >= 3.11${NC}"
        exit 1
    fi
    echo "  ✓ Python $VER 安装成功"
fi

# 2. 自动安装 CUDA Toolkit（如缺少 nvcc）
echo ""
echo "[2/8] 配置 CUDA Toolkit..."

NEED_CUDA=false
CUDA_AVAILABLE=false

if command -v nvcc &>/dev/null; then
    CUDA_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K\d+\.\d+' || echo "")
    if [ -n "$CUDA_VER" ]; then
        echo "  ✓ nvcc 版本: $CUDA_VER"
        CUDA_AVAILABLE=true
    fi
fi

if [ "$CUDA_AVAILABLE" = false ]; then
    echo "  nvcc 未找到，尝试自动安装 CUDA Toolkit..."
    # 检查是否有 NVIDIA 驱动 (至少需要驱动才能用 GPU)
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${YELLOW}  警告: nvidia-smi 未找到，请先安装 NVIDIA 驱动${NC}"
        echo "  Ubuntu: sudo apt install nvidia-driver-535"
        echo "  安装后重启，然后重新运行 bash setup.sh"
    fi

    if [ "$OS" = "ubuntu" ]; then
        # 尝试从 NVIDIA 官方仓库安装 cuda-toolkit
        if ! dpkg -s cuda-toolkit-12-3 &>/dev/null && ! dpkg -s cuda-toolkit-12-4 &>/dev/null; then
            echo "  → 从 apt 安装 nvidia-cuda-toolkit..."
            $SUDO apt-get update -qq 2>&1 | tail -1
            # 优先用 apt 自带的
            if apt-cache show nvidia-cuda-toolkit &>/dev/null 2>&1; then
                $SUDO apt-get install -y nvidia-cuda-toolkit -qq 2>&1 | tail -3
            else
                # 尝试 NVIDIA 官方 repo
                wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -O /tmp/cuda-keyring.deb 2>/dev/null
                $SUDO dpkg -i /tmp/cuda-keyring.deb 2>/dev/null || true
                $SUDO apt-get update -qq 2>&1 | tail -1
                $SUDO apt-get install -y cuda-toolkit-12-4 -qq 2>&1 | tail -3 || \
                $SUDO apt-get install -y cuda-toolkit-12-3 -qq 2>&1 | tail -3 || true
            fi
        fi

        # 尝试多种 nvcc 路径
        for nvcc_path in /usr/local/cuda/bin/nvcc /usr/lib/cuda/bin/nvcc /usr/bin/nvcc; do
            if [ -x "$nvcc_path" ]; then
                export PATH=$(dirname "$nvcc_path"):$PATH
                CUDA_AVAILABLE=true
                echo "  ✓ nvcc 找到: $nvcc_path"
                break
            fi
        done
    fi

    if [ "$CUDA_AVAILABLE" = false ]; then
        echo -e "${YELLOW}  警告: 自动安装 CUDA Toolkit 失败${NC}"
        echo "  将跳过 selective_scan 编译，训练时使用 CPU（极慢）"
        echo "  手动安装: https://developer.nvidia.com/cuda-downloads"
    fi
fi

# 检查 GPU
if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${RED}错误: 未检测到 nvidia-smi，需要 NVIDIA GPU 和驱动${NC}"
    echo "  安装驱动: sudo apt install nvidia-driver-535 && sudo reboot"
    exit 1
else
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1
fi

# 3. 创建虚拟环境
echo ""
echo "[3/8] 创建 Python 虚拟环境..."

if [ -d "$VENV_DIR" ]; then
    echo "  虚拟环境已存在: $VENV_DIR"
    echo "  如需重建请先删除: rm -rf venv/"
else
    # 确保 venv 模块可用
    if ! $PYTHON_BIN -m venv --help &>/dev/null 2>&1; then
        echo "  → 安装 python3-venv..."
        install_pkg "python3.12-venv" || install_pkg "python3-venv"
    fi
    $PYTHON_BIN -m venv "$VENV_DIR"
    echo "  ✓ 虚拟环境创建完成"
fi

source "$VENV_DIR/bin/activate"
echo "  Python: $(python --version)"

# 4. 安装 PyTorch（自动匹配 CUDA 版本）
echo ""
echo "[4/8] 安装 PyTorch..."

if python -c "import torch; print(torch.__version__)" &>/dev/null 2>&1; then
    TORCH_VER=$(python -c "import torch; print(torch.__version__)")
    echo "  PyTorch 已安装: $TORCH_VER"
else
    # 检测 CUDA 版本来选择 PyTorch 版本
    CUDA_MAJOR=""
    if [ "$CUDA_AVAILABLE" = true ] && command -v nvcc &>/dev/null; then
        CUDA_FULL=$(nvcc --version 2>/dev/null | grep -oP 'release \K\d+\.\d+' || echo "")
        CUDA_MAJOR=$(echo "$CUDA_FULL" | cut -d. -f1)
    fi

    case "$CUDA_MAJOR" in
        12)
            echo "  → 安装 PyTorch (CUDA 12.1)..."
            pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu121 -q
            ;;
        11)
            echo "  → 安装 PyTorch (CUDA 11.8)..."
            pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu118 -q
            ;;
        *)
            echo -e "  ${YELLOW}无法确定 CUDA 版本，安装 CPU 版 PyTorch${NC}"
            pip install torch==2.5.1 torchvision==0.20.1 -q
            ;;
    esac
    echo "  ✓ PyTorch 安装完成: $(python -c 'import torch; print(torch.__version__)')"
fi

# 验证 CUDA
if python -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
    echo "  ✓ GPU: $(python -c 'import torch; print(torch.cuda.get_device_name(0))')"
else
    echo -e "${RED}错误: PyTorch GPU 不可用，无法训练${NC}"
    echo "  检查: nvidia-smi 是否正常？驱动版本是否匹配？"
    exit 1
fi

# 5. 安装项目依赖
echo ""
echo "[5/8] 安装项目依赖..."

pip install --upgrade pip -q 2>&1 | tail -1

echo "  → 安装 ultralytics 基础依赖..."
pip install -e "$PROJECT_DIR" -q 2>&1 | tail -1

echo "  → 安装额外依赖 (timm, einops, pycocotools)..."
pip install timm einops pycocotools -q 2>&1 | tail -1
echo "  ✓ 所有依赖安装完成"

# 6. 编译 selective_scan CUDA 扩展
echo ""
echo "[6/8] 编译 selective_scan CUDA 扩展..."

SELECTIVE_SCAN_DIR="$PROJECT_DIR/selective_scan"

if python -c "import selective_scan_cuda_core" 2>/dev/null; then
    echo "  ✓ selective_scan 已安装，跳过编译"
elif [ "$CUDA_AVAILABLE" = true ]; then
    echo "  → 编译中 (须要 1-3 分钟)..."
    cd "$SELECTIVE_SCAN_DIR"
    pip install ninja -q 2>&1 | tail -1
    if pip install . 2>&1 | tail -5; then
        cd "$PROJECT_DIR"
        if python -c "import selective_scan_cuda_core" 2>/dev/null; then
            echo "  ✓ selective_scan 编译安装成功"
        else
            echo -e "${RED}编译完成但 import 失败${NC}"
            echo "  尝试: cd selective_scan && pip install . 查看详细错误"
            exit 1
        fi
    else
        cd "$PROJECT_DIR"
        echo -e "${RED}selective_scan 编译失败${NC}"
        echo "  检查: nvcc --version 是否可用？"
        exit 1
    fi
else
    echo -e "${RED}错误: 需要 CUDA Toolkit (nvcc) 编译 selective_scan${NC}"
    echo "  Ubuntu: sudo apt install nvidia-cuda-toolkit"
    echo "  或从 https://developer.nvidia.com/cuda-downloads 安装"
    exit 1
fi

# 7. 下载 VisDrone 数据集
echo ""
echo "[7/8] 准备 VisDrone2019 数据集..."

VISDRONE_DIR="$DATASETS_DIR/VisDrone2019"

# 更新 VisDrone.yaml 路径为当前项目目录
python -c "
import re
yaml_path = '$PROJECT_DIR/ultralytics/cfg/datasets/VisDrone.yaml'
with open(yaml_path) as f:
    content = f.read()
content = re.sub(r'^path:.*$', f'path: $VISDRONE_DIR', content, flags=re.M)
with open(yaml_path, 'w') as f:
    f.write(content)
"

if [ -d "$VISDRONE_DIR/images/train" ] && [ -d "$VISDRONE_DIR/images/val" ]; then
    TRAIN_COUNT=$(find "$VISDRONE_DIR/images/train" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    VAL_COUNT=$(find "$VISDRONE_DIR/images/val" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    echo "  ✓ 数据集已存在: 训练${TRAIN_COUNT}张, 验证${VAL_COUNT}张"
else
    echo "  → 下载 VisDrone 数据集 (约 2.3GB)..."
    echo "  从 Ultralytics 镜像下载 YOLO 格式数据..."

    mkdir -p "$VISDRONE_DIR"

    python -c "
import sys
from pathlib import Path
from ultralytics.utils.downloads import download

visdrone_dir = Path('$VISDRONE_DIR')
base_url = 'https://github.com/ultralytics/yolov5/releases/download/v1.0'

for name in ['VisDrone2019-DET-train', 'VisDrone2019-DET-val', 'VisDrone2019-DET-test-dev']:
    url = f'{base_url}/{name}.zip'
    print(f'  下载 {name}.zip ...')
    download([url], dir=visdrone_dir, curl=True, threads=4)
    print(f'  ✓ {name} 下载完成')

# 整理为 YOLO 标准目录结构
import shutil
for src, dst in [
    ('VisDrone2019-DET-train', 'images/train'),
    ('VisDrone2019-DET-val',   'images/val'),
    ('VisDrone2019-DET-test-dev', 'images/test'),
]:
    src_dir = visdrone_dir / src
    if src_dir.exists():
        dst_img = visdrone_dir / dst
        dst_img.mkdir(parents=True, exist_ok=True)
        for f in (src_dir / 'images').iterdir():
            f.rename(dst_img / f.name)
        dst_lbl = visdrone_dir / dst.replace('images', 'labels')
        dst_lbl.mkdir(parents=True, exist_ok=True)
        lbl_src = src_dir / 'labels'
        if lbl_src.exists():
            for f in lbl_src.iterdir():
                f.rename(dst_lbl / f.name)
        shutil.rmtree(src_dir)

print('✓ VisDrone 数据集下载完成')
print(f'  训练: {len(list((visdrone_dir/\"images/train\").glob(\"*\")))} 张')
print(f'  验证: {len(list((visdrone_dir/\"images/val\").glob(\"*\")))} 张')
print(f'  测试: {len(list((visdrone_dir/\"images/test\").glob(\"*\")))} 张')
"

    if [ $? -ne 0 ]; then
        echo -e "${RED}数据集下载失败${NC}"
        echo "  手动下载: 从 https://github.com/ultralytics/yolov5/releases/tag/v1.0"
        echo "  下载 3 个 zip，解压到 $VISDRONE_DIR/，目录结构见 USE.md"
        exit 1
    fi
fi

# 8. 验证环境完整性
echo ""
echo "[8/8] 验证环境完整性..."

ERRORS=0

echo -n "  PyTorch + CUDA ... "
python -c "import torch; assert torch.cuda.is_available(); print('OK')" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }

echo -n "  ultralytics ... "
python -c "import ultralytics; print('OK')" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }

echo -n "  selective_scan ... "
python -c "import selective_scan_cuda_core; print('OK')" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }

echo -n "  timm / einops / pycocotools ... "
python -c "import timm, einops, pycocotools; print('OK')" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }

echo -n "  VisDrone 数据集 ... "
python -c "
from pathlib import Path
d = Path('$VISDRONE_DIR')
assert (d/'images'/'train').exists(), 'train missing'
assert (d/'images'/'val').exists(), 'val missing'
assert (d/'labels'/'train').exists(), 'labels missing'
print('OK')
" || { echo "FAIL"; ERRORS=$((ERRORS+1)); }

if [ $ERRORS -gt 0 ]; then
    echo -e "\n${RED}${ERRORS} 项检查失败，请查看上方错误信息${NC}"
    exit 1
fi

# ============================================================
echo ""
echo "================================================"
echo -e "${GREEN}  环境配置全部完成，可以开始训练!${NC}"
echo "================================================"
echo ""
echo "  每次使用前激活环境:"
echo "    source venv/bin/activate"
echo "    export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
echo ""
echo "  训练命令:"
echo "    python mbyolo_train.py --model T --task train --epochs 100"
echo "    python mbyolo_train.py --model B --task train --epochs 200"
echo "    python mbyolo_train.py --model L --task train --epochs 300 --batch_size 1"
echo ""
echo "  更多用法: cat USE.md"
echo "================================================"
