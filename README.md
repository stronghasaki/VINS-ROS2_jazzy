# VINS-Fusion on ROS2 Jazzy

VINS-Fusion 的 ROS2 **Jazzy** 移植 + EuRoC 基准测试，附带可复现的 Docker 环境。

> 为什么做这个：VINS-Fusion 官方只支持 ROS1；GitHub 上现存的 ROS2 移植
> 基本停在 Humble（支持到 2027-04）。Jazzy 是当前的 LTS（支持到 2029-05），
> 但没有人提供移植 + 基准数字。本仓库补上这一块。

## 与其他移植的差异

| | 官方 ROS1 | Humble 移植们 | 本仓库 |
|---|---|---|---|
| ROS2 Jazzy | ✗ | ✗ | ✓ |
| EuRoC 基准数字 | 有(ROS1) | 多数没有 | ✓ ATE RMSE 0.118 m |
| 一键 Docker 复现 | ✗ | 少数 | ✓ |
| evo 评测脚本 | ✗ | ✗ | ✓ |

## 基准结果（MH_01_easy, stereo+IMU）

| 指标 | 数值 |
|---|---|
| ATE RMSE (Sim(3) aligned) | **0.118 m** |
| ATE mean / max | 0.101 m / 0.322 m |
| 关键帧位姿输出 | 492 帧, 实时 (solver ~45 ms/frame) |

评测方式：`evo_ape`（TUM 格式，`--align --correct_scale`，`t_max_diff 0.02`），
EuRoC state_groundtruth_estimate0 为真值。轨迹样例与 evo 结果文件见
`scripts/`（`mh01_easy_vio.tum` / `mh01_easy_vio.ape.zip`，可 `evo_res` 直接对比）。

## 一键复现（Docker）

宿主机只需 Docker（无需装 ROS）：

```bash
# 1. 构建依赖镜像（Ceres 2.1.0 + OpenCV + Jazzy，一次性）
cd docker
docker build -f Dockerfile.base -t vins-jazzy-base .

# 2. 编译工作区（~10 min, 8GB 内存放缓一点见 FAQ）
docker run --rm -v $PWD/..:/ws -w /ws vins-jazzy-base \
    bash -c "source /opt/ros/jazzy/setup.bash && \
    MAKEFLAGS=-j2 colcon build --symlink-install --parallel-workers 1"

# 3. 下载 EuRoC MH_01_easy.bag 并转 rosbag2（Jazzy 读不了 .bag）
pip3 install rosbags
rosbags-convert MH_01_easy.bag --dst MH_01_easy_ros2

# 4. 跑
docker run --rm --network host \
    -v $PWD/../src:/ws/src -v $PWD/../build:/ws/build -v $PWD/../install:/ws/install \
    -v /path/to/MH_01_easy_ros2:/bags:ro -v $HOME/vins_out:/root \
    vins-jazzy-base bash -c "source /opt/ros/jazzy/setup.bash && \
    source /ws/install/local_setup.bash && \
    (ros2 launch vins euroc.launch.py &) && sleep 8 && \
    ros2 bag play /bags && sleep 30"
# 轨迹输出在 $HOME/vins_out/output/vio.csv (TUM 格式)

# 5. 评测
evo_ape tum groundtruth.tum vio.csv -a -as --t_max_diff 0.02
```

⚠️ **build/ 和 install/ 必须同时挂载**：colcon `--symlink-install` 生成的
`install/*/lib/**` 是指向 build/ 的符号链接（详见 FAQ #4）。

## FAQ：移植/复现路上的坑（每个都有真实报错原文）

1. **Ubuntu 22.04 装不了 Jazzy** → 别升系统，用 Docker。
2. **Ceres 2.1.0 在 noble 上 CMake 失败** (`CXSparse::CXSparse` ALIAS missing)
   → VINS 不用 CXSparse，`-DCXSPARSE=OFF`。不要升 Ceres 2.2：它移除了
   `LocalParameterization`，VINS/camodocal 会全面报错。
3. **ros:jazzy 镜像没有 OpenCV 开发包** → 补 `libopencv-dev` + Boost dev 三件套。
4. **只挂载 install/ 时节点静默不启动** → symlink install 指向 build/，
   两个目录必须成对挂载。
5. **8GB 内存编译 OOM (`cc1plus: Killed`)** → DBoW2 模板 + -O3 单文件峰值 >2GB，
   `MAKEFLAGS=-j2 colcon build --parallel-workers 1`。
6. **Jazzy 的 cv_bridge 4.x 删了 `.h` 兼容头** → `cv_bridge.h` → `cv_bridge.hpp`。
7. **上游 vio.csv 时间戳是整数秒、路径不展开 `~` 且失败不报错**
   → 本仓库已改为 TUM 格式 + 自动展开/建目录。
8. **PEP 668 / numpy-scipy 二进制冲突** 装 evo → 见博客详解。

完整施工日志（含每个报错的原文、根因与教训）：
[docs/01-pitfalls-log.md](docs/01-pitfalls-log.md)

## 仓库结构

```
├── src/
│   ├── camera_models/   # camodocal (Jazzy 适配)
│   ├── config/          # euroc / realsense / KITTI 配置
│   ├── global_fusion/   # GPS 融合
│   ├── loop_fusion/     # 回环 + 位姿图
│   └── vins/            # 核心估计器
├── docker/Dockerfile.base   # 依赖镜像（Ceres 2.1.0 tarball 内置，构建不依赖外网）
├── scripts/eval_euroc.sh    # evo ATE 评测

```

## 致谢与许可

- [VINS-Fusion](https://github.com/HKUST-Aerial-Robotics/VINS-Fusion) (HKUST-Aerial-Robotics, GPLv3)
- ROS2 Humble 移植基线：[zinuok/VINS-Fusion-ROS2](https://github.com/zinuok/VINS-Fusion-ROS2)
- 数据集：[EuRoC MAV](https://projects.asl.ethz.ch/datasets/aerial-machinery-datasets/) (ETH Zurich)

本仓库遵循 GPLv3。移植改动以 git 历史逐条呈现，每条 commit 对应一个坑。
