#!/usr/bin/env python3
"""Cuts the SPIR-V modules PyroWave's decoder uses out of slangmosh.hpp of DELOS for Android and writes them as .spv.

    python3 extract_spirv.py <slangmosh.hpp> <output directory>

The header holds one array of 32-bit words, the modules back to back. A module starts at the SPIR-V magic number. The
three written are told apart by what they contain, not by their position:
  idwt_p1_fp16.spv      inverse transform, 16-bit shared memory, 32-bit arithmetic (PYROWAVE_PRECISION 1, the default)
  idwt_p0_fp16.spv      inverse transform with 16-bit arithmetic (PRECISION 0)
  dequant_mode1.spv     dequantisation reading the payload through texel buffers (STORAGE_MODE 1; what MoltenVK selects)
Standard library only.
"""
import re
import struct
import sys
from pathlib import Path

MAGIC = 0x07230203
OP_CAPABILITY, OP_EXECUTION_MODE, OP_TYPE_FLOAT, OP_TYPE_VECTOR, OP_FADD = 17, 16, 22, 23, 129
LOCAL_SIZE = 17
CAP_FLOAT16, CAP_SAMPLED_BUFFER, CAP_GROUP_NON_UNIFORM = 9, 46, 61


def modules(path: Path) -> list[list[int]]:
    text = path.read_text()
    start = text.index("spirv_bank[]")
    words = [int(w, 16) for w in re.findall(r"0x([0-9a-f]+)u", text[start:text.index("};", start)])]
    starts = [i for i, w in enumerate(words) if w == MAGIC and i + 1 < len(words) and words[i + 1] >> 16 == 1]
    return [words[a:b] for a, b in zip(starts, starts[1:] + [len(words)])]


def instructions(module: list[int]):
    i = 5
    while i < len(module):
        count, op = module[i] >> 16, module[i] & 0xFFFF
        if count == 0:
            return
        yield op, module[i + 1:i + count]
        i += count


def describe(module: list[int]) -> dict:
    caps, local, types, fadd = set(), None, {}, {}
    for op, args in instructions(module):
        if op == OP_CAPABILITY:
            caps.add(args[0])
        elif op == OP_EXECUTION_MODE and args[1] == LOCAL_SIZE:
            local = tuple(args[2:5])
        elif op == OP_TYPE_FLOAT:
            types[args[0]] = ("float", args[1])
        elif op == OP_TYPE_VECTOR:
            types[args[0]] = ("vector", args[1], args[2])
        elif op == OP_FADD:
            kind = types.get(args[0])
            if kind and kind[0] == "vector" and kind[2] == 2:
                width = types[kind[1]][1]
                fadd[width] = fadd.get(width, 0) + 1
    return {"caps": caps, "local": local, "fadd_vec2": fadd}


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    found: dict[str, list[int]] = {}
    for module in modules(Path(sys.argv[1])):
        info = describe(module)
        caps, local = info["caps"], info["local"]
        if local == (64, 1, 1) and CAP_GROUP_NON_UNIFORM not in caps and info["fadd_vec2"]:
            if 16 in info["fadd_vec2"]:
                found["idwt_p0_fp16"] = module
            elif CAP_FLOAT16 in caps:
                found["idwt_p1_fp16"] = module
        elif local == (128, 1, 1) and CAP_SAMPLED_BUFFER in caps:
            found["dequant_mode1"] = module
    missing = {"idwt_p0_fp16", "idwt_p1_fp16", "dequant_mode1"} - set(found)
    if missing:
        print("not found:", ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    for name, module in found.items():
        (out / f"{name}.spv").write_bytes(struct.pack(f"<{len(module)}I", *module))
        print(f"{name}.spv: {len(module) * 4} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
