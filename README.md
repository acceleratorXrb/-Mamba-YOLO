# [AAAI2025] Mamba YOLO: A Simple Baseline for Object Detection with State Space Model

![Python 3.11](https://img.shields.io/badge/python-3.11-g) ![pytorch 2.3.0](https://img.shields.io/badge/pytorch-2.3.0-blue.svg)

<div align="center">
  <img src="./asserts/mambayolo.jpg" width="1200px"/>
</div>

## 项目简介

Mamba YOLO 是 AAAI 2025 论文的官方实现。核心思想是将 **State Space Model（Mamba/SSM）** 引入 YOLO 目标检测框架，用基于 Vision State Space 的 VSSBlock/XSSBlock 替换传统卷积模块作为 backbone 和 neck，从而在不显著增加计算量的前提下提升检测精度。

- **论文**: [Mamba YOLO: SSMs-Based YOLO For Object Detection](https://arxiv.org/abs/2406.05835)
- **原始仓库**: [HZAI-ZJNU/Mamba-YOLO](https://github.com/HZAI-ZJNU/Mamba-YOLO)
- **基础框架**: 基于 [Ultralytics](https://github.com/ultralytics/ultralytics) YOLOv8 (v8.2.29) 修改
- **Selective Scan 算子**: 来自 [VMamba](https://github.com/MzeroMiko/VMamba)

---

## 技术架构

### State Space Model（SSM）简介

传统的 Transformer 依赖 Self-Attention，计算复杂度随序列长度平方增长。SSM（Structured State Space Model）将输入序列建模为连续时间动态系统：

```
h'(t) = A·h(t) + B·x(t)
y(t)  = C·h(t) + D·x(t)
```

通过在 4 个方向（正行、反转行、正列、反转列）对特征图进行一维 selective scan，SSM 能以线性复杂度捕捉长距离依赖关系，同时保持全局感受野。

### 核心模块

本项目在 `ultralytics/nn/modules/mamba_yolo.py` 中定义了 4 个自定义模块：

| 模块 | 位置 | 功能 |
|------|------|------|
| **SimpleStem** | Backbone 第一层 | 两个 3×3 Conv 实现 4× 下采样（P2/4） |
| **VSSBlock** | Backbone | Vision State Space Block，等价于 Transformer Encoder Block，用 SS2D 替代 Self-Attention |
| **VisionClueMerge** | Backbone 下采样层 | 将 2×2 空间块展开为 4×channels，类似 Swin 的 PatchMerge |
| **XSSBlock** | Neck（PAFPN） | Cross State Space Block，用于多尺度特征融合 |

**VSSBlock 内部结构**：

```
输入 → ProjConv(1×1+BN+SiLU) → LSBlock → LayerNorm → SS2D → DropPath
                                                              ↓ + residual
                                                        LayerNorm → RGBlock(FFN) → DropPath → + residual
```

**SS2D 内部结构**：

```
输入 → in_proj(1×1 Conv) → [x, z 分流] 
       x → 3×3 DWConv → SiLU → 4向CrossScan展开 → SelectiveScan(CUDA) → CrossMerge合并
       z → SiLU → 门控乘法
       → out_proj(1×1 Conv) → 输出
```

**Selective Scan** 通过 CUDA C++ 扩展实现（`selective_scan/` 目录），包含 4 个编译好的 `.so` 库：
- `selective_scan_cuda_core` — 基础实现
- `selective_scan_cuda_oflex` — 灵活内存布局
- `selective_scan_cuda_ndstate` — 多维状态
- `selective_scan_cuda_nrow` — 按行分块

### 模型结构

三种尺度共享相同架构（仅 depth/width 不同），采用 YOLO 经典的 Backbone + PAFPN Neck + Detect Head 设计：

```
Backbone:
  SimpleStem (P2/4, 128ch)
  → 3× VSSBlock[128]
  → VisionClueMerge → P3/8, 256ch
  → 3× VSSBlock[256]
  → VisionClueMerge → P4/16, 512ch
  → 9× VSSBlock[512]
  → VisionClueMerge → P5/32, 1024ch
  → 3× VSSBlock[1024]
  → SPPF

Neck (PAFPN，全由 XSSBlock 构成):
  P5 → Upsample → Concat(P4) → 3× XSSBlock[512]
  → Upsample → Concat(P3) → 3× XSSBlock[256]       # P3/8-small
  → Conv↓ → Concat → 3× XSSBlock[512]              # P4/16-medium
  → Conv↓ → Concat(P5) → 3× XSSBlock[1024]         # P5/32-large

Head: Detect(P3, P4, P5)
```

### 模型规格

| 模型 | depth_mult | width_mult | max_channels | 参数量 | FLOPs | 默认Batch | COCO AP |
|------|-----------|------------|-------------|--------|-------|-----------|---------|
| T (Tiny) | 0.33 | 0.25 | 1024 | 5.8M | 13.2G | 4 | 44.5 |
| B (Base) | 0.33 | 0.50 | 1024 | 21.8M | 49.7G | 2 | 49.1 |
| L (Large) | 0.67 | 0.75 | 768 | 57.6M | 156.2G | 1 | 52.1 |

---

## 项目文件结构

```
mamba-yolo/
├── mbyolo_train.py                  # ★ 训练/验证/测试 入口脚本
├── run_all_models.sh                # 批量训练 T/B/L 三个模型的脚本
├── yolov8n.pt                       # YOLOv8n 预训练权重
├── pyproject.toml                   # 项目元数据和依赖
├── README.md                        # 本文件
├── USE.md                           # 详细使用指南
│
├── venv/                            # Python 虚拟环境（已装好所有依赖）
│
├── datasets/                        # 数据集存放
│   ├── VisDrone2019/                # VisDrone-DET 数据集
│   │   ├── images/train/            #   6471 张训练图
│   │   ├── images/val/              #   548 张验证图
│   │   ├── images/test/             #   1610 张测试图
│   │   └── labels/{train,val,test}/ #   YOLO 格式标注
│   └── coco8/                       # COCO 8张小样本（调试用）
│
├── ultralytics/                     # Ultralytics 框架（含 Mamba 修改）
│   ├── cfg/
│   │   ├── default.yaml             # ★ 全局超参数配置
│   │   ├── datasets/                # 数据集配置
│   │   │   ├── VisDrone.yaml        #   VisDrone-DET 路径和10类定义
│   │   │   └── VisDrone-VID.yaml    #   VisDrone-VID（视频目标检测）
│   │   └── models/mamba-yolo/
│   │       ├── Mamba-YOLO-T.yaml    #   Tiny 模型结构定义
│   │       ├── Mamba-YOLO-B.yaml    #   Base 模型结构定义
│   │       └── Mamba-YOLO-L.yaml    #   Large 模型结构定义
│   ├── nn/modules/
│   │   ├── mamba_yolo.py            # ★★ SS2D/VSSBlock/XSSBlock 等核心模块
│   │   └── common_utils_mbyolo.py   # ★★ CrossScan/SelectiveScan 等底层算子
│   ├── engine/
│   │   ├── model.py                 #   模型基类（train/val/predict/export）
│   │   ├── trainer.py               #   训练循环引擎
│   │   └── validator.py             #   验证基类
│   ├── models/yolo/
│   │   ├── model.py                 #   YOLO 封装类（task_map映射）
│   │   └── detect/
│   │       ├── train.py             #   检测任务训练器
│   │       └── val.py               #   检测任务验证器（含 COCO AP 指标）
│   └── utils/
│       └── metrics.py               #   AP/Precision/Recall 指标计算
│
├── selective_scan/                  # CUDA C++ Selective Scan 扩展
│   ├── setup.py                     #   编译脚本
│   ├── csrc/                        #   CUDA 源码
│   └── build/                       #   编译好的 .so 文件
│
├── output_dir/VisDrone/             # 训练输出
│   └── mambayolo_T/                 # Tiny 模型的训练结果
│       ├── weights/                 #   模型权重
│       ├── args.yaml                #   训练参数记录
│       ├── results.csv              #   训练日志
│       ├── labels.jpg               #   标注可视化
│       └── train_batch*.jpg         #   训练批次预览
│
└── tests/                           # 单元测试
```

---

## 环境准备

### 1. 环境要求

- Python 3.11+
- PyTorch 2.3.0 + CUDA 12.1
- RTX 3070 8GB 或更高显存 GPU

### 2. 激活虚拟环境

```bash
source venv/bin/activate
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd /home/xrb/桌面/mamba-yolo
```

---

## 快速开始

### 训练

```bash
# Tiny 模型训练（推荐首选）
python mbyolo_train.py --model T --task train --epochs 100

# Base 模型训练
python mbyolo_train.py --model B --task train --epochs 200

# Large 模型训练（追求最高精度）
python mbyolo_train.py --model L --task train --epochs 300 --batch_size 1
```

### 验证（计算完整 COCO AP 指标）

```bash
# 验证已训练的 Tiny 模型
python mbyolo_train.py --model T --task val

# 指定权重文件验证
python mbyolo_train.py --model B --task val \
    --weights output_dir/VisDrone/mambayolo_b/weights/best.pt
```

验证时自动输出 **COCO 官方全套 AP 指标**：

| 指标 | 含义 |
|------|------|
| AP (AP@0.5:0.95) | IoU 0.5~0.95 十个阈值的均值（COCO 主要指标） |
| AP@0.5 (AP50) | IoU=0.5 时各类别平均精度 |
| AP@0.75 (AP75) | IoU=0.75 时各类别平均精度（严格匹配） |
| AP_small (APs) | 小目标精度（面积 < 32² 像素） |
| AP_medium (APm) | 中目标精度（32² < 面积 < 96²） |
| AP_large (APl) | 大目标精度（面积 > 96²） |

### 测试

```bash
# 在测试集上评估（1610张，不参与训练）
python mbyolo_train.py --model T --task test
```

---

## 超参数配置

### 参数分层

项目有三层配置，优先级从高到低：

```
命令行参数  >  mbyolo_train.py 默认值  >  default.yaml 全局配置
```

### 命令行传参（训练类核心参数）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--model` | T | 模型大小: T / B / L |
| `--task` | train | train / val / test |
| `--epochs` | 300 | 训练轮数 |
| `--batch_size` | T=4, B=2, L=1 | 批大小（按模型自动设定） |
| `--imgsz` | 640 | 输入图像尺寸 |
| `--lr` | 0.01 | 初始学习率 |
| `--optimizer` | SGD | SGD / Adam / AdamW |
| `--device` | 0 | GPU 编号 |
| `--workers` | 8 | 数据加载线程数 |
| `--patience` | 50 | 早停耐心值 |
| `--seed` | 42 | 随机种子 |
| `--cos_lr` | True | 余弦学习率衰减 |
| `--close_mosaic` | 10 | 最后N轮关闭 mosaic 增强 |
| `--amp` | True | 自动混合精度 |
| `--project` | output_dir/VisDrone | 输出根目录 |
| `--name` | 自动生成 | 实验名称 |
| `--weights` | None | 预训练权重路径 |
| `--resume` | False | 断点续训 |

### default.yaml 配置（增强+优化器+损失权重）

直接编辑 `ultralytics/cfg/default.yaml`，以下参数会被命令行读取并生效：

```yaml
# 优化器参数
lr0: 0.01            # 初始学习率
lrf: 0.01            # 终学习率倍率 (final_lr = lr0 × lrf)
momentum: 0.937      # SGD 动量
weight_decay: 0.0005 # 权重衰减
warmup_epochs: 3.0   # 预热轮数
warmup_momentum: 0.8 # 预热初始动量
warmup_bias_lr: 0.1  # 预热偏置学习率

# 损失权重
box: 7.5             # 边界框损失权重
cls: 0.5             # 分类损失权重
dfl: 1.5             # DFL 分布焦点损失权重

# 数据增强
mosaic: 1.0          # Mosaic 增强概率（0 为关闭）
mixup: 0.0           # MixUp 增强概率
fliplr: 0.5          # 水平翻转概率
hsv_h: 0.015         # 色调变化范围
hsv_s: 0.7           # 饱和度变化范围
hsv_v: 0.4           # 明度变化范围
scale: 0.5           # 缩放比例
degrees: 0.0         # 旋转角度
translate: 0.1       # 平移比例
shear: 0.0           # 错切角度

# 其他
nbs: 64              # 名义 batch size（用于自动缩放 lr）
label_smoothing: 0.0 # 标签平滑
```

---

## 常用工作流

```bash
# 1. 快速验证想法
python mbyolo_train.py --model T --task train --epochs 50 --name quick_exp

# 2. 正式训练 Base 模型
python mbyolo_train.py --model B --task train --epochs 200 --name final_base

# 3. 换优化器+调学习率
python mbyolo_train.py --model B --task train --epochs 200 \
    --lr 0.001 --optimizer AdamW --name exp_adamw

# 4. 评估模型（自动输出完整 COCO AP）
python mbyolo_train.py --model B --task val --name final_base

# 5. 测试集评估
python mbyolo_train.py --model B --task test --name final_base

# 6. 小尺寸省显存训练
python mbyolo_train.py --model L --task train --epochs 100 --imgsz 512 --batch_size 1

# 7. 断点续训
python mbyolo_train.py --model T --task train --resume
```

---

## 显存参考

RTX 3070 8GB 实测（640×640 输入，AMP 开启）：

| 模型 | Batch | 显存占用 |
|------|-------|----------|
| T | 4 | ~3.5GB |
| T | 2 | ~2.8GB |
| B | 2 | ~3.8GB |
| B | 1 | ~2.5GB |
| L | 1 | ~3.8GB |

显存不够时优先减小 `--batch_size`，其次减小 `--imgsz`。

---

## 数据集格式

YOLO 标注格式（每张图片对应一个同名 `.txt`）：

```
<class_id> <x_center> <y_center> <width> <height>
```

所有坐标归一化到 [0, 1]。目录结构：

```
datasets/<数据集名>/
├── images/
│   ├── train/        # 训练图片
│   ├── val/          # 验证图片
│   └── test/         # 测试图片
├── labels/
│   ├── train/        # YOLO 标注
│   ├── val/
│   └── test/
└── dataset.yaml      # 数据集描述（见 ultralytics/cfg/datasets/）
```

---

## 与原始 YOLOv8 的区别

| 组件 | YOLOv8 原始 | Mamba-YOLO |
|------|------------|------------|
| Backbone Block | C2f（Bottleneck + CrossStage） | **VSSBlock**（SS2D + LSBlock + FFN） |
| Neck Block | C2f | **XSSBlock**（SS2D + LSBlock + FFN） |
| Stem | Conv + C2f | **SimpleStem**（双 3×3 Conv） |
| 下采样 | Conv(stride=2) | **VisionClueMerge**（空间展开 + 1×1 Conv） |
| Detection Head | Detect（不变） | Detect（不变） |
| 长距离依赖 | 仅靠 FPN 多尺度融合 | SS2D 4向扫描捕捉全局依赖 |

核心差异：用 State Space Model 替换了所有 Bottleneck 结构，保持了 YOLO 的检测头和训练范式不变。

---

## 依赖项

核心依赖（已装在 venv 中）：

- PyTorch 2.3.0 + CUDA 12.1
- timm（DropPath）
- einops（tensor 重排）
- pycocotools（COCO AP 指标计算）
- seaborn, thop（可视化和 FLOPs 计算）

---

## 引用

```bibtex
@misc{wang2024mambayolossmsbasedyolo,
      title={Mamba YOLO: SSMs-Based YOLO For Object Detection},
      author={Zeyu Wang and Chen Li and Huiying Xu and Xinzhong Zhu},
      year={2024},
      eprint={2406.05835},
      archivePrefix={arXiv},
      primaryClass={cs.CV},
      url={https://arxiv.org/abs/2406.05835},
}
```

## 致谢

本项目基于 [Ultralytics](https://github.com/ultralytics/ultralytics) 和 [VMamba](https://github.com/MzeroMiko/VMamba) 的 Selective Scan 实现。
