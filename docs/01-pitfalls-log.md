# 把 VINS-Fusion 移植到 ROS2 Jazzy：我踩过的坑（施工日志，持续更新）

> 背景：VINS-Fusion 官方只支持 ROS1。GitHub 上现存的 ROS2 移植基本停在 Humble，
> 而没有人提供 Jazzy（2024 年起的 LTS，支持到 2029）版本。本系列记录我从零
> 完成 Jazzy 移植 + EuRoC 基准测试的全过程。所有实验均为本人用开源代码、
> 公开数据集在个人设备上独立复现。
>
> 本篇是施工日志：按时间顺序记录每一个真实报错与修复。最终会拆成独立成文。

## 环境

- 宿主机：Ubuntu 22.04 / 8C8G / 无独立显卡
- 目标：ROS2 Jazzy（Docker 容器内）+ VINS-Fusion（CPU 模式）
- 起点：以 zinuok 的 Humble 移植为基线（git 可 diff）

## 坑 #1：Ubuntu 22.04 装不了 Jazzy

**现象**：Jazzy 官方只支持 Ubuntu 24.04（Noble），22.04（Jammy）只能装 Humble。

**解法**：不升级系统，Docker 容器内跑 Jazzy。副产品：仓库天然获得
"一条命令复现"的能力，README 卖点 +1。

**教训**：想跑新 LTS，先查兼容矩阵再动手，别在系统升级上浪费时间。

## 坑 #2：Docker Hub 拉不动（国内网络）

**现象**：`docker pull ros:jazzy` 超时，
`dial tcp 128.242.240.20:443: i/o timeout`。

**解法**：换镜像仓库拉取后打 tag：
```bash
docker pull docker.m.daocloud.io/library/ros:jazzy
docker tag docker.m.daocloud.io/library/ros:jazzy ros:jazzy
```
实测 docker.1ms.run、dockerproxy.net 也可用（2026-10，镜像域名时效性强）。

## 坑 #3：apt 换源踩到的 403

**现象**：`cn.archive.ubuntu.com` 和 `mirrors.tuna.tsinghua.edu.cn`
同时返回 403，且解析到**同一个 IP**——`cn.archive` 本来就是清华镜像的别名。

**解法**：先 `curl -sI` 测一圈候选镜像（aliyun/ustc/官方源），挑通的换：
```bash
sudo sed -i.bak 's|http://cn.archive.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list
```
**教训**：apt 报 403 不是 apt 的错，先用 curl 二分定位网络层，再动配置。

## 坑 #4：Ceres 2.1.0 在 Ubuntu 24.04 上 CMake 直接失败（本篇最干的坑）

**现象**：编译 Ceres 2.1.0 时：
```
CMake Error at internal/ceres/CMakeLists.txt:329 (target_link_libraries):
  Target "ceres" links to: CXSparse::CXSparse
  but the target was not found.  ... An ALIAS target is missing.
```

**根因**：noble 的 SuiteSparse/CMake 打包方式变了，Ceres 2.1.0 自带的
`FindCXSparse.cmake` 找不到新的 imported target。这是 Ceres 2.2.0 修复的
打包兼容问题之一。

**为什么不用 Ceres 2.2 一了百了**：VINS-Fusion 和 camera_models(camodocal)
大量使用 `ceres::LocalParameterization`——2.1 里已标记 deprecated，
**2.2 里被移除**（替代品是 `Manifold`）。升 Ceres = 手改全部因子类，
工作量完全不是一个量级。

**解法**：VINS 根本不用 CXSparse，直接关掉：
```bash
cmake .. -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DCXSPARSE=OFF
```
编译通过。

**教训**：报错指向的库（CXSparse）不一定是你在乎的库，先问"这个依赖
谁在用、能不能关"，再问"怎么修"。以及：依赖版本组合是移植项目的
第一座大山，值得单独一篇。

## 坑 #5：ros:jazzy 基础镜像没有 OpenCV 开发包

**现象**：colcon 报 `Could NOT find OpenCV (missing: OpenCVConfig.cmake)`。

**解法**：ros 基础镜像只带运行库不带开发头文件，Dockerfile 里补：
```dockerfile
RUN apt-get install -y libopencv-dev libboost-filesystem-dev \
    libboost-program-options-dev libboost-system-dev
```
（camera_models 还需要 Boost 的 filesystem/program_options。）

## 坑 #6：容器里 pip 装 evo 被 PEP 668 拦截

**现象**：`pip3 install evo` 报
"error: externally-managed-environment"（Python 3.12 / noble 的保护机制）。

**解法**：`pip3 install --break-system-packages evo`。
容器环境里这个 flag 是安全的（镜像本来就是一次性的），但要注意
`|| pip3 install evo` 这种"降级重试"写法在这里是反模式：
第一个命令失败后降级命令会撞上同一个 PEP 668 错误，报错信息
反而把人引向错误方向。

## 坑 #7：ETH 官方服务器从国内基本不可达（EuRoC 下载）

**现象**：`robotics.ethz.ch` 的 MH_01_easy.bag，wget 挂 40 分钟 0 字节，
https 同样超时。

**解法**：HuggingFace 上有人托管了 EuRoC，走 hf-mirror 国内直连
（实测 ~10MB/s，4 分钟下完 2.55GB）：
```bash
wget -c "https://hf-mirror.com/datasets/kavehsgh/EuRoC_MAV_Dataset_Machine_Hall_Easy_01/resolve/main/MH_01_easy.bag"
```
下载前先核对文件完整性（`ros2 bag info` 或对比官方 size/md5）。

## 坑 #8：两个"运维自己坑自己"（非技术坑）

