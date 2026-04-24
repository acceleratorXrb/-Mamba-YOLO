# Mamba-YOLO 使用指南

## 环境准备

```bash
# 激活虚拟环境（必须）
source venv/bin/activate

# 设置显存优化（必须，防止碎片化导致 OOM）
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# 进入项目目录
cd /home/xrb/桌面/mamba-yolo
```

## 项目结构速览

```
mamba-yolo/
├── mbyolo_train.py              # ★ 训练/验证/测试 入口脚本
├── venv/                        # Python 虚拟环境（已装好所有依赖）
├── datasets/                    # 数据集存放
│   └── VisDrone2019/            # VisDrone-DET（已下载，已转 YOLO 格式）
│       ├── images/train/        # 6471 张训练图
│       ├── images/val/          # 548 张验证图
│       ├── images/test/         # 1610 张测试图
│       └── labels/{train,val,test}/  # YOLO 标注
├── ultralytics/
│   └── cfg/
│       ├── datasets/VisDrone.yaml          # 数据集路径配置
│       ├── default.yaml                    # ★ 全局超参数（学习率/增强/损失权重等）
│       └── models/mamba-yolo/
│           ├── Mamba-YOLO-T.yaml           # Tiny 模型结构（5.8M 参数）
│           ├── Mamba-YOLO-B.yaml           # Base 模型结构（21.8M 参数）
│           └── Mamba-YOLO-L.yaml           # Large 模型结构（57.6M 参数）
└── output_dir/VisDrone/        # 训练输出
    ├── mambayolo_t/             # Tiny 的训练结果
    ├── mambayolo_b/             # Base 的训练结果
    └── mambayolo_l/             # Large 的训练结果
```

## 三款模型对比

| 模型 | 参数量 | 计算量 | 显存占用 | 默认 Batch | 适用场景 |
|------|--------|--------|----------|------------|----------|
| **T** (Tiny) | 5.8M | 13.2G | ~3.5GB | 4 | 快速实验、显存紧张 |
| **B** (Base) | 21.8M | 49.7G | ~3.8GB | 2 | 精度/速度平衡 |
| **L** (Large) | 57.6M | 156.2G | ~3.8GB | 1 | 最高精度 |

## 训练命令

### 基本训练（自动使用默认超参数）

```bash
# Tiny 模型训练 100 轮（推荐先用这个试）
python mbyolo_train.py --model T --task train --epochs 100

# Base 模型训练
python mbyolo_train.py --model B --task train --epochs 100

# Large 模型训练
python mbyolo_train.py --model L --task train --epochs 100
```

### 常用参数组合

```bash
# 指定 batch size（不指定则用上表默认值）
python mbyolo_train.py --model T --task train --epochs 100 --batch_size 2

# 指定学习率
python mbyolo_train.py --model T --task train --epochs 100 --lr 0.001

# 换优化器 (SGD/Adam/AdamW)
python mbyolo_train.py --model B --task train --epochs 100 --optimizer AdamW --lr 0.001

# 较小输入尺寸（省显存、加速）
python mbyolo_train.py --model L --task train --epochs 100 --imgsz 512

# 指定数据加载线程数
python mbyolo_train.py --model T --task train --epochs 100 --workers 4

# 指定输出名称（方便区分实验）
python mbyolo_train.py --model T --task train --epochs 100 --name exp_001
```

### 完整参数列表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--model` | T | 模型大小: T / B / L |
| `--task` | train | train / val / test |
| `--data` | VisDrone.yaml | 数据集配置路径 |
| `--epochs` | 300 | 训练轮数 |
| `--batch_size` | 按模型自动 | 批大小（默认 T=4, B=2, L=1） |
| `--imgsz` | 640 | 输入图像尺寸 |
| `--device` | 0 | GPU 编号，多卡用 `0,1` |
| `--workers` | 8 | 数据加载线程数 |
| `--optimizer` | SGD | SGD / Adam / AdamW |
| `--lr` | 0.01 | 初始学习率 |
| `--amp` | True | 混合精度（省显存） |
| `--cos_lr` | True | 余弦学习率衰减 |
| `--patience` | 50 | 早停耐心值（50轮不涨就停） |
| `--seed` | 42 | 随机种子 |
| `--close_mosaic` | 10 | 最后N轮关闭 mosaic 增强 |
| `--project` | output_dir/VisDrone | 输出根目录 |
| `--name` | 自动生成 | 实验名称 |
| `--weights` | None | 预训练权重路径 |
| `--resume` | False | 断点续训 |

## 超参数调整

### 方式一：命令行传参（改学习率/优化器等常用项）

```bash
python mbyolo_train.py --model T --task train --epochs 100 --lr 0.005 --optimizer AdamW
```

### 方式二：修改默认超参数文件（推荐，所有参数都能改）

**文件位置**：`ultralytics/cfg/default.yaml`（第 89-120 行）

