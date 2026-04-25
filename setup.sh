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
    echo "  Python >= 3.11 未找到，尝试通过 conda 安装 Python 3.12..."

    CONDA_BIN=""
    for cpath in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "/opt/conda/bin/conda" "/root/miniconda3/bin/conda"; do
        if [ -x "$cpath" ]; then
            CONDA_BIN="$cpath"
            break
        fi
    done
    if [ -z "$CONDA_BIN" ]; then
        CONDA_BIN="conda"
    fi
    CONDA_AVAILABLE=false
    if command -v "$CONDA_BIN" &>/dev/null || [ -x "$CONDA_BIN" ]; then
        CONDA_AVAILABLE=true
    fi

    if $CONDA_AVAILABLE && $CONDA_BIN --version &>/dev/null 2>&1; then
        echo "  ✓ 找到 conda: $CONDA_BIN"
        # 在 base 环境中确认 Python 版本
        CONDA_PY=$($CONDA_BIN run -n base python --version 2>&1 | grep -oP '\d+\.\d+')
        CONDA_MAJOR=$(echo "$CONDA_PY" | cut -d. -f1)
        CONDA_MINOR=$(echo "$CONDA_PY" | cut -d. -f2)
        if [ "$CONDA_MAJOR" -ge 3 ] && [ "${CONDA_MINOR:-0}" -ge 11 ]; then
            echo "  conda base 环境已有 Python $CONDA_PY，无需安装"
            PYTHON_BIN="$CONDA_BIN run -n base python"
            VER="$CONDA_PY"
        else
            echo "  → conda 安装 Python 3.12 (可能需要几分钟)..."
            $CONDA_BIN install -y -n base python=3.12
            PYTHON_BIN="$CONDA_BIN run -n base python"
            VER="3.12"
        fi
    else
        echo "  conda 不可用，尝试 Miniconda（从官方源下载）..."
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
        MINICONDA_SH="/tmp/miniconda_install.sh"
        curl -fsSL "$MINICONDA_URL" -o "$MINICONDA_SH" 2>&1 || wget -q "$MINICONDA_URL" -O "$MINICONDA_SH" 2>&1
        if [ -s "$MINICONDA_SH" ]; then
            echo "  → 安装 Miniconda..."
            bash "$MINICONDA_SH" -b -p "$HOME/miniconda3"
            CONDA_BIN="$HOME/miniconda3/bin/conda"
            echo "  → conda 安装 Python 3.12 (可能需要几分钟)..."
            $CONDA_BIN install -y -n base python=3.12
            PYTHON_BIN="$CONDA_BIN run -n base python"
            VER="3.12"
            rm -f "$MINICONDA_SH"
        else
            echo -e "${YELLOW}  Miniconda 下载失败，回退到系统包管理器${NC}"
            if [ "$OS" = "ubuntu" ]; then
                if [ "$OS_VERSION" = "22.04" ]; then
                    install_pkg "software-properties-common"
                    $SUDO add-apt-repository -y ppa:deadsnakes/ppa 2>&1 | tail -3
                    $SUDO apt-get update -qq 2>&1 | tail -1
                fi
                install_pkg "python3.12"
                install_pkg "python3.12-venv"
                install_pkg "python3.12-dev"
            elif [ "$OS" = "debian" ]; then
                install_pkg "python3"
                install_pkg "python3-venv"
                install_pkg "python3-dev"
            else
                install_pkg "python3"
                install_pkg "python3-devel"
            fi
        fi
    fi

    # 确认已安装
    if [ -n "$PYTHON_BIN" ]; then
        ACTUAL_VER=$(eval "$PYTHON_BIN --version" 2>&1)
        echo "  ✓ Python 安装成功: $ACTUAL_VER"
    elif ! find_python; then
        echo -e "${RED}Python 安装失败，请手动安装 Python >= 3.11${NC}"
        exit 1
    fi
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

# 4. 安装 PyTorch（自动匹配系统 CUDA 版本）
echo ""
echo "[4/8] 安装 PyTorch..."

# 先检测系统 nvcc 的 CUDA 大版本（用于一致性校验）
SYS_CUDA_MAJOR=""
if [ "$CUDA_AVAILABLE" = true ] && command -v nvcc &>/dev/null; then
    SYS_CUDA_FULL=$(nvcc --version 2>/dev/null | grep -oP 'release \K\d+\.\d+' || echo "")
    SYS_CUDA_MAJOR=$(echo "$SYS_CUDA_FULL" | cut -d. -f1)
    echo "  系统 CUDA: $SYS_CUDA_FULL"
