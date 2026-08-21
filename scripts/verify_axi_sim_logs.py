#!/usr/bin/env python3
"""
scripts/verify_axi_sim_logs.py
Parses Icarus/VVP simulation logs to verify AXI4-Lite read/write transaction integrity.
"""

import sys
import re
import argparse
from dataclasses import dataclass
from typing import List, Dict, Optional

# Valid CSR Address Ranges in NCE Architecture
VALID_CSR_RANGES = [
    (0x000, 0x038),  # Base CSRs (VERSION, CAPABILITIES, CONTROL, COMMAND, STATUS, ERROR, PERF)
    (0x040, 0x080),  # Vector Staging & Commit
    (0x0A0, 0x0E0),  # Matrix Staging & Commit
    (0x100, 0x138),  # Readback & Exception Flags
    (0x140, 0x1D4),  # Systolic GEMM CSRs
    (0x200, 0x3FF),  # Tiled GEMM CSRs
    (0x400, 0x4FF),  # Conv3x3 CSRs
    (0x500, 0x7FF),  # Tensor Memory CSRs
]

RE_WRITE_OKAY = re.compile(
    r"\[\s*(?P<time>\d+)\]\s+WRITE OKAY:\s+addr=0x(?P<addr>[0-9a-fA-F]+),\s+data=0x(?P<data>[0-9a-fA-F]+),\s+strb=0x(?P<strb>[0-9a-fA-F]+),\s+resp=0x(?P<resp>[0-9a-fA-F]+)"
)

RE_READ_OKAY = re.compile(
    r"\[\s*(?P<time>\d+)\]\s+READ OKAY:\s+addr=0x(?P<addr>[0-9a-fA-F]+),\s+data=0x(?P<data>[0-9a-fA-F]+),\s+resp=0x(?P<resp>[0-9a-fA-F]+)"
)

RE_ERROR_EXP = re.compile(
    r"\[\s*(?P<time>\d+)\]\s+(?P<op>WRITE|READ) ERROR expected:\s+addr=0x(?P<addr>[0-9a-fA-F]+),\s+resp=0x(?P<resp>[0-9a-fA-F]+)"
)

RE_TB_SUMMARY = re.compile(
    r"(?P<status>PASS|FAIL):\s+(?P<module>\w+)\s+(?P<msg>.*)"
)

def is_mapped_addr(addr: int) -> bool:
    return any(start <= addr <= end for start, end in VALID_CSR_RANGES)

def verify_log_file(file_path: str) -> bool:
    total_writes = 0
    total_reads = 0
    total_expected_errors = 0
    violations = []
    last_time = 0
    tb_passed = False

    try:
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                
                # 1. Match WRITE OKAY
                m_wr = RE_WRITE_OKAY.search(line)
                if m_wr:
                    total_writes += 1
                    t = int(m_wr.group("time"))
                    addr = int(m_wr.group("addr"), 16)
                    resp = int(m_wr.group("resp"), 16)
                    
                    if t < last_time:
                        violations.append(f"Line {line_num}: Time regression ({t} < {last_time})")
                    last_time = t
                    
                    if resp != 0:
                        violations.append(f"Line {line_num}: WRITE OKAY had non-zero response (resp={resp})")
                    if not is_mapped_addr(addr):
                        violations.append(f"Line {line_num}: WRITE OKAY to unmapped address (addr=0x{addr:08x})")
                    continue

                # 2. Match READ OKAY
                m_rd = RE_READ_OKAY.search(line)
                if m_rd:
                    total_reads += 1
                    t = int(m_rd.group("time"))
                    addr = int(m_rd.group("addr"), 16)
                    resp = int(m_rd.group("resp"), 16)
                    
                    if t < last_time:
                        violations.append(f"Line {line_num}: Time regression ({t} < {last_time})")
                    last_time = t
                    
                    if resp != 0:
                        violations.append(f"Line {line_num}: READ OKAY had non-zero response (resp={resp})")
                    if not is_mapped_addr(addr):
                        violations.append(f"Line {line_num}: READ OKAY to unmapped address (addr=0x{addr:08x})")
                    continue

                # 3. Match Expected Errors
                m_err = RE_ERROR_EXP.search(line)
                if m_err:
                    total_expected_errors += 1
                    addr = int(m_err.group("addr"), 16)
                    resp = int(m_err.group("resp"), 16)
                    if resp != 2:
                        violations.append(f"Line {line_num}: Expected SLVERR (0x2) but resp was {resp}")
                    continue

                # 4. Match TB Summary
                m_sum = RE_TB_SUMMARY.search(line)
                if m_sum:
                    if m_sum.group("status") == "PASS":
                        tb_passed = True
                    else:
                        violations.append(f"Line {line_num}: Testbench reported FAIL: {m_sum.group('msg')}")

    except Exception as e:
        print(f"Error reading log file {file_path}: {e}")
        return False

    print(f"\n==================================================")
    print(f" AXI Simulation Verification Report: {file_path}")
    print(f"==================================================")
    print(f" Total Writes Verified:         {total_writes}")
    print(f" Total Reads Verified:          {total_reads}")
    print(f" Expected SLVERR Checked:       {total_expected_errors}")
    print(f" Testbench Assertion Passed:    {tb_passed}")
    print(f" Protocol Violations Found:     {len(violations)}")
    print(f"==================================================")

    if violations:
        print("\nVIOLATION DETAILS:")
        for v in violations[:10]:
            print(f"  [!] {v}")
        return False
    elif not tb_passed and (total_writes > 0 or total_reads > 0):
        print("  [!] Error: No explicit testbench PASS marker found in log.")
        return False
    else:
        print(" [✓] STATUS: ALL AXI TRANSACTIONS CLEAN AND VERIFIED.\n")
        return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AXI Simulation Log Integrity Verifier")
    parser.add_argument("log_files", nargs="+", help="Path to simulation log files (.log)")
    args = parser.parse_args()

    all_passed = True
    for log_path in args.log_files:
        if not verify_log_file(log_path):
            all_passed = False
    sys.exit(0 if all_passed else 1)