```yaml
# 关键超参数说明：
lr0: 0.01            # 初始学习率
lrf: 0.01            # 最终学习率倍率（final_lr = lr0 * lrf = 0.0001）
momentum: 0.937       # SGD 动量
weight_decay: 0.0005  # 权重衰减
warmup_epochs: 3.0    # 预热轮数
box: 7.5              # 边界框损失权重
cls: 0.5              # 分类损失权重
dfl: 1.5              # DFL 损失权重

# 数据增强参数：
mosaic: 1.0           # Mosaic 增强概率（1.0=始终开启）
mixup: 0.0            # MixUp 增强概率（VisDrone 默认关闭）
degrees: 0.0          # 旋转角度
fliplr: 0.5           # 水平翻转概率
hsv_h: 0.015          # 色调变化
hsv_s: 0.7            # 饱和度变化
hsv_v: 0.4            # 明度变化
scale: 0.5            # 缩放比例范围
```

例如调大学习率、减少预热、关闭 mosaic：
```yaml
lr0: 0.02
warmup_epochs: 1.0
mosaic: 0.0
```

### 方式三：修改模型结构配置

**文件位置**：`ultralytics/cfg/models/mamba-yolo/Mamba-YOLO-{T,B,L}.yaml`

- `scales` 行：`[depth_multiplier, width_multiplier, max_channels]`
- 不推荐直接改，除非你想自定义模型大小

## 验证和测试

### 验证（计算 mAP）

```bash
# 验证 Tiny 模型（自动启用 COCO 完整 AP 指标评估）
python mbyolo_train.py --model T --task val

# 指定权重文件
python mbyolo_train.py --model L --task val \
    --weights output_dir/VisDrone/mambayolo_l/weights/best.pt
```

### COCO 风格完整 AP 指标

独立验证时（`--task val` 非训练期），系统**自动**生成 COCO 格式标注并调用 pycocotools 计算 
**COCO 官方全套 AP 指标**：

| 指标 | 含义 |
|------|------|
| **AP (AP@0.5:0.95)** | IoU 0.5~0.95 十个阈值下各类别平均精度的均值（COCO 主要指标）|
| **AP@0.5 (AP50)** | IoU=0.5 时各类别平均精度（宽松匹配） |
| **AP@0.75 (AP75)** | IoU=0.75 时各类别平均精度（严格匹配） |
| **AP_small (APs)** | 小目标精度（面积 < 32² 像素） |
| **AP_medium (APm)** | 中目标精度（32² < 面积 < 96²） |
| **AP_large (APl)** | 大目标精度（面积 > 96²） |

> **AP vs mAP**: COCO 官方用 AP（Average Precision），YOLO 代码里内部用 mAP（mean Average Precision）。
> 两者本质相同——COCO 的 AP 已经是对所有类别取过均值的，所以不需要再加 "m"。但 Ultralytics 代码里
> key 名沿用了 `mAP50`, `mAP50-95` 等命名习惯，与 `AP@0.5`, `AP@0.5:0.95` 是一一对应的。

验证过程输出两轮结果：
1. **YOLO 内置指标表** — 显示 P, R, mAP50, mAP50-95, mAP75, mAPs, mAPm, mAPl
2. **pycocotools 官方评表格** — 显示 AP, AP50, AP75, APs, APm, APl, AR 等

### 测试

```bash
python mbyolo_train.py --model T --task test
```

验证/测试结果保存在 `output_dir/VisDrone/<name>/` 下，包括：
- 各种 mAP@50、mAP@50-95、mAP@75、mAPs、mAPm、mAPl 指标
- `annotations.json` — 从 YOLO 标注生成的 COCO 格式真值
- `predictions.json` — 模型预测结果的 COCO 格式
- 混淆矩阵
- P-R 曲线
- F1-置信度曲线

## 断点续训

```bash
# 如果训练中断，从上次保存的 checkpoint 继续
python mbyolo_train.py --model T --task train --resume
```

## 常用工作流示例

```bash
# 1. 小实验：Tiny 50轮快速验证想法
python mbyolo_train.py --model T --task train --epochs 50 --name quick_test

# 2. 正式训练：Base 200轮
python mbyolo_train.py --model B --task train --epochs 200 --name final_base

# 3. 评估结果（自动输出完整 COCO AP 指标）
python mbyolo_train.py --model B --task val --name final_base

# 4. 换超参对比实验
python mbyolo_train.py --model B --task train --epochs 200 \
    --lr 0.005 --optimizer AdamW --name exp_adamw

# 5. Large 模型小尺寸训练（省显存）
python mbyolo_train.py --model L --task train --epochs 100 --imgsz 512
```

## 显存与 Batch Size 关系

RTX 3070 8GB 实测（640x640 输入）：

| 模型 | Batch | 显存 |
|------|-------|------|
| T | 4 | ~3.5G |
| T | 2 | ~2.8G |
| B | 2 | ~3.8G |
| B | 1 | ~2.5G |
| L | 1 | ~3.8G |

如果显存不够，优先减小 `--batch_size`，其次减小 `--imgsz`。

## 数据集目录要求

YOLO 格式的标准结构（本项目已配置好）：

```
datasets/<数据集名>/
├── images/
│   ├── train/    # 训练图片
│   ├── val/      # 验证图片
│   └── test/     # 测试图片
├── labels/
│   ├── train/    # 标注（每张图一个同名 .txt）
│   ├── val/
│   └── test/
└── dataset.yaml  # 数据集描述（见 ultralytics/cfg/datasets/）
```

标注文件格式（每行一个目标）：
```
<class_id> <x_center> <y_center> <width> <height>
```
所有坐标归一化到 [0, 1]。
