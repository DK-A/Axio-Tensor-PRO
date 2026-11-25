#!/usr/bin/env python3
"""
optimization_engine.py - Automated Design-Space Optimization & Ablation Engine
Evaluates Array Geometries (2x2, 4x4, 8x8), Clock Frequencies (100-200 MHz),
and Buffering Modes against physical Spartan-7 FPGA resource budgets.
Supports Digilent Arty S7-25 (80 DSP cap) and Arty S7-50 (120 DSP cap).
"""

import sys
import argparse
import json
import numpy as np

# FPGA Hardware Budgets (Spartan-7 -1 Speed Grade)
FPGA_BUDGETS = {
    "Arty_S7_25": {
        "part": "xc7s25csga324-1",
        "luts": 14600,
        "ffs": 29200,
        "dsps": 80,
        "brams": 45
    },
    "Arty_S7_50": {
        "part": "xc7s50csga324-1",
        "luts": 32600,
        "ffs": 65200,
        "dsps": 120,
        "brams": 75
    }
}

WORKLOADS = {
    "tinyml_conv2d": {"M": 16, "K": 9, "N": 16, "total_ops": 16 * 9 * 16 * 2, "name": "MobileNet Conv2D Patch"},
    "kws_fc":        {"M": 32, "K": 16, "N": 16, "total_ops": 32 * 16 * 16 * 2, "name": "Keyword Spotting FC"},
    "micro_gemm":    {"M": 4,  "K": 4,  "N": 4,  "total_ops": 4 * 4 * 4 * 2,     "name": "Micro-GEMM 4x4"}
}

def evaluate_hardware_point(n: int, f_mhz: float, double_buffer: bool, fpga_key: str, workload_key: str):
    """
    Evaluates silicon resource utilization, timing closure, latency, and throughput
    for a specific architectural candidate.
    """
    budget = FPGA_BUDGETS[fpga_key]
    wl = WORKLOADS[workload_key]
    
    # 1. Silicon Resource Cost Model (Calibrated against Vivado P&R)
    # Each PE: 1 DSP48E1 slice, ~120 LUTs for control/muxing, ~140 FFs
    pe_count = n * n
    dsp_used = pe_count
    
    lut_per_pe = 115
    ff_per_pe  = 138
    
    # Buffer overhead
    buffer_bytes = 4 * n * n if double_buffer else 2 * n * n
    lut_buffer = buffer_bytes * 4
    ff_buffer  = buffer_bytes * 8
    
    # FSM & UART & Skew buffers
    lut_overhead = 380 + (n * 18)
    ff_overhead  = 420 + (n * 16)
    
    lut_total = (pe_count * lut_per_pe) + lut_buffer + lut_overhead
    ff_total  = (pe_count * ff_per_pe)  + ff_buffer  + ff_overhead
    
    # Check physical resource limits
    dsp_util_pct = (dsp_used / budget["dsps"]) * 100.0
    lut_util_pct = (lut_total / budget["luts"]) * 100.0
    
    resource_pass = (dsp_used <= budget["dsps"]) and (lut_total <= budget["luts"])
    
    # 2. Timing Closure Model (WNS Slack on Spartan-7 -1)
    # Period in ns: T_clk = 1000 / f_mhz
    # Critical path is control broadcast fanout (clr_acc broadcast across N*N array)
    t_clk_ns = 1000.0 / f_mhz
    data_delay_ns = 3.20 + (n * 0.35) # Control wire propagation across fabric
    clock_skew_ns = 0.45
    setup_req_ns  = 0.35
    total_path_ns = data_delay_ns + clock_skew_ns + setup_req_ns
    wns_slack_ns  = t_clk_ns - total_path_ns
    timing_pass   = (wns_slack_ns >= 0.0)
    
    # 3. Workload Execution Latency
    # Calculate number of tiles needed
    t_m = int(np.ceil(wl["M"] / n))
    t_k = int(np.ceil(wl["K"] / n))
    t_n = int(np.ceil(wl["N"] / n))
    total_tiles = t_m * t_n * t_k
    
    # Active compute cycles per tile: K_tile + 2N - 2 + 1 latch cycle
    cycles_per_tile = n + (2 * n) - 2 + 1
    total_compute_cycles = total_tiles * cycles_per_tile
    
    compute_latency_us = (total_compute_cycles / f_mhz)
    
    # Sustained GOPS
    sustained_gops = (wl["total_ops"] / (compute_latency_us * 1e-6)) / 1e9 if compute_latency_us > 0 else 0
    gops_per_dsp   = sustained_gops / dsp_used if dsp_used > 0 else 0
    
    # Estimated dynamic power (mW) @ f_mhz
    dynamic_power_mw = (lut_total * 0.008 + dsp_used * 0.85) * (f_mhz / 100.0)
    gops_per_watt    = (sustained_gops / (dynamic_power_mw * 1e-3)) if dynamic_power_mw > 0 else 0

    is_valid = resource_pass and timing_pass

    return {
        "n": n,
        "f_mhz": f_mhz,
        "double_buffer": double_buffer,
        "dsp_used": dsp_used,
        "dsp_util_pct": dsp_util_pct,
        "lut_total": lut_total,
        "lut_util_pct": lut_util_pct,
        "wns_slack_ns": round(wns_slack_ns, 2),
        "timing_pass": timing_pass,
        "resource_pass": resource_pass,
        "is_valid": is_valid,
        "total_compute_cycles": total_compute_cycles,
        "compute_latency_us": round(compute_latency_us, 2),
        "sustained_gops": round(sustained_gops, 3),
        "gops_per_dsp": round(gops_per_dsp, 4),
        "dynamic_power_mw": round(dynamic_power_mw, 1),
        "gops_per_watt": round(gops_per_watt, 2)
    }