fi

NEED_TORCH_INSTALL=false
if python -c "import torch; print(torch.__version__)" &>/dev/null 2>&1; then
    TORCH_VER=$(python -c "import torch; print(torch.__version__)")
    TORCH_CUDA=$(python -c "import torch; print(torch.version.cuda)" 2>/dev/null || echo "cpu")
    TORCH_CUDA_MAJOR=$(echo "$TORCH_CUDA" | cut -d. -f1)
    echo "  PyTorch 已安装: $TORCH_VER (CUDA $TORCH_CUDA)"

    # 检查 PyTorch CUDA 版本是否与系统 nvcc 匹配
    if [ -n "$SYS_CUDA_MAJOR" ] && [ "$TORCH_CUDA_MAJOR" != "$SYS_CUDA_MAJOR" ]; then
        echo -e "  ${YELLOW}CUDA 版本不匹配: PyTorch=$TORCH_CUDA_MAJOR, nvcc=$SYS_CUDA_MAJOR${NC}"
        echo "  → 卸载旧版 PyTorch，重新安装匹配版本..."
        pip uninstall -y torch torchvision 2>/dev/null || true
        NEED_TORCH_INSTALL=true
    fi
else
    NEED_TORCH_INSTALL=true
fi

if [ "$NEED_TORCH_INSTALL" = true ]; then
    case "$SYS_CUDA_MAJOR" in
        12)
            echo "  → 安装 PyTorch (CUDA 12.1) 约 2GB, 可能需要几分钟..."
            pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu121
            ;;
        11)
            echo "  → 安装 PyTorch (CUDA 11.8) 约 2GB, 可能需要几分钟..."
            pip install torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu118
            ;;
        *)
            echo -e "  ${YELLOW}无法确定系统 CUDA 版本，安装 CPU 版 PyTorch${NC}"
            pip install torch==2.5.1 torchvision==0.20.1
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

pip install --upgrade pip

echo "  → 安装 ultralytics 基础依赖..."
pip install -e "$PROJECT_DIR"

echo "  → 安装额外依赖 (timm, einops, pycocotools)..."
pip install timm einops pycocotools
echo "  ✓ 所有依赖安装完成"

# 6. 编译 selective_scan CUDA 扩展
echo ""
echo "[6/8] 编译 selective_scan CUDA 扩展..."

SELECTIVE_SCAN_DIR="$PROJECT_DIR/selective_scan"

if python -c "import selective_scan_cuda_core" 2>/dev/null; then
    echo "  ✓ selective_scan 已安装，跳过编译"
elif [ "$CUDA_AVAILABLE" = true ]; then
    echo "  → 编译中 (须要 1-3 分钟, 此过程会产生大量输出)..."

    # 确保 CUDA_HOME 已设置（PyTorch 的 cpp_extension 需要）
    if [ -z "${CUDA_HOME:-}" ]; then
        if [ -d "/usr/local/cuda" ]; then
            export CUDA_HOME="/usr/local/cuda"
            echo "  CUDA_HOME 设置为: $CUDA_HOME"
        fi
    fi

    cd "$SELECTIVE_SCAN_DIR"
    # 清理之前的编译残留
    rm -rf build/ dist/ *.egg-info 2>/dev/null || true
    pip install ninja wheel
    # 保存完整编译日志并实时显示进度
    BUILD_LOG="/tmp/selective_scan_build_$$.log"
    if pip install . --no-build-isolation 2>&1 | tee "$BUILD_LOG"; then
        cd "$PROJECT_DIR"
        echo "  → 验证 selective_scan 导入..."
        IMPORT_LOG="/tmp/selective_scan_import_$$.log"
        # PyTorch 的 .so 库路径需要加到 LD_LIBRARY_PATH
        TORCH_LIB=$(python -c "import torch; print(torch.utils.cmake_prefix_path+'/../../../lib')" 2>/dev/null || echo "")
        if [ -z "$TORCH_LIB" ] || [ ! -d "$TORCH_LIB" ]; then
            TORCH_LIB=$(python -c "import torch, os; print(os.path.join(os.path.dirname(torch.__file__), 'lib'))" 2>/dev/null)
        fi
        export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH}"
        if python -c "import selective_scan_cuda_core" >"$IMPORT_LOG" 2>&1; then
            rm -f "$BUILD_LOG" "$IMPORT_LOG"
            # 持久化 LD_LIBRARY_PATH 供后续步骤使用
            export LD_LIBRARY_PATH="${TORCH_LIB}:${LD_LIBRARY_PATH}"
            echo "  ✓ selective_scan 编译安装成功"
        else
            IMPORT_RC=$?
            echo -e "  ${RED}编译完成但 import 失败 (exit=$IMPORT_RC)${NC}"
            echo "  --- import 错误输出 ---"
            cat "$IMPORT_LOG"
            echo "  --- 编译日志最后 10 行 ---"
            echo "  完整编译日志: $BUILD_LOG"
            tail -20 "$BUILD_LOG"
            exit 1
        fi
    else
        cd "$PROJECT_DIR"
        echo -e "${RED}selective_scan 编译失败${NC}"
        echo "  完整编译日志: $BUILD_LOG"
        echo "  --- 最后 30 行 ---"
        tail -30 "$BUILD_LOG"
        echo "  --- 检查关键条件 ---"
        echo "  nvcc: $(which nvcc 2>/dev/null || echo 'NOT FOUND')"
        echo "  CUDA_HOME: ${CUDA_HOME:-NOT SET}"
        echo "  torch cuda: $(python -c 'import torch; print(torch.version.cuda)' 2>/dev/null || echo 'N/A')"
        echo "  gcc: $(gcc --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
        exit 1
    fi
