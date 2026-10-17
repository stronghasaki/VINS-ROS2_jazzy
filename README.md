# VINS-ROS2 Jazzy

VINS-Fusion 的 ROS2 Jazzy 移植，附 EuRoC 基准结果和 Docker 复现环境。

基于 [zinuok/VINS-Fusion-ROS2](https://github.com/zinuok/VINS-Fusion-ROS2)（Humble）适配到 Jazzy，改动见 git 历史。

## EuRoC 结果（MH_01_easy, stereo+IMU）

| 平移 ATE RMSE | mean | max | 旋转 APE mean | 有效帧率 |
|---|---|---|---|---|
| 0.118 m | 0.101 m | 0.322 m | 2.77° | ~2.7 Hz（首测，机器过载丢帧，3682 帧只消化 492 帧） |
| 0.163 m | 0.149 m | 0.369 m | 1.90° | ~10 Hz（feature_tracker freq 限频，消化 1830 帧） |

两次都真实测得。VINS 的精度跟有效帧率走：丢帧越多相邻处理帧基线越长，平移 ATE 反而更好、旋转更差——复现数字对不上号，先查自己的 vio.csv 行数 ÷ 序列时长。评测用 `evo_ape`（TUM 格式，`--align --correct_scale`，`t_max_diff 0.02`），真值为 EuRoC 官方 state_groundtruth_estimate0（从 ETH research-collection 原包抽取，转换脚本 `scripts/eval_euroc.sh` 带四元数模长自检）。轨迹和 evo 结果文件在 `scripts/` 下，可以 `evo_res` 直接对比。

注：早期 README 的 0.118 m 由一份有列序 bug 的真值转换脚本算出（详见 docs/01-pitfalls-log.md 坑 8——evo 的平移 APE 只用位置，该 bug 不影响平移指标，但会毁掉旋转评测）。上表已用修正版脚本对官方真值重测确认（0.1176 m）。

## 复现

宿主机只需 Docker，不用装 ROS。数据集放哪里都行，下面用 `$DATA` 表示其路径。

```bash
# 0. 数据集：EuRoC MH_01_easy
# 从 https://projects.asl.ethz.ch/datasets/aerial-machinery-datasets/ 下载
# MH_01_easy.zip（国内直连 ETH 慢的话走 hf-mirror，见 docs/01-pitfalls-log.md 坑 7），解压：
#   $DATA/MH_01_easy.bag                          ← 第 3 步转 rosbag2 用
#   $DATA/mav0/cam0/ cam1/ imu0/ state_groundtruth_estimate0/ ...
#                                                 ← 第 5 步评测真值用

# 1. 构建依赖镜像（Ceres 2.1.0 + OpenCV + Jazzy）
cd docker
docker build -f Dockerfile.base -t vins-jazzy-base .

# 2. 编译工作区（~10 min，8GB 内存放缓一点见 Notes）
docker run --rm -v $PWD/..:/ws -w /ws vins-jazzy-base \
    bash -c "source /opt/ros/jazzy/setup.bash && \
    MAKEFLAGS=-j2 colcon build --symlink-install --parallel-workers 1"

# 3. EuRoC 的 .bag 转成 rosbag2（Jazzy 读不了 .bag）
pip3 install rosbags
rosbags-convert $DATA/MH_01_easy.bag --dst $DATA/MH_01_easy_ros2

# 3.5 rosbags 转出的 metadata 是旧 schema，不补 Jazzy 读不了（ros2 bag info 三秒可验，
#     报 yaml-cpp bad conversion 就是它；详见 pitfalls 坑 10）
cd $DATA/MH_01_easy_ros2
cp metadata.yaml metadata.yaml.orig-rosbags
sed -e "s|offered_qos_profiles: ''|offered_qos_profiles: []|" metadata.yaml.orig-rosbags \
  | sed 's|\(      serialization_format: cdr\)|\1\n      type_description_hash: ""|' > metadata.yaml
cd -

# 4. 跑（src 必须挂到 /ws/src/src：install/ 内 launch/config 软链接指向 /ws/src/src/**，
#    挂成 /ws/src 会报 FileNotFoundError，见 pitfalls 坑 6）
docker run --rm --network host \
    -v $PWD/../src:/ws/src/src -v $PWD/../build:/ws/build -v $PWD/../install:/ws/install \
    -v $DATA/MH_01_easy_ros2:/bags:ro -v $HOME/vins_out:/root \
    vins-jazzy-base bash -c "source /opt/ros/jazzy/setup.bash && \
    source /ws/install/local_setup.bash && \
    (ros2 launch vins euroc.launch.py &) && sleep 8 && \
    ros2 bag play /bags && sleep 30"
# 轨迹输出在 $HOME/vins_out/output/vio.csv（TUM 格式）

# 5. 评测（脚本做真值 TUM 化 + 四元数模长自检 + evo_ape）
./scripts/eval_euroc.sh $HOME/vins_out/output/vio.csv \
    $DATA/mav0/state_groundtruth_estimate0/data.csv
# 结果: vio.csv.ape.zip + gt_mh01.tum，多次实验用 evo_res *.ape.zip 对比
```

注意：`build/` 和 `install/` 必须同时挂载，colcon `--symlink-install` 生成的 `install/*/lib/**` 是指向 `build/` 的软链接，只挂一个会找不到可执行文件；同理 src 要挂到 `/ws/src/src`（坑 6 / 坑 10 见 [docs/01-pitfalls-log.md](docs/01-pitfalls-log.md)）。

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
