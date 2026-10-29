#!/usr/bin/env python3
"""Generate differential tests for the Luau RISC-V CPU.

Python's big integers give an exact reference for RV32IM arithmetic. This writes
tests/CpuCases.spec.luau, which runs each instruction in the Luau CPU and
compares the result.

    python3 tools/gen_cpu_tests.py
"""
import os
import random

MASK = 0xFFFFFFFF
random.seed(1234)


def s32(x):
    x &= MASK
    return x - (1 << 32) if x & 0x80000000 else x


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def i_type(imm, rs1, funct3, rd, opcode=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


R_OPS = {
    "ADD": (0x00, 0, lambda a, b: a + b),
    "SUB": (0x20, 0, lambda a, b: a - b),
    "SLL": (0x00, 1, lambda a, b: a << (b & 31)),
    "SLT": (0x00, 2, lambda a, b: int(s32(a) < s32(b))),
    "SLTU": (0x00, 3, lambda a, b: int(a < b)),
    "XOR": (0x00, 4, lambda a, b: a ^ b),
    "SRL": (0x00, 5, lambda a, b: a >> (b & 31)),
    "SRA": (0x20, 5, lambda a, b: s32(a) >> (b & 31)),
    "OR": (0x00, 6, lambda a, b: a | b),
    "AND": (0x00, 7, lambda a, b: a & b),
    "MUL": (0x01, 0, lambda a, b: a * b),
    "MULH": (0x01, 1, lambda a, b: (s32(a) * s32(b)) >> 32),
    "MULHSU": (0x01, 2, lambda a, b: (s32(a) * b) >> 32),
    "MULHU": (0x01, 3, lambda a, b: (a * b) >> 32),
    "DIV": (0x01, 4, lambda a, b: -1 if b == 0 else (a if (s32(a) == -(1 << 31) and s32(b) == -1) else trunc_div(s32(a), s32(b)))),
    "DIVU": (0x01, 5, lambda a, b: MASK if b == 0 else a // b),
    "REM": (0x01, 6, lambda a, b: a if b == 0 else (0 if (s32(a) == -(1 << 31) and s32(b) == -1) else s32(a) - trunc_div(s32(a), s32(b)) * s32(b))),
    "REMU": (0x01, 7, lambda a, b: a if b == 0 else a % b),
}

I_OPS = {
    "ADDI": (0, lambda a, imm: a + imm),
    "SLTI": (2, lambda a, imm: int(s32(a) < imm)),
    "SLTIU": (3, lambda a, imm: int(a < (imm & MASK))),
    "XORI": (4, lambda a, imm: a ^ (imm & MASK)),
    "ORI": (6, lambda a, imm: a | (imm & MASK)),
    "ANDI": (7, lambda a, imm: a & (imm & MASK)),
}

SHIFT_OPS = {
    "SLLI": (0x00, 1, lambda a, sh: a << sh),
    "SRLI": (0x00, 5, lambda a, sh: a >> sh),
    "SRAI": (0x20, 5, lambda a, sh: s32(a) >> sh),
}

EDGE = [0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0x0000FFFF,
        0xFFFF0000, 0x00010000, 0x12345678, 0xDEADBEEF, 31, 32, 33]


def operands(n):
    vals = [(a, b) for a in EDGE for b in EDGE]
    for _ in range(n):
        vals.append((random.getrandbits(32), random.getrandbits(32)))
        vals.append((random.getrandbits(32), random.getrandbits(random.choice([1, 4, 8, 16]))))
    return vals


def main():
    cases = []  # (name, instruction, a, b, expected)
    for name, (f7, f3, fn) in R_OPS.items():
        for a, b in operands(60):
            cases.append((name, r_type(f7, 2, 1, f3, 3), a, b, fn(a, b) & MASK))
    for name, (f3, fn) in I_OPS.items():
        for a, _ in operands(30):
            for imm in (0, 1, -1, 2047, -2048, random.randint(-2048, 2047)):
                cases.append((name, i_type(imm, 1, f3, 3), a, 0, fn(a, imm) & MASK))
    for name, (f7, f3, fn) in SHIFT_OPS.items():
        for a, _ in operands(10):
            for sh in (0, 1, 15, 16, 31, random.randint(0, 31)):
                inst = (f7 << 25) | (sh << 20) | (1 << 15) | (f3 << 12) | (3 << 7) | 0x13
                cases.append((name, inst, a, 0, fn(a, sh) & MASK))

    # Loads after a word store: rd = load(base + off) with sign/zero extension.
    mem_cases = []  # (name, instruction, word stored at 0x100, offset, expected)
    LOADS = {"LB": (0, 1, True), "LH": (1, 2, True), "LW": (2, 4, False), "LBU": (4, 1, False), "LHU": (5, 2, False)}
    for name, (f3, size, signed) in LOADS.items():
        for _ in range(40):
            word = random.getrandbits(32)
            word2 = random.getrandbits(32)
            off = random.randrange(0, 5)
            data = word.to_bytes(4, "little") + word2.to_bytes(4, "little")
            v = int.from_bytes(data[off:off + size], "little")
            if signed and v >> (size * 8 - 1):
                v -= 1 << (size * 8)
            inst = i_type(off, 1, f3, 3, opcode=0x03)
            mem_cases.append((name, inst, word, word2, v & MASK))
    # Stores: store rs2 at base + off, then read the two words back.
    store_cases = []
    STORES = {"SB": (0, 1), "SH": (1, 2), "SW": (2, 4)}
    for name, (f3, size) in STORES.items():
        for _ in range(40):
            word, word2, val = random.getrandbits(32), random.getrandbits(32), random.getrandbits(32)
            off = random.randrange(0, 5)
            data = bytearray(word.to_bytes(4, "little") + word2.to_bytes(4, "little"))
            data[off:off + size] = (val & ((1 << (size * 8)) - 1)).to_bytes(size, "little")
            inst = ((off >> 5) << 25) | (2 << 20) | (1 << 15) | (f3 << 12) | ((off & 31) << 7) | 0x23
            store_cases.append((name, inst, word, word2, val, int.from_bytes(data[0:4], "little"), int.from_bytes(data[4:8], "little")))
    # Branches: taken or not (offset +8).
    branch_cases = []
    BR = {"BEQ": (0, lambda a, b: a == b), "BNE": (1, lambda a, b: a != b), "BLT": (4, lambda a, b: s32(a) < s32(b)),
          "BGE": (5, lambda a, b: s32(a) >= s32(b)), "BLTU": (6, lambda a, b: a < b), "BGEU": (7, lambda a, b: a >= b)}
    for name, (f3, fn) in BR.items():
        for a, b in operands(10):
            imm = 8
            inst = (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (2 << 20) | (1 << 15) | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63
            branch_cases.append((name, inst, a, b, 1 if fn(a, b) else 0))
    # AMOs on memory word at 0x100: rd = old, mem = op(old, rs2).
    amo_cases = []
    AMO = {"AMOSWAP": (1, lambda m, v: v), "AMOADD": (0, lambda m, v: m + v), "AMOXOR": (4, lambda m, v: m ^ v),
           "AMOAND": (12, lambda m, v: m & v), "AMOOR": (8, lambda m, v: m | v),
           "AMOMIN": (16, lambda m, v: m if s32(m) < s32(v) else v), "AMOMAX": (20, lambda m, v: m if s32(m) > s32(v) else v),
           "AMOMINU": (24, lambda m, v: min(m, v)), "AMOMAXU": (28, lambda m, v: max(m, v))}
    for name, (f5, fn) in AMO.items():
        for m, v in operands(10):
            inst = (f5 << 27) | (2 << 20) | (1 << 15) | (2 << 12) | (3 << 7) | 0x2F
            amo_cases.append((name, inst, m, v, m & MASK, fn(m, v) & MASK))

    out = [
        "-- Generated by tools/gen_cpu_tests.py. Do not edit.",
        "-- Each case: { name, instruction, rs1 value, rs2 value, expected rd }",
        "return function(test, root, require)",
        "\tlocal Cpu = require(root.LinuxVM.Emulator.Cpu)",
        "\tlocal CASES = {",
    ]
    for name, inst, a, b, exp in cases:
        out.append(f'\t\t{{ "{name}", 0x{inst:08X}, 0x{a:08X}, 0x{b:08X}, 0x{exp:08X} }},')
    out += [
        "\t}",
        "\tlocal ram = buffer.create(4096)",
        "\tlocal mmio = { load = function() return 0 end, store = function() return nil end,",
        "\t\tcsrRead = function() return 0 end, csrWrite = function() end }",
        "\tlocal cpu = Cpu.new(ram, mmio)",
        "\tlocal failures = {}",
        "\tfor _, c in CASES do",
        "\t\tcpu:reset(0x80000000, 0, 0)",
        "\t\tcpu.regs[2] = c[3]",
        "\t\tcpu.regs[3] = c[4]",
        "\t\tbuffer.writeu32(ram, 0, c[2])",
        "\t\tcpu:step(1, 0)",
        "\t\tif cpu.regs[4] ~= c[5] then",
        "\t\t\ttable.insert(failures, string.format(\"%s(%08X, %08X) = %08X, expected %08X\", c[1], c[3], c[4], cpu.regs[4], c[5]))",
        "\t\tend",
        "\tend",
        "\tlocal MEM = {",
    ] + [f'\t\t{{ "{n}", 0x{i:08X}, 0x{w:08X}, 0x{w2:08X}, 0x{e:08X} }},' for n, i, w, w2, e in mem_cases] + [
        "\t}",
        "\tfor _, c in MEM do",
        "\t\tcpu:reset(0x80000000, 0, 0)",
        "\t\tbuffer.writeu32(ram, 0x100, c[3])",
        "\t\tbuffer.writeu32(ram, 0x104, c[4])",
        "\t\tcpu.regs[2] = 0x80000100",
        "\t\tbuffer.writeu32(ram, 0, c[2])",
        "\t\tcpu:step(1, 0)",
        "\t\tif cpu.regs[4] ~= c[5] then",
        "\t\t\ttable.insert(failures, string.format(\"%s [%08X %08X] = %08X, expected %08X\", c[1], c[3], c[4], cpu.regs[4], c[5]))",
        "\t\tend",
        "\tend",
        "\tlocal STORES = {",
    ] + [f'\t\t{{ "{n}", 0x{i:08X}, 0x{w:08X}, 0x{w2:08X}, 0x{v:08X}, 0x{e1:08X}, 0x{e2:08X} }},' for n, i, w, w2, v, e1, e2 in store_cases] + [
        "\t}",
        "\tfor _, c in STORES do",
        "\t\tcpu:reset(0x80000000, 0, 0)",
        "\t\tbuffer.writeu32(ram, 0x100, c[3])",
        "\t\tbuffer.writeu32(ram, 0x104, c[4])",
        "\t\tcpu.regs[2] = 0x80000100",
        "\t\tcpu.regs[3] = c[5]",
        "\t\tbuffer.writeu32(ram, 0, c[2])",
        "\t\tcpu:step(1, 0)",
        "\t\tlocal w1, w2 = buffer.readu32(ram, 0x100), buffer.readu32(ram, 0x104)",
        "\t\tif w1 ~= c[6] or w2 ~= c[7] then",
        "\t\t\ttable.insert(failures, string.format(\"%s %08X -> %08X %08X, expected %08X %08X\", c[1], c[5], w1, w2, c[6], c[7]))",
        "\t\tend",
        "\tend",
        "\tlocal BRANCHES = {",
    ] + [f'\t\t{{ "{n}", 0x{i:08X}, 0x{a:08X}, 0x{b:08X}, {t} }},' for n, i, a, b, t in branch_cases] + [
        "\t}",
        "\tfor _, c in BRANCHES do",
        "\t\tcpu:reset(0x80000000, 0, 0)",
        "\t\tcpu.regs[2] = c[3]",
        "\t\tcpu.regs[3] = c[4]",
        "\t\tbuffer.writeu32(ram, 0, c[2])",
        "\t\tcpu:step(1, 0)",
        "\t\tlocal taken = if cpu.pc == 0x80000008 then 1 else 0",
        "\t\tif taken ~= c[5] then",
        "\t\t\ttable.insert(failures, string.format(\"%s(%08X, %08X) taken=%d, expected %d\", c[1], c[3], c[4], taken, c[5]))",
        "\t\tend",
        "\tend",
        "\tlocal AMOS = {",
    ] + [f'\t\t{{ "{n}", 0x{i:08X}, 0x{m:08X}, 0x{v:08X}, 0x{rd:08X}, 0x{nm:08X} }},' for n, i, m, v, rd, nm in amo_cases] + [
        "\t}",
        "\tfor _, c in AMOS do",
        "\t\tcpu:reset(0x80000000, 0, 0)",
        "\t\tbuffer.writeu32(ram, 0x100, c[3])",
        "\t\tcpu.regs[2] = 0x80000100",
        "\t\tcpu.regs[3] = c[4]",
        "\t\tbuffer.writeu32(ram, 0, c[2])",
        "\t\tcpu:step(1, 0)",
        "\t\tlocal mem = buffer.readu32(ram, 0x100)",
        "\t\tif cpu.regs[4] ~= c[5] or mem ~= c[6] then",
        "\t\t\ttable.insert(failures, string.format(\"%s(mem %08X, %08X) rd=%08X mem=%08X, expected %08X %08X\", c[1], c[3], c[4], cpu.regs[4], mem, c[5], c[6]))",
        "\t\tend",
        "\tend",
        "\ttest(string.format(\"CPU matches the reference (%d ALU, %d load, %d store, %d branch, %d AMO cases)\", #CASES, #MEM, #STORES, #BRANCHES, #AMOS), function()",
        "\t\tif #failures > 0 then",
        "\t\t\terror(#failures .. \" mismatches, e.g.:\\n  \" .. table.concat(failures, \"\\n  \", 1, math.min(#failures, 12)))",
        "\t\tend",
        "\tend)",
        "end",
    ]
    path = os.path.join(os.path.dirname(__file__), "..", "tests", "CpuCases.spec.luau")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {len(cases)} cases to {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
