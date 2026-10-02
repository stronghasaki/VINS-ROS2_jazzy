# VINS-ROS2 Jazzy

VINS-Fusion 的 ROS2 Jazzy 移植，附 EuRoC 基准结果和 Docker 复现环境。

基于 [zinuok/VINS-Fusion-ROS2](https://github.com/zinuok/VINS-Fusion-ROS2)（Humble）适配到 Jazzy，改动见 git 历史。

## EuRoC 结果（MH_01_easy, stereo+IMU）

| ATE RMSE | mean | max |
|---|---|---|
| 0.118 m | 0.101 m | 0.322 m |

492 个关键帧，solver 约 45 ms/frame。评测用 `evo_ape`（TUM 格式，`--align --correct_scale`，`t_max_diff 0.02`），真值为 EuRoC state_groundtruth_estimate0。轨迹和 evo 结果文件在 `scripts/` 下，可以 `evo_res` 直接对比。

## 复现

宿主机只需 Docker，不用装 ROS。

```bash
# 1. 构建依赖镜像（Ceres 2.1.0 + OpenCV + Jazzy）
cd docker
docker build -f Dockerfile.base -t vins-jazzy-base .

# 2. 编译工作区（~10 min，8GB 内存放缓一点见 Notes）
docker run --rm -v $PWD/..:/ws -w /ws vins-jazzy-base \
    bash -c "source /opt/ros/jazzy/setup.bash && \
    MAKEFLAGS=-j2 colcon build --symlink-install --parallel-workers 1"

# 3. EuRoC 的 .bag 转成 rosbag2（Jazzy 读不了 .bag）
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
# 轨迹输出在 $HOME/vins_out/output/vio.csv（TUM 格式）

# 5. 评测
evo_ape tum groundtruth.tum vio.csv -a -as --t_max_diff 0.02
```

注意：`build/` 和 `install/` 必须同时挂载，colcon `--symlink-install` 生成的 `install/*/lib/**` 是指向 `build/` 的软链接，只挂一个会找不到可执行文件。

## Notes

- Ubuntu 22.04 装不了 Jazzy，用 Docker。
- Ceres 必须是 2.1.0，2.2 删了 `LocalParameterization`，VINS/camodocal 编译不过。noble 上编译 2.1.0 报 `CXSparse::CXSparse` ALIAS missing，加 `-DCXSPARSE=OFF`（VINS 本来就不用 CXSparse）。
- `ros:jazzy` 镜像不带 OpenCV 开发包，需要 `libopencv-dev` + Boost dev。
- 8GB 内存编译会 OOM（`cc1plus: Killed`，DBoW2 模板 + -O3 单文件峰值超 2GB），用 `MAKEFLAGS=-j2 colcon build --parallel-workers 1`。
- Jazzy 的 cv_bridge 4.x 删了 `.h` 兼容头，`cv_bridge.h` 要改成 `cv_bridge.hpp`。
- 上游的 `vio.csv` 输出时间戳是整数秒（`precision(0)` 截断），evo 对不上真值；且配置里的 `~` 不展开、目录不存在时 ofstream 静默失败。本仓库已改为标准 TUM 格式输出并做了路径兜底。
- 宿主机装 evo 遇到 PEP 668 / numpy-scipy 冲突的话，装在容器里。

细节记录：[docs/01-pitfalls-log.md](docs/01-pitfalls-log.md)

## 结构

```
├── src/
│   ├── camera_models/   # camodocal
│   ├── config/          # euroc / realsense / KITTI 配置
│   ├── global_fusion/   # GPS 融合
│   ├── loop_fusion/     # 回环 + 位姿图
│   └── vins/            # 核心估计器
├── docker/Dockerfile.base
├── scripts/eval_euroc.sh
└── docs/01-pitfalls-log.md
```

## License

GPLv3，继承自上游。数据集：[EuRoC MAV](https://projects.asl.ethz.ch/datasets/aerial-machinery-datasets/) (ETH Zurich)。
