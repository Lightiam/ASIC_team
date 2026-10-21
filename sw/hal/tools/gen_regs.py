#!/usr/bin/env python3
"""Generate nce_regs.h from the CSR RTL.

The register map lives in exactly one place -- the SystemVerilog that decodes
it. This script reads that file and emits the C header, so software can never
describe a register the hardware does not implement.

Usage:  python3 sw/hal/tools/gen_regs.py <path-to-nce_axi_csr_backend.sv> <out.h>
"""
import re, sys, io

def main(rtl_path, out_path):
    src = io.open(rtl_path, encoding="utf-8", errors="replace").read()

    regs = [(n[5:], int(v.replace("_", ""), 16)) for n, v in
            re.findall(r"localparam logic \[31:0\] (ADDR_[A-Z0-9_]+)\s*=\s*32'h([0-9A-F_]+)", src)]
    devid  = re.search(r"DEVICE_ID_VALUE\s*=\s*32'h([0-9A-F_]+)", src).group(1).replace("_", "")
    verval = re.search(r"VERSION_VALUE\s*=\s*32'h([0-9A-F_]+)", src).group(1).replace("_", "")

    # Writable set = every address the write-accept decoder does not reject.
    m = re.search(r"if \(write_addr_i\[1:0\] != 2'b00\).*?endcase", src, re.S)
    writable = set(re.findall(r"(ADDR_[A-Z0-9_]+)", m.group(0))) if m else set()

    span = max(a for _, a in regs) + 4
    ascii_id = "".join(chr((int(devid, 16) >> s) & 0xFF) for s in (24, 16, 8, 0))

    o = []
    o.append("// " + "=" * 75)
    o.append("// nce_regs.h -- NCE AXI4-Lite control/status register map")
    o.append("//")
    o.append("// GENERATED FROM RTL. Do not hand-edit.")
    o.append("//   source : rtl/bus/nce_axi_csr_backend.sv")
    o.append("//   tool   : sw/hal/tools/gen_regs.py")
    o.append("//")
    o.append("// Interface reality, because it is easy to assume otherwise:")
    o.append("//   * AXI4-Lite, 32-bit address. There is no PCIe in this design")
    o.append("//     (docs/spec/ARCHITECTURE.md defers it), so there is no BAR and no")
    o.append("//     fixed physical base. The base is wherever the integrator maps the")
    o.append("//     slave, which is why it is a constructor argument, not a constant.")
    o.append("//   * The entire file spans 0x000..0x%03X. No paged subsystem windows." % (span - 4))
    o.append("//   * Writes must be 32-bit aligned and use a full byte strobe.")
    o.append("//   * There are no thermal, laser, HBM or ECC registers. Those blocks")
    o.append("//     do not exist in this RTL.")
    o.append("// " + "=" * 75)
    o.append("")
    o.append("#pragma once")
    o.append("")
    o.append("#include <stdint.h>")
    o.append("")
    o.append("/* Identity. DEVICE_ID reads ASCII %r. */" % ascii_id)
    o.append("#define NCE_DEVICE_ID_VALUE   0x%sU" % devid)
    o.append("#define NCE_VERSION_VALUE     0x%sU" % verval)
    o.append("#define NCE_REG_SPAN_BYTES    0x%03XU" % span)
    o.append("")
    o.append("/* Offsets in bytes from the slave base. RW = accepted by the write")
    o.append("   decoder; RO = reads back, writes are rejected with an error. */")
    for n, a in regs:
        o.append("#define NCE_REG_%-22s 0x%03XU   /* %s */" %
                 (n, a, "RW" if ("ADDR_" + n) in writable else "RO"))
    o.append("")
    o.append("/* STATUS (0x%03X) bits, from the RTL read path: command handshake and" %
             dict(regs)["STATUS"])
    o.append("   IEEE-754 exception flags. */")
    st = re.search(r"ADDR_STATUS: begin(.*?)\n\s*end", src, re.S)
    if st:
        for mm in re.finditer(r"read_data_o\[(\d+)(?::(\d+))?\]\s*=\s*(\w+)", st.group(1)):
            hi, lo, sig = mm.group(1), mm.group(2), mm.group(3)
            name = re.sub(r"_(i|q)$", "", sig).upper()
            if lo:
                o.append("#define %-40s %sU" % ("NCE_STATUS_" + name + "_SHIFT", lo))
                o.append("#define %-40s 0x%XU" % ("NCE_STATUS_" + name + "_MASK",
                                                  (1 << (int(hi) - int(lo) + 1)) - 1))
            else:
                o.append("#define %-40s (1U << %s)" % ("NCE_STATUS_" + name, hi))

    io.open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(o) + "\n")
    print("generated %s: %d registers, %d writable, DEVICE_ID=0x%s (%r)" %
          (out_path, len(regs), len(writable & {"ADDR_" + n for n, _ in regs}), devid, ascii_id))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