else
    echo -e "${RED}错误: 需要 CUDA Toolkit (nvcc) 编译 selective_scan${NC}"
    echo "  Ubuntu: sudo apt install nvidia-cuda-toolkit"
    echo "  或从 https://developer.nvidia.com/cuda-downloads 安装"
    exit 1
fi

# 7. 下载 VisDrone-VID 数据集
echo ""
echo "[7/8] 准备 VisDrone-VID 数据集..."

VISDRONE_DIR="$DATASETS_DIR/VisDrone-VID"

# 更新 VisDrone-VID.yaml 路径为当前项目目录
python3 << PYEOF
import re
yaml_path = '$PROJECT_DIR/ultralytics/cfg/datasets/VisDrone-VID.yaml'
with open(yaml_path) as f:
    content = f.read()
content = re.sub(r'^path:.*$', f'path: $VISDRONE_DIR', content, flags=re.M)
with open(yaml_path, 'w') as f:
    f.write(content)
PYEOF

if [ -d "$VISDRONE_DIR/images/train" ] && [ -d "$VISDRONE_DIR/images/val" ]; then
    TRAIN_COUNT=$(find "$VISDRONE_DIR/images/train" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    VAL_COUNT=$(find "$VISDRONE_DIR/images/val" -type f \( -name "*.jpg" -o -name "*.png" \) 2>/dev/null | wc -l)
    echo "  ✓ 数据集已存在: 训练${TRAIN_COUNT}张, 验证${VAL_COUNT}张"
else
    echo "  → 下载 VisDrone-VID 数据集 (约 9GB，需要较长时间)..."
    echo "  主下载源: hf-mirror (HuggingFace 国内镜像)"
    echo ""

    mkdir -p "$VISDRONE_DIR"

    # 确保 requests 已安装
    pip install requests -q

    python3 << 'PYEOF'
import os, sys, zipfile, shutil
from pathlib import Path
from PIL import Image

visdrone_dir = Path(os.environ['VISDRONE_DIR'])

# hf-mirror (国内 HuggingFace 镜像) 优先
HF_MIRROR = 'https://hf-mirror.com/datasets/AndriiDemk/visDrone_copy/resolve/main'

# Google Drive 备用 (使用 confirm=t 绕过确认页)
GDRIVE_BASE = 'https://drive.usercontent.google.com/download'

FILES = {
    'VisDrone2019-VID-train.zip': {
        'hf': f'{HF_MIRROR}/VisDrone2019-VID-train.zip',
        'gd_id': '1NSNapZQHar22OYzQYuXCugA3QlMndzvw',
        'size_gb': 7.5,
    },
    'VisDrone2019-VID-val.zip': {
        'hf': f'{HF_MIRROR}/VisDrone2019-VID-val.zip',
        'gd_id': '1xuG7Z3IhVfGGKMe3Yj6RnrFHqo_d2a1B',
        'size_gb': 1.5,
    },
    'VisDrone2019-VID-test-dev.zip': {
        'hf': None,  # hf-mirror 暂无 test-dev
        'gd_id': '1-BEq--FcjshTF1UwUabby_LHhYj41os5',
        'size_gb': 2.1,
    },
}

import requests

def download_http(url, output_path, label):
    """下载 HTTP 文件，显示进度"""
    if output_path.exists() and output_path.stat().st_size > 10000:
        print(f'  ✓ {output_path.name} 已存在，跳过')
        return True
    print(f'  ⬇ {label}: {output_path.name} ...')
    try:
        with requests.get(url, stream=True, timeout=120) as resp:
            resp.raise_for_status()
            total = int(resp.headers.get('content-length', 0))
            tmp = output_path.with_suffix('.part')
            downloaded = 0
            with open(tmp, 'wb') as f:
                for chunk in resp.iter_content(chunk_size=8*1024*1024):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        if total:
                            pct = downloaded / total * 100
                            mb = downloaded / 1024 / 1024
                            total_mb = total / 1024 / 1024
                            print(f'\r    {pct:.0f}%  {mb:.0f}/{total_mb:.0f} MB', end='', flush=True)
            print()
            tmp.rename(output_path)
            mb = output_path.stat().st_size / 1024 / 1024
            print(f'  ✓ {output_path.name} 完成 ({mb:.0f} MB)')
            return True
    except Exception as e:
        print(f'\n  ✗ {output_path.name} HTTP 下载失败: {e}')
        if tmp.exists():
            tmp.unlink()
        return False

def download_gdrive(file_id, output_path):
    """Google Drive 备用下载 (confirm=t 绕过确认)"""
    if output_path.exists() and output_path.stat().st_size > 10000:
        print(f'  ✓ {output_path.name} 已存在，跳过')
        return True
    print(f'  ⬇ Google Drive: {output_path.name} ...')
    url = f'{GDRIVE_BASE}?id={file_id}&export=download&confirm=t'
    return download_http(url, output_path, 'Google Drive')

# ---- Download ----
failed = []
for fname, info in FILES.items():
    zip_path = visdrone_dir / fname
    size_str = f'{info["size_gb"]:.1f} GB'

    if zip_path.exists() and zip_path.stat().st_size > 10000:
        print(f'  ✓ {fname} ({size_str}) 已存在，跳过')
        continue

    success = False
    # 1) 优先 hf-mirror
    if info['hf']:
        success = download_http(info['hf'], zip_path, 'hf-mirror')
    # 2) 回退 Google Drive
    if not success:
        success = download_gdrive(info['gd_id'], zip_path)

    if not success:
        failed.append(fname)
    print()

if failed:
    print()
    print('='*56)
    print('  以下文件下载失败:')
    for f in failed:
        print(f'    - {f}')
    print()
    print('  可手动下载后放到以下目录，再重新运行 bash setup.sh:')
    print(f'    {visdrone_dir}/')
    print()
    print('  百度网盘备用链接:')
    print('    train:     https://pan.baidu.com/s/1kC3NTK6MPVv3D1CY9gXaCQ')
    print('    val:       https://pan.baidu.com/s/12-A6Mg1Gg7hyS4WwG27dDw')
    print('    test-dev:  https://pan.baidu.com/s/1r1P5aJ1zOlQH_58LfYFzQQ')
    print('='*56)
    sys.exit(1)

# Extract
for fname in FILES:
    zip_path = visdrone_dir / fname
    if not zip_path.exists():
        continue
    extract_dir = visdrone_dir / fname.replace('.zip', '')
    if extract_dir.exists():
        print(f'  {fname} 已解压，跳过')
        continue
    print(f'  → 解压 {fname} ...')
    with zipfile.ZipFile(zip_path, 'r') as zf:
        zf.extractall(visdrone_dir)
    print(f'  ✓ {fname} 解压完成')

# Convert VID annotations to YOLO format
# VID dataset structure:
#   VisDrone2019-VID-train/annotations/<seq>.txt    (per-sequence, all frames)
#   VisDrone2019-VID-train/sequences/<seq>/<id>.jpg (per-frame images)
# VID annotation format (10 fields):
#   frame_index, target_id, bbox_left, bbox_top, bbox_width, bbox_height, score, category, truncation, occlusion

def convert_split(split_name, dst_name):
    split_dir = visdrone_dir / split_name
    ann_dir = split_dir / 'annotations'
    seq_dir = split_dir / 'sequences'
    if not ann_dir.is_dir() or not seq_dir.is_dir():
        print(f'  ⚠ {split_name}: annotations/ 或 sequences/ 缺失，跳过')
        return

    dst_img = visdrone_dir / 'images' / dst_name
    dst_lbl = visdrone_dir / 'labels' / dst_name
    dst_img.mkdir(parents=True, exist_ok=True)
    dst_lbl.mkdir(parents=True, exist_ok=True)

    total_imgs, total_objs = 0, 0
    for ann_file in sorted(ann_dir.glob('*.txt')):
        seq_name = ann_file.stem
        seq_path = seq_dir / seq_name
        if not seq_path.is_dir():
            continue

        # Parse all annotations for this sequence, grouped by frame
        frame_boxes = {}
        for line in ann_file.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) < 10:
                continue
            frame_id = int(parts[0])
            left, top, bw, bh = map(float, parts[2:6])
            score = int(float(parts[6]))
            category = int(float(parts[7]))
            if score != 1 or category < 1 or category > 10:
                continue
            if bw <= 0 or bh <= 0:
                continue
            frame_boxes.setdefault(frame_id, []).append((category - 1, left, top, bw, bh))

        # Convert each frame image
        for img_file in sorted(seq_path.glob('*.jpg')):
            try:
                frame_id = int(img_file.stem)
            except ValueError:
                continue

            canonical = f'{seq_name}_img{frame_id:07d}'
            dst_ip = dst_img / f'{canonical}.jpg'

            # Copy image
            if not dst_ip.exists():
                shutil.copy2(img_file, dst_ip)

            # Read image size and convert boxes
            try:
                with Image.open(img_file) as im:
                    iw, ih = im.size
            except Exception:
                continue

            lines = []
            for cls, x1, y1, bw, bh in frame_boxes.get(frame_id, []):
                xc = max(0.0, min(1.0, (x1 + (x1 + bw)) / 2.0 / iw))
                yc = max(0.0, min(1.0, (y1 + (y1 + bh)) / 2.0 / ih))
                nw = max(0.0, min(1.0, bw / iw))
                nh = max(0.0, min(1.0, bh / ih))
                lines.append(f'{cls} {xc:.6f} {yc:.6f} {nw:.6f} {nh:.6f}')

            (dst_lbl / f'{canonical}.txt').write_text('\n'.join(lines) + ('\n' if lines else ''))
            total_imgs += 1
            total_objs += len(lines)

    print(f'  {split_name} → {dst_name}: {total_imgs} images, {total_objs} boxes')

