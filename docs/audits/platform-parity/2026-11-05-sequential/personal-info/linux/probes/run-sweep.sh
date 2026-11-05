#!/bin/sh
set -eu
personal_probe_root=/workspace/scratch/parity-sequential-2026-11-05/personal-info/linux
personal_probe_runtime=/workspace/scratch/parity-toolchain/ci-bin/luajit
personal_sweep_name=$1
for personal_probe_name in combo-publication config-route editor-firstboot all-fields prefix-count-owner targeted; do
 PYTHONDONTWRITEBYTECODE=1 "$personal_probe_runtime" "$personal_probe_root/probes/$personal_probe_name.lua" > "$personal_probe_root/logs/final-$personal_sweep_name-$personal_probe_name.log" 2>&1
done
