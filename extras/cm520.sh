#!/bin/bash
set -e

WORK_IB="${1:?Usage: $0 <work_ib_dir> [opboot|restore]}"
MODE="${2:-opboot}"

DTB_FILE=$(find "$WORK_IB/build_dir" -name "*cm520-79f.dtb" | head -n 1)
ITB_FILE=$(find "$WORK_IB/build_dir" -name "*cm520-79f*.itb" | head -n 1)
DTC_BIN=$(find "$WORK_IB" -name dtc -type f 2>/dev/null | head -n 1)
[ ! -x "$DTC_BIN" ] && DTC_BIN=$(command -v dtc || true)

[ -n "$DTB_FILE" ] && [ -f "$DTB_FILE.orig" ] && cp -f "$DTB_FILE.orig" "$DTB_FILE"
[ -n "$ITB_FILE" ] && [ -f "$ITB_FILE.orig" ] && cp -f "$ITB_FILE.orig" "$ITB_FILE"

[ "$MODE" = "restore" ] && exit 0

if [ -z "$DTB_FILE" ] || [ -z "$ITB_FILE" ] || [ -z "$DTC_BIN" ]; then
	echo "[cm520] ERROR: CM520 DTB, ITB, or dtc not found" >&2
	exit 1
fi

[ ! -f "$DTB_FILE.orig" ] && cp -f "$DTB_FILE" "$DTB_FILE.orig"
[ ! -f "$ITB_FILE.orig" ] && cp -f "$ITB_FILE" "$ITB_FILE.orig"

python3 - "$DTB_FILE" "$ITB_FILE" "$DTC_BIN" <<'PYEOF'
import hashlib, re, struct, subprocess, sys, zlib
from pathlib import Path

dtb_path, itb_path, dtc_bin = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

dts_path = dtb_path.with_suffix(".dtb.dts")
subprocess.run([dtc_bin, "-q", "-I", "dtb", "-O", "dts", "-o", str(dts_path), str(dtb_path)], check=True)
dts = dts_path.read_text(encoding="utf-8")
dts, n_sub = re.subn(r'(label\s*=\s*)"ubi"', r'\1"rootfs"', dts)
assert n_sub > 0, "未在 DTB 中找到 ubi 分区标签"

bootargs_line = 'bootargs-append = " ubi.block=0,1 root=/dev/ubiblock0_1";'
if "ubi.block=0,1" not in dts:
    if re.search(r'\bchosen\s*\{', dts):
        dts = re.sub(r'(\bchosen\s*\{)', lambda m: m.group(1) + "\n\t\t" + bootargs_line, dts, count=1)
    else:
        dts, n_root = re.subn(r'\n\};\s*$', "\n\tchosen {\n\t\t" + bootargs_line + "\n\t};\n};\n", dts, count=1)
        assert n_root == 1, "未能在 DTB 根节点末尾注入 chosen"

dts_path.write_text(dts, encoding="utf-8")
subprocess.run([dtc_bin, "-q", "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_path)], check=True)
dts_path.unlink(missing_ok=True)

new_dtb = dtb_path.read_bytes()
assert b"rootfs\x00" in new_dtb and b"ubi.block=0,1" in new_dtb, "DTB 补丁未生效"

itb_dts_path = itb_path.with_suffix(".itb.dts")
subprocess.run([dtc_bin, "-q", "-I", "dtb", "-O", "dts", "-o", str(itb_dts_path), str(itb_path)], check=True)
itb_dts = itb_dts_path.read_text(encoding="utf-8")

m_fdt = re.search(r'(\bfdt[-@]\d+\s*\{)(.*?)(\n\t\t\};)', itb_dts, flags=re.S)
assert m_fdt, "未在 FIT .itb 中找到 fdt 节点"
fdt_body = m_fdt.group(2)

hex_bytes = " ".join(f"{b:02x}" for b in new_dtb)
fdt_body, n_data = re.subn(r'(\bdata\s*=\s*)(\[[^\]]*\]|<[^>]*>);', lambda m: f"{m.group(1)}[{hex_bytes}];", fdt_body, count=1)
assert n_data == 1, "未在 FIT fdt 节点中找到 data 属性"

crc_val = zlib.crc32(new_dtb) & 0xFFFFFFFF

def patch_hash(m):
    blk = m.group(0)
    m_algo = re.search(r'algo\s*=\s*"([^"]+)"', blk)
    assert m_algo, f"未知 FIT hash 节点: {blk}"
    algo = m_algo.group(1)
    if algo == "crc32":
        raw = struct.pack(">I", crc_val)
    elif algo in ("sha1", "sha256", "md5"):
        raw = getattr(hashlib, algo)(new_dtb).digest()
    else:
        raise AssertionError(f"不支持的 FIT hash 算法: {algo}")

    if re.search(r'value\s*=\s*\[', blk):
        v_hex = " ".join(f"{b:02x}" for b in raw)
        return re.sub(r'(value\s*=\s*)\[[^\]]*\];', rf'\g<1>[{v_hex}];', blk)
    v_cells = " ".join(f"0x{w:08x}" for w in struct.unpack(f">{len(raw)//4}I", raw))
    return re.sub(r'(value\s*=\s*)<[^>]*>;', rf'\g<1><{v_cells}>;', blk)

fdt_body = re.sub(r'\bhash[-@]\d+\s*\{[^}]*\};', patch_hash, fdt_body, flags=re.S)
itb_dts = itb_dts[:m_fdt.start(2)] + fdt_body + itb_dts[m_fdt.end(2):]
itb_dts_path.write_text(itb_dts, encoding="utf-8")
subprocess.run([dtc_bin, "-q", "-I", "dts", "-O", "dtb", "-o", str(itb_path), str(itb_dts_path)], check=True)
itb_dts_path.unlink(missing_ok=True)

new_itb = itb_path.read_bytes()
assert new_dtb in new_itb, "FIT .itb 未包含修补后的 DTB"
print(f"[cm520] Patched DTB & FIT ITB for OpBoot ({itb_path.name}, crc32=0x{crc_val:08x})")
PYEOF