# Convert each split
for split, dst in [('VisDrone2019-VID-train', 'train'),
                    ('VisDrone2019-VID-val', 'val'),
                    ('VisDrone2019-VID-test-dev', 'test')]:
    convert_split(split, dst)

# Clean up extracted dirs and zips
for d in visdrone_dir.iterdir():
    if d.is_dir() and d.name.startswith('VisDrone2019-VID-') and d.name not in ('images', 'labels'):
        shutil.rmtree(d, ignore_errors=True)

# Report
for split in ['train', 'val', 'test']:
    img_d = visdrone_dir / 'images' / split
    lbl_d = visdrone_dir / 'labels' / split
    n = len(list(img_d.glob('*'))) if img_d.exists() else 0
    print(f'  {split}: {n} images')
print('✓ VisDrone-VID 数据集准备完成')
PYEOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}数据集下载失败${NC}"
        echo "  手动下载: https://github.com/VisDrone/VisDrone-Dataset"
        echo "  Google Drive 链接见项目 README"
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

echo -n "  VisDrone-VID 数据集 ... "
if python3 << PYEOF
from pathlib import Path
d = Path('$VISDRONE_DIR')
assert (d/'images'/'train').exists(), 'train missing'
assert (d/'images'/'val').exists(), 'val missing'
assert (d/'labels'/'train').exists(), 'labels missing'
print('OK')
PYEOF
then
    :
else
    echo "FAIL"
    ERRORS=$((ERRORS+1))
fi

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
echo "    export LD_LIBRARY_PATH=\$(python -c \"import torch, os; print(os.path.join(os.path.dirname(torch.__file__), 'lib'))\"):\$LD_LIBRARY_PATH"
echo ""
echo "  训练命令 (VisDrone-VID):"
echo "    python mbyolo_train.py --model T --task train --epochs 100"
echo "    python mbyolo_train.py --model B --task train --epochs 200"
echo "    python mbyolo_train.py --model L --task train --epochs 300 --batch_size 1"
echo ""
echo "  更多用法: cat README.md"
echo "================================================"
