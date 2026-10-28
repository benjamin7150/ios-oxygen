#!/bin/bash
# Build the freestanding shim and wrap it in an Android boot.img v0.
#
# Usage:  build.sh [payload] [--board santoni|oxygen]
#   santoni (default): Redmi 4X, MSM8937.
#   oxygen:            Mi Max 2, MSM8953 (1080x1920 BGR24 FB, 4 GiB, iPhone 8+ identity).
set -euo pipefail

BOARD="santoni"
PAYLOAD=""
while [ $# -gt 0 ]; do
	case "$1" in
		--board) BOARD="$2"; shift 2 ;;
		*) PAYLOAD="$1"; shift ;;
	esac
done
[ -n "$PAYLOAD" ] && [ -f "$PAYLOAD" ] && PAYLOAD="$(realpath "$PAYLOAD")"

case "$BOARD" in
	santoni|oxygen) ;;
	*) echo "unknown --board $BOARD" >&2; exit 1 ;;
esac
BOARD_DEF="-DBOARD_$(printf '%s' "$BOARD" | tr 'a-z' 'A-Z')"

cd "$(dirname "$0")"

CC="${CC:-clang}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"
READELF="${READELF:-llvm-readelf}"
NM="${NM:-llvm-nm}"
LD="${LD:-ld.lld}"
HOST_CC="${HOST_CC:-clang}"

CFLAGS="-target aarch64-linux-gnu -O2 -ffreestanding -nostdlib -fno-pic -fno-jump-tables -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra $BOARD_DEF"

mkdir -p out

for f in start.S shim.c console.c mmu.c fdt.c loader.c gic.c timer.c wdt.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done

# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/gic.o out/timer.o out/wdt.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }

$LD -T shim.ld --build-id=none -N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/gic.o out/timer.o out/wdt.o -o out/shim.elf

$OBJCOPY -O binary out/shim.elf out/Image

# Pad to image_size so .bss/stacks exist as zeroed bytes.
size=$((16#$($NM out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image

# Build static Mach-O PID 1 init test program
echo "Building static Mach-O PID 1 init (santoni-init.S)..."
$CC -target arm64-apple-ios16.0 -c ../tools/santoni-init.S -o out/santoni-init.o
python3 ../tools/mkinit.py out/santoni-init.o out/init.macho

# Board-tagged kernel command line (the tag identifies the image in logs; the
# kernel target itself is selected at compile time by MACHINE_CONFIG).
CMDLINE="debug=0x14e serial=3 disable_kprintf_output=0 -enable_kprintf_spam sweetfb_native=1 sweetcpufreq=0 sweetbattery=0 rd=md0 -v keepsyms=1 $BOARD"
# The iPhone 8 Plus donor has the same 1080x1920 panel as oxygen: present the
# native resolution as the UI canvas (1:1 mapping) instead of the iPhone X
# 1125x2436 canvas that santoni uses.
ADT_NATIVE=""
[ "$BOARD" = oxygen ] && ADT_NATIVE="--native"

# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio -> diagnostics.
RAMDISK="out/ramdisk.bin"
if [ -n "$PAYLOAD" ]; then
	magic=$(python3 -c "import sys; f=open(sys.argv[1],'rb'); b=f.read(4); print(b.hex())" "$PAYLOAD" 2>/dev/null || true)
	if [ "$magic" = "cffaedfe" ] || [ "$magic" = "feedfacf" ]; then
		echo "Detected raw Mach-O kernel ($PAYLOAD). Generating $BOARD ADT and packing with mkpayload.py..."
		python3 ../tools/mkadt.py "out/$BOARD.adt" --board "$BOARD" $ADT_NATIVE
		python3 ../tools/mkpayload.py "$PAYLOAD" "out/$BOARD.adt" out/payload.bin --cmdline "$CMDLINE" --ramdisk out/init.macho
		RAMDISK="out/payload.bin"
	else
		RAMDISK="$PAYLOAD"
	fi
else
	if command -v cpio >/dev/null 2>&1; then
		(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
	else
		python3 -c 'import gzip; h=b"07070100000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000b00000000TRAILER!!!\0\0\0\0"; open("out/ramdisk.bin","wb").write(gzip.compress(h + b"\0"*(512-len(h)), compresslevel=9))'
	fi
fi

# Append the board's Qualcomm device tree table so Qualcomm LK finds a matching
# DTB at kernel_addr + image_size.  santoni used a 29-DTB table; oxygen uses its
# own FDT pulled from the live device.
DTB_BLOB="../resources/${BOARD}_appended_dtbs.bin"
if [ ! -f "$DTB_BLOB" ] && [ "$BOARD" = oxygen ] && [ -f ../oxygen.dtb ]; then
	DTB_BLOB="../oxygen.dtb"
fi
if [ -f "$DTB_BLOB" ]; then
	cat "$DTB_BLOB" >> out/Image
fi

# Packaging: wrap in boot.img v0 using tools/mkbootimg.py
python3 ../tools/mkbootimg.py \
	--kernel out/Image \
	--ramdisk "$RAMDISK" \
	--output out/shim-boot.img \
	--base 0x80000000 \
	--pagesize 2048 \
	--header_version 0 \
	--cmdline "$CMDLINE"

# Host render of the console layout
$HOST_CC -O2 -Wall -I. $BOARD_DEF -o out/host_test console.c host_test.c && ./out/host_test

# Host unit test for GICv2 MMIO lifecycle
$HOST_CC -O2 -Wall -I. $BOARD_DEF -o out/gic_test gic_test.c && ./out/gic_test

# Host unit test for Mach-O segment unroller and boot_args
$HOST_CC -O2 -Wall -I. $BOARD_DEF -o out/loader_test loader_test.c loader.c && ./out/loader_test

# Phase 4 storage: SDHCI register mock, hardened GPT (CRC32 + SYSTEM log
# fence) and console log ring, plus unified-diff structure of xnu/patches.
# Fails the build if any of them regress or a Santoni patch is malformed.
HOST_CC="$HOST_CC" OUT_DIR="$PWD/out" bash ../tests/run_tests.sh

ls -l out/Image out/shim-boot.img
