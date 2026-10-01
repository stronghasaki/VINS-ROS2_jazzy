#!/bin/bash
# EuRoC MH_01_easy ATE 评测脚本（evo）
# 前置：vins_result_no_loop.csv / vins_result_loop.csv（VINS 输出的 TUM 格式轨迹）
#       以及 groundtruth/data.csv（EuRoC state_groundtruth_estimate0）
# 用法：./eval_euroc.sh <csv路径> [MH_01_easy目录]
set -euo pipefail

CSV=${1:?usage: eval_euroc.sh <vins_result.csv> [euroc_dataset_dir]}
DS=${2:-/bags/MH_01_easy/mav0/state_groundtruth_estimate0/data.csv}

# EuRoC groundtruth 是 timestamp tx ty tz qx qy qz qw（无逗号分隔头3行注释）
# TUM 格式是 timestamp tx ty tz qx qy qz qw（空格分隔）——列序恰好一致，只差时间单位
# VINS 输出的时间戳已是秒（nS 转换在 rosNode 里做），groundtruth 是纳秒
gt_tum=$(dirname "$CSV")/gt_mh01.tum
awk 'NR>3 {printf "%.9f %s %s %s %s %s %s %s\n", $1/1e9, $2, $3, $4, $6, $7, $8, $9}' \
    "$DS" > "$gt_tum"

echo "=== ATE RMSE (no alignment if loop closed; SE3-aligned) ==="
evo_ape tum "$gt_tum" "$CSV" -va --align --correct_scale \
    --t_max_diff 0.02 --t_min_diff 0.0 2>&1 | grep -E "rmse|mean|median|max|sse" || true

evo_ape tum "$gt_tum" "$CSV" -va --align --correct_scale \
    --t_max_diff 0.02 --t_min_diff 0.0 --save_results "$CSV.ape.zip" > /dev/null
echo "结果已存: $CSV.ape.zip（用 evo_res 汇总对比各版本）"
