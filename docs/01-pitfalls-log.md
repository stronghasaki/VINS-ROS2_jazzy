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

- **现象**：`ros2 launch vins euroc.launch.py` 无报错，但 estimator 未运行，输出文件是旧数据。
- **根因**：colcon `--symlink-install` 生成的 `install/vins/lib/vins/vins_node` 是指向 `/ws/build/...` 的符号链接；容器只挂载 `install/` 时可执行文件不存在，而 launch 文件对"进程未启动"是静默的。
- **解法**：挂载成对出现：`-v repo/build:/ws/build -v repo/install:/ws/install`。排查命令：`ls -la install/vins/lib/vins/` 查看链接指向。
- **原理**：symlink install 将构建产物与安装产物绑定，容器挂载 / 打包 / 跨机拷贝时任一单独存在都是坏的；要么成对携带，要么构建时不用 `--symlink-install`。

## 评测期

### 7. VINS 上游 `vio.csv` 无法直接对齐真值

- **现象**：evo 按 `--t_max_diff 0.02` 对齐时全部匹配失败；或输出文件根本没生成。
- **根因**：两个叠加问题，均在原版 `vio.csv` 写出代码：
  1. `foutC.precision(0)` 将时间戳截成整数秒（如 `1403636584`），与真值纳秒/微秒精度无法对齐；
  2. C++ `ofstream` 不展开 `~`，目录不存在时静默失败、不报任何错。
- **解法**：本仓库已改为标准 TUM 格式（`t tx ty tz qx qy qz qw`，微秒精度时间戳），并在读配置处加"展开 `~` + `mkdir -p`"兜底。
- **原理**：评测失败未必在算法侧；移植/复现默认"上游输出格式不可信"，先检查 IO 代码再跑评测。

### 8. evo 安装的环境问题（容器 / 宿主机两种场景）

- **容器内**：`pip3 install evo` 被 PEP 668 拦截（noble / Python 3.12 的 externally-managed-environment）。解法 `pip3 install --break-system-packages evo`，一次性镜像内安全。注意 `|| pip3 install evo` 式降级重试是反模式：降级命令撞上同一个 PEP 668 错误，误导排查方向。
- **宿主机 `pip --user`**：`evo_ape` 报 `ValueError: numpy.dtype size changed, may indicate binary incompatibility. Expected 96 from C header, got 88`。根因：22.04 系统 scipy 针对 numpy 1.x 编译，`pip --user evo` 拉入 numpy 2.x，`~/.local` 优先级高于系统包但系统 scipy 二进制未变。解法 `pip3 install --user --upgrade scipy`（1.15+ wheel 兼容 numpy 2.x）。

## 附：rosbag1 → rosbag2 转换

Jazzy 移除了 rosbag1 支持，EuRoC 的 `.bag` 需先转 rosbag2 格式，用 python `rosbags` 包，无需装 ROS1：

```bash
pip3 install rosbags
rosbags-convert MH_01_easy.bag --dst MH_01_easy_ros2
```

转换后 `ros2 bag info` 核对消息数与原 bag 一致再跑。