1. `pkill -f "docker build"` 会连**自己的构建脚本**一起杀——因为脚本
   命令行里就包含这个关键词。用更精确的匹配或 PID 文件。
2. `docker build -q` 静默模式下，一个 10 分钟的构建看起来像死机。
   长构建永远保留全量日志输出。

## 待续

- [ ] colcon 全量编译的 Jazzy API 报错清单（cv_bridge / message_filters / tf2 …）
- [ ] EuRoC 基准：evo ATE 评测 vs ROS1 原版对照
- [ ] 每个坑拆独立成文的终稿

- [x] colcon 全量编译的 Jazzy API 报错清单 → 已开始：第一个真差异是 cv_bridge.h → cv_bridge.hpp（Jazzy 移除 .h 兼容头），见 v0.1 修复记录
- [x] EuRoC 基准 → **MH_01_easy：ATE RMSE 0.118 m**（Sim(3) 对齐，evo_ape，492 位姿帧实时跑完），与 VINS-Fusion ROS1 原版同数量级，数字见 README 基准表

## 坑 #9：8GB 内存编译 VINS 会被 OOM 杀（cc1plus: Killed）

**现象**：colcon 编译 loop_fusion 时报 `c++: fatal error: Killed signal
terminated program cc1plus`——没有任何 error 行，只有 Killed。

**根因**：DBoW2 词袋模板代码 + Release -O3，单个翻译单元峰值内存
轻松超过 2GB；colcon 默认按核数并行（8 核），8GB 内存直接爆。

**解法**：`MAKEFLAGS=-j2 colcon build --parallel-workers 1`。
**教训**：`Killed` 就是 OOM 的签名；低配机器编译 SLAM 项目先限并行度，
别去找"代码 bug"。

## 坑 #10：ament symlink install 报 ../config 不存在

**现象**：`ament_cmake_symlink_install_directory() can't find
'/ws/src/src/vins/../config/'`。

**根因**：CMakeLists 用 `install(DIRECTORY ../config/)` 引用**包外**目录
（zinuok 原仓库 layout 是 workspace 根下 config/）。目录结构一变，
相对路径就断。

**解法**：照原 layout 把 config/ 放回包的兄弟目录。
**教训**：CMake 里引用包外路径是移植时的隐形地雷，`git grep "\.\./"`
应是移植 checklist 的固定动作。

## 坑 #11：ament symlink install 的镜像陷阱——只挂 install/ 是不够的

**现象**：把 build/install 目录挂进运行容器后 `ros2 launch vins euroc.launch.py`
无报错，但 estimator 根本没启动，输出文件是旧数据。反复排查 launch 文件、
bag 时间戳，全部正常。

**根因**：colcon 默认 `--symlink-install` 生成的
`install/vins/lib/vins/vins_node` 是一个**指向 `/ws/build/...` 的符号链接**。
运行容器只挂载了 `install/` 而没挂 `build/`，可执行文件自然不存在——
而 launch 文件对"进程没起来"是静默的，日志里什么都不报。

**解法**：挂载成对出现：`-v repo/build:/ws/build -v repo/install:/ws/install`。
排查命令就一条：`ls -la install/vins/lib/vins/` 看链接指向。

**教训**：symlink install 把"构建产物"和"安装产物"焊死在一起，**容器
挂载、打包发布、跨机拷贝时任何一个单独拿出来都是坏的**。做"一键复现"
镜像时要么两边都带，要么构建时不用 symlink install。

## 坑 #12：宿主机 pip --user 装 evo：numpy/scipy 二进制不兼容

**现象**：`evo_ape` 报 `ValueError: numpy.dtype size changed, may indicate
binary incompatibility. Expected 96 from C header, got 88`。

**根因**：Ubuntu 22.04 的系统 scipy 是针对 numpy 1.x 编译的；`pip install
--user evo` 拉进了 numpy 2.x。`~/.local` 的 numpy 优先级高于系统包，
但系统的 scipy 还是老的二进制——混搭爆炸。

**解法**：`pip3 install --user --upgrade scipy`（1.15+ 的 wheel 同时兼容
numpy 2.x）。

**教训**：`pip --user` 会静默制造"pip 版本 + apt 版本"的混搭环境。
报错里的 `dtype size changed` 就是这个组合的签名。

## 坑 #13：VINS 上游输出的轨迹根本没法直接评测

两个叠加问题，都出在 VINS-Fusion 原版的 `vio.csv` 写出代码上：

1. **`foutC.precision(0)`**：时间戳被截成**整数秒**（如 `1403636584`），
   evo 按 `--t_max_diff 0.02` 对齐时全部匹配失败。
2. **`~` 展开与静默失败**：C++ 的 `ofstream` 不展开 `~`，目录不存在时
   **不报任何错**，只是不写文件——你以为是算法没跑完，其实是路径问题。

**解法**：改写输出为标准 TUM 格式（`t tx ty tz qx qy qz qw`，时间戳微秒
精度），并在读配置处加"展开 `~` + `mkdir -p`"兜底。

**教训**：评测链路的最后一步往往不在算法里，而在这些 20 行的 IO 代码里。
移植/复现工作要默认"上游的输出格式不可信"，先看一眼再跑评测。

## 附：rosbag1 → rosbag2 转换（Jazzy 读不了 .bag）

Jazzy 移除了 rosbag1 支持，EuRoC 的 `.bag` 必须先转 rosbag2 格式。
用 python 的 `rosbags` 包一行搞定，无需装 ROS1：

```bash
pip3 install rosbags
rosbags-convert MH_01_easy.bag --dst MH_01_easy_ros2
```

转换后 `ros2 bag info` 核对消息数与原 bag 一致再跑。