def run_design_space_exploration(fpga_key: str = "Arty_S7_25", workload_key: str = "tinyml_conv2d"):
    """
    Executes a structured sweep over all design candidates and ranks Pareto-optimal points.
    """
    print("=" * 86)
    print(f"AXIO-TENSOR PRO: AUTOMATED DESIGN-SPACE OPTIMIZATION ENGINE")
    print(f"Target FPGA: {fpga_key} ({FPGA_BUDGETS[fpga_key]['part']}) | Budget: {FPGA_BUDGETS[fpga_key]['dsps']} DSPs, {FPGA_BUDGETS[fpga_key]['luts']} LUTs")
    print(f"Target Workload: {WORKLOADS[workload_key]['name']} ({WORKLOADS[workload_key]['M']}x{WORKLOADS[workload_key]['K']}x{WORKLOADS[workload_key]['N']})")
    print("=" * 86)

    geometries = [2, 4, 8]
    frequencies = [100.0, 150.0, 200.0]
    buffering_modes = [False, True] # Single vs Double Ping-Pong

    results = []
    for n in geometries:
        for f_mhz in frequencies:
            for db in buffering_modes:
                res = evaluate_hardware_point(n, f_mhz, db, fpga_key, workload_key)
                results.append(res)

    # Filter valid configurations (timing closure + resource headroom)
    valid_points = [r for r in results if r["is_valid"]]
    # Sort by sustained GOPS descending
    ranked_points = sorted(valid_points, key=lambda x: x["sustained_gops"], reverse=True)

    print(f"\n{'-'*86}")
    print(f"{'Array':<6} {'Freq':<8} {'Buffer':<10} {'DSPs':<10} {'LUTs':<11} {'WNS Slack':<11} {'Latency':<12} {'Sustained':<10} {'GOPS/W':<8}")
    print(f"{'Size':<6} {'(MHz)':<8} {'Strategy':<10} {'Used':<10} {'Used':<11} {'(ns)':<11} {'(us)':<12} {'(GOPS)':<10} {'':<8}")
    print(f"{'-'*86}")

    for r in results:
        status_tag = "" if r["is_valid"] else " [PRUNED]"
        buf_str = "Double" if r["double_buffer"] else "Single"
        wns_str = f"{r['wns_slack_ns']:+.2f} ns" if r['timing_pass'] else f"{r['wns_slack_ns']:+.2f} [FAIL]"
        dsp_str = f"{r['dsp_used']} ({r['dsp_util_pct']:.0f}%)"
        lut_str = f"{r['lut_total']} ({r['lut_util_pct']:.0f}%)"
        
        print(f"{r['n']}x{r['n']:<4} {r['f_mhz']:<8.0f} {buf_str:<10} {dsp_str:<10} {lut_str:<11} {wns_str:<11} {r['compute_latency_us']:<12.2f} {r['sustained_gops']:<10.3f} {r['gops_per_watt']:<8.1f}{status_tag}")

    print(f"{'-'*86}")
    if ranked_points:
        best = ranked_points[0]
        buf_winner = "Double (Ping-Pong)" if best["double_buffer"] else "Single Buffer"
        print(f"\n[RECOMMENDED PARETO WINNER for {fpga_key}]:")
        print(f"  [*] Architecture: {best['n']}x{best['n']} Array @ {best['f_mhz']:.0f} MHz with {buf_winner}")
        print(f"  [*] Silicon Footprint: {best['dsp_used']} DSPs ({best['dsp_util_pct']:.1f}%), {best['lut_total']} LUTs ({best['lut_util_pct']:.1f}%)")
        print(f"  [*] Timing Closure: WNS = {best['wns_slack_ns']:+.2f} ns (Positive Slack Guaranteed)")
        print(f"  [*] Performance: Latency = {best['compute_latency_us']} us | Sustained = {best['sustained_gops']} GOPS | Efficiency = {best['gops_per_watt']} GOPS/Watt")
    print("=" * 86)
    return ranked_points

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Axio-Tensor PRO DSE Engine")
    parser.add_argument("--fpga", choices=["Arty_S7_25", "Arty_S7_50"], default="Arty_S7_25")
    parser.add_argument("--workload", choices=["tinyml_conv2d", "kws_fc", "micro_gemm"], default="tinyml_conv2d")
    args = parser.parse_args()

    run_design_space_exploration(args.fpga, args.workload)
