#!/bin/bash
# EuRoC MH_01_easy ATE 评测脚本（evo）——修正版（v3）
# 修正记录：
#   v2：groundtruth 四元数列序。EuRoC 列序为
#       $1=timestamp $2..4=px py pz $5=qw $6..8=qx qy qz $9..=vx vy vz（wxyz）
#       TUM 为 t x y z qx qy qz qw（xyzw）。旧版误取 $6 $7 $8 $9（把 vx 当了 qw）
#       ——evo 读入不做归一化，非单位四元数污染 SE3 对齐的旋转估计。正确取法 $6 $7 $8 $5。
#   v3：官方 data.csv 是第 1 行 # 注释头 + 逗号分隔（旧注释假设"无逗号、3 行注释头"不成立，
#       awk 默认空白分隔会把整行吞成 $1，字段全空）。改用 -F','，以首字段是否纯数字判定数据行。
# 前置：vins_result_no_loop.csv / vins_result_loop.csv（VINS 输出的 TUM 格式轨迹）
#       以及 groundtruth/data.csv（EuRoC state_groundtruth_estimate0）
# 用法：./eval_euroc.sh <csv路径> [MH_01_easy目录]
set -euo pipefail

CSV=${1:?usage: eval_euroc.sh <vins_result.csv> [euroc_dataset_dir]}
DS=${2:-/bags/MH_01_easy/mav0/state_groundtruth_estimate0/data.csv}

# 自检：真值数据首行的四元数 (qw,qx,qy,qz) 模长应接近 1。
# 若模长远离 1，说明列序假设不成立，直接报错退出。
awk -F',' 'NR==2 && $1 ~ /^[0-9]+$/ {q=sqrt($5*$5+$6*$6+$7*$7+$8*$8); if (q<0.9 || q>1.1) {print "FATAL: quaternion norm " q " out of range, column layout mismatch in " DS > "/dev/stderr"; exit 1}}' DS="$DS" "$DS"

gt_tum=$(dirname "$CSV")/gt_mh01.tum
awk -F',' '$1 ~ /^[0-9]+$/ {printf "%.9f %s %s %s %s %s %s %s\n", $1/1e9, $2, $3, $4, $6, $7, $8, $5}' \
    "$DS" > "$gt_tum"

echo "=== ATE RMSE (SE3-aligned, scale-corrected) ==="
evo_ape tum "$gt_tum" "$CSV" -va --align --correct_scale \
    --t_max_diff 0.02 2>&1 | grep -E "rmse|mean|median|max|sse" || true

evo_ape tum "$gt_tum" "$CSV" -va --align --correct_scale \
    --t_max_diff 0.02 --save_results "$CSV.ape.zip" > /dev/null
echo "结果已存: $CSV.ape.zip（用 evo_res 汇总对比各版本）"
