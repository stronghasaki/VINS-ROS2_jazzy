# 已知坑与解法

环境：宿主机 Ubuntu 22.04 / 8C8G / 无独显；ROS2 Jazzy（仅支持 24.04）跑在 Docker 容器内；VINS 走 CPU 模式；以 [zinuok/VINS-Fusion-ROS2](https://github.com/zinuok/VINS-Fusion-ROS2)（Humble）为底座。

只记录非常识性、有复用价值的问题，格式：现象 → 根因 → 解法 → 原理。按编译期 / 运行期 / 评测期分组。

## 编译期

### 1. Ceres 2.1.0 CMake 报 CXSparse::CXSparse target 不存在

- **现象**：

```
CMake Error at internal/ceres/CMakeLists.txt:329 (target_link_libraries):
  Target "ceres" links to: CXSparse::CXSparse
  but the target was not found.  ... An ALIAS target is missing.
```

- **根因**：noble 的 SuiteSparse/CMake 打包方式变更，Ceres 2.1.0 自带的 `FindCXSparse.cmake` 找不到新的 imported target。该兼容问题在 Ceres 2.2.0 修复。
- **为什么不能升 Ceres 2.2**：VINS-Fusion 与 camera_models（camodocal）大量使用 `ceres::LocalParameterization`，该类 2.1 已 deprecated、2.2 中移除（替代品 `Manifold`）。升级 = 手改全部因子类。
- **解法**：VINS 求解器不使用 CXSparse，直接关闭：

```bash
cmake .. -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DCXSPARSE=OFF
```

- **原理**：报错指向的依赖不等于被使用的依赖，先确认依赖的实际使用方，再决定修复路径。

### 2. 编译 loop_fusion 时 cc1plus 被 Killed

- **现象**：`c++: fatal error: Killed signal terminated program cc1plus`（无任何 error 行，只有 Killed = OOM 签名）。
- **根因**：DBoW2 词袋模板代码 + Release `-O3`，单翻译单元峰值内存超 2GB；colcon 默认按核数开 8 路并行，8G 内存爆掉。
- **解法**：

```bash
MAKEFLAGS=-j2 colcon build --parallel-workers 1
```

- **原理**：模板实例数 × 优化开销是乘法关系，并行度决定峰值内存，低配机器先限并行度。

### 3. ros:jazzy 基础镜像缺 OpenCV 开发包

- **现象**：colcon 报 `Could NOT find OpenCV (missing: OpenCVConfig.cmake)`。
- **根因**：ros 基础镜像只含运行库，不含开发头文件（`OpenCVConfig.cmake` 在 dev 包里）。
- **解法**：Dockerfile 补装（Boost 三件套为 camera_models 所需）：

```dockerfile
RUN apt-get install -y libopencv-dev libboost-filesystem-dev \
    libboost-program-options-dev libboost-system-dev
```

### 4. cv_bridge 头文件：Jazzy 移除 `.h` 兼容头

- **现象**：colcon 编译报找不到 `cv_bridge.h`。
- **根因**：Jazzy 的 cv_bridge 4.x 移除了 `.h` 兼容头，统一为 `cv_bridge.hpp`。
- **解法**：全部 `#include <cv_bridge/cv_bridge.h>` 改为 `cv_bridge.hpp`。

### 5. ament symlink install 报 ../config 不存在

- **现象**：`ament_cmake_symlink_install_directory() can't find '/ws/src/src/vins/../config/'`。
- **根因**：CMakeLists 用 `install(DIRECTORY ../config/)` 引用包外目录（底座原仓库 layout 为 workspace 根下 config/），目录结构变化后相对路径断裂。
- **解法**：照原 layout 将 config/ 放回包的兄弟目录。
- **原理**：CMake 引用包外路径时编译期不校验、install 期才解析，报错点远离出错点。移植他人仓库先执行 `git grep "\.\./"` 排查此类引用。

## 运行期

### 6. 只挂载 install/ 时 launch 无报错但 estimator 不启动

- **现象**：`ros2 launch vins euroc.launch.py` 无报错，输出文件是上一次的旧数据。
- **根因**：colcon `--symlink-install` 生成的 `install/vins/lib/vins/vins_node` 是指向 `/ws/build/...` 的符号链接；容器只挂载 `install/` 时可执行文件不存在，而 launch 文件对"进程未启动"是静默的。
- **解法**：挂载成对出现：`-v repo/build:/ws/build -v repo/install:/ws/install`。排查命令：`ls -la install/vins/lib/vins/` 查看链接指向。
- **补充（构建布局同样被定格）**：share 下的 launch/config 链接指向的是**构建时** src 的容器内路径。构建挂 `-v $PWD/..:/ws`（包在 `/ws/src/vins`）就生成指向 `/ws/src/**` 的链接，运行时把 src 挂到 `/ws/src/src` 必报 FileNotFoundError——构建与运行的挂载布局必须完全一致。本项目统一 src 挂 `/ws/src/src`（构建、运行都是）。注意不要同时挂 repo 根和 `/ws/src/src`：colcon 会发现重复包直接报错退出。
- **原理**：symlink install 将构建产物与安装产物绑定，容器挂载 / 打包 / 跨机拷贝时任一单独存在都是坏的；符号链接存的是路径字符串，能不能解析只看容器内挂载点——构建时路径即运行时路径。要么布局一致，要么构建时不用 `--symlink-install`。

## 评测期

### 7. VINS 上游 `vio.csv` 无法直接对齐真值

- **现象**：evo 按 `--t_max_diff 0.02` 对齐时全部匹配失败；或输出文件根本没生成。
- **根因**：两个叠加问题，均在原版 `vio.csv` 写出代码：
  1. `foutC.precision(0)` 将时间戳截成整数秒（如 `1403636584`），与真值纳秒/微秒精度无法对齐；
  2. C++ `ofstream` 不展开 `~`，目录不存在时静默失败、不报任何错。
- **解法**：本仓库已改为标准 TUM 格式（`t tx ty tz qx qy qz qw`，微秒精度时间戳），并在读配置处加"展开 `~` + `mkdir -p`"兜底。

### 8. 真值四元数列序：EuRoC 是 wxyz，TUM 是 xyzw，awk 一列之差旋转评测全毁

- **现象**：自写真值转换脚本转出 TUM 后，`evo_ape -va` 报 `invalid (must be unit quaternions)`。平移 ATE"看起来完全正常"，旋转评测（`-r angle_deg`）误差却是 66° 量级，全程无报错。
- **根因**：官方 `state_groundtruth_estimate0/data.csv` 的实际格式是第 1 行 `#` 注释头 + 逗号分隔（CSV），列序 `$1=timestamp, $2..4=px py pz, $5=qw $6=qx $7=qy $8=qz, $9..=vx vy vz`（wxyz）。转换脚本两层错误：(a) 写成 `$6 $7 $8 $9`——把线速度 vx（$9）当 qw 塞进 TUM 第 8 列，正确取法 `$6 $7 $8 $5`；(b) 注释假设"无逗号、3 行注释头"，对官方文件用 awk 默认空白分隔会把整行吞成 $1，字段全空。
- **为什么 evo 不报错、平移 ATE 还是对的**：`evo/tools/file_interface.py` 的 `read_tum_trajectory_file` 读入后只做列 roll（xyzw→wxyz），不归一化也不校验模长（模长校验只在 `check()` 里警告）。平移 APE 和 Umeyama 对齐只用位置坐标，四元数列不进这条路径——A/B 实测两种列序的平移 RMSE 逐位相同（0.1176 m）。四元数只在旋转评测和一切用到真值姿态的场景生效，那里 2.77° 变 66.3°，无任何报错。
- **解法**：v3 脚本（`scripts/eval_euroc.sh`）：`-F','` + 首字段纯数字判数据行 + `$6 $7 $8 $5`，并在转换时加模长自检：数据首行 (qw,qx,qy,qz) 模长偏离 1 直接报错退出。
- **原理**：评测数字被污染的方向取决于该指标用到数据的哪部分。TUM(xyzw) 与 ASL/ROS geometry_msgs(wxyz) 两套约定并行二十年，评测脚本对新格式数据的第一行做断言（模长、时间戳单位、列数）。README 结果已按 v3 脚本用官方真值重测确认。

### 9. evo 安装的环境问题（容器 / 宿主机两种场景）

- **容器内**：`pip3 install evo` 被 PEP 668 拦截（noble / Python 3.12 的 externally-managed-environment）。解法 `pip3 install --break-system-packages --ignore-installed evo`——只加 `--break-system-packages` 还会在收尾时报 `ERROR: Cannot uninstall numpy 1.26.4, RECORD file not found (installed by debian)`（debian 装的 numpy 没有 pip 卸载元数据），`--ignore-installed` 让 pip 不尝试卸载 debian 版直接盖上。一次性镜像内安全。
- **宿主机 `pip --user`**：`evo_ape` 报 `ValueError: numpy.dtype size changed, may indicate binary incompatibility. Expected 96 from C header, got 88`。根因：22.04 系统 scipy 针对 numpy 1.x 编译，`pip --user evo` 拉入 numpy 2.x，`~/.local` 优先级高于系统包但系统 scipy 二进制未变。解法 `pip3 install --user --upgrade scipy`（1.15+ wheel 兼容 numpy 2.x）。
- **宿主机画图**：`evo_res -p` 报 `ImportError: cannot import name 'docstring' from 'matplotlib'`。根因：pip 的 matplotlib 3.10 wheel 不再带 `mpl_toolkits/__init__.py`（命名空间包），而 apt 装的 `/usr/lib/python3/dist-packages/mpl_toolkits` 是有 `__init__.py` 的常规包——Python 的 import 规则是常规包优先于命名空间包，mplot3d 仍解析到系统旧版、和新版 matplotlib 拼不上。给 `~/.local` 的 mpl_toolkits 补空 `__init__.py` 不能解决。
- **无头机器的画图后端**：venv 装好后 `evo_res -p` 报 `Failed to import any of the following Qt binding modules`。evo 的 `~/.evo/settings.json` 里 `plot_backend` 默认 `qtagg`，服务器没 Qt，改成 `agg` 即可。
- **环境隔离**：评测环境要么全在容器里，要么全部 venv（22.04 需先 `apt install python3.10-venv`）。

## 附：数据集下载与 rosbag1 → rosbag2 转换

### 11. EuRoC 官方下载页迁移 + 国内镜像

- **现象**：README 里写的 `projects.asl.ethz.ch/datasets/aerial-machinery-datasets/` 返回 404（ASL 数据集页已改版）。
- **现状**：官方页现为 https://projects.asl.ethz.ch/datasets/euroc-mav/ （2026-10 验证 200）。国内直连 ETH 慢/不稳时，可用 hf-mirror 上的第三方镜像：`https://hf-mirror.com/datasets/GlowBond/EuRoC_MAV_Dataset/resolve/main/machine_hall.zip`（machine_hall.zip 内含各序列的 `.bag` 与 `mav0/` 真值目录；第三方镜像，建议下载后核对文件大小/条数）。
- **原理**：数据集官网搬家不留 301 的不少见；引用外部下载地址的 README，定期 `curl -sI` 抽查一下链接活性。

### rosbag1 → rosbag2 转换

Jazzy 移除了 rosbag1 支持，EuRoC 的 `.bag` 需先转 rosbag2 格式，用 python `rosbags` 包，无需装 ROS1：

```bash
pip3 install -U rosbags
rosbags-convert --src MH_01_easy.bag --dst MH_01_easy_ros2
```

注：0.10.x 时代 `rosbags-convert` 接受位置参数，0.11.x 起必须 `--src`，否则 `error: the following arguments are required: --src`。

转换后 `ros2 bag info` 核对消息数与原 bag 一致再跑。

### 10. rosbags 转出的 bag，Jazzy `ros2 bag play` 直接报 yaml-cpp bad conversion

- **现象**：`ros2 bag info` / `ros2 bag play` 一启动就报 `Exception on parsing info file: yaml-cpp: error at line 25, column 29: bad conversion`，bag 完全播不了，VINS 侧表现为一直 "waiting for image and imu"。报错行号恰好落在 `metadata.yaml` 里 `offered_qos_profiles: ''` 的引号上，极易误判成 VINS 配置文件问题（VINS 自己的 yaml 走 OpenCV FileStorage，不经 yaml-cpp）。
- **根因**：旧版 rosbags 写出的 metadata 是旧 schema——`offered_qos_profiles` 是字符串（转出来还是空串），且没有 `type_description_hash` 字段。Jazzy 的 rosbag2 解析器要求 `offered_qos_profiles` 是 YAML 序列（空序列也得写不带引号的 `[]`，写成字符串 `'[]'` 同样报 bad conversion），且每个 topic 必须带 `type_description_hash`。**是否踩中取决于 rosbags 版本**：0.11.5 实测已是 Jazzy schema（`[]` + RIHS01 hash），转完直接能用；旧版转出的才是旧 schema。所以先 `ros2 bag info` 判断，不要无条件打补丁——对 0.11.5 的输出跑补丁 sed 会插入第二个 `type_description_hash`（重复键）。
- **排查**：`ros2 bag info` 和 play 走同一个解析路径，单跑 info 三秒复现。做变体二分：删字段报 `invalid node; first invalid key: "offered_qos_profiles"`（字段必填），写 `'[]'` 仍报 bad conversion（类型不对），写裸 `[]` 才过、报错变成缺 hash——三条变体拼出真实 schema。
- **解法**：db3 不用动，只补 metadata.yaml（仅旧 schema 需要）：

  ```bash
  cp metadata.yaml metadata.yaml.orig-rosbags
  sed -e "s|offered_qos_profiles: ''|offered_qos_profiles: []|" metadata.yaml.orig-rosbags \
    | sed 's|\(      serialization_format: cdr\)|\1\n      type_description_hash: ""|' > metadata.yaml
  ```

- **原理**：跨版本的 bag 元数据是 schema 演进的重灾区。yaml-cpp 报错的行号指向值节点的起始位置（引号、方括号），不是"这行内容写错了"，别顺着行号猜，用增删字段做二分。
