#!/bin/sh
# Read the SWEET / SANTONI console log (kernel patches 0047 / 0143) from a phone
# booted into recovery (fastboot boot recovery/recovery.img; adb root shell).
#   tools/sweet-log-pull.sh OUT.txt
#
# Santoni: pulls 8193 blocks (512B) from the dedicated idle SYSTEM partition.
# Sweet: pulls the last 1025 blocks (4 KiB) of the USERDATA partition.
set -eu
out=${1:?usage: sweet-log-pull.sh OUT.txt}
# Keep the partition name next to the resolved device: readlink -f turns
# by-name/system into /dev/block/mmcblk0p65, so grepping the path for "system"
# used to fall through to the userdata-tail branch and read the wrong range.
sel=$(adb shell 'for n in system userdata; do for d in /dev/block/bootdevice/by-name/$n /dev/block/by-name/$n; do [ -e $d ] && { echo "$n $(readlink -f $d)"; exit 0; }; done; done' | tr -d '\r')
[ -n "$sel" ] || { echo "system or userdata block device not found" >&2; exit 1; }
name=${sel%% *}
dev=${sel#* }

case "$name" in
system)
    echo "Found SYSTEM partition ($dev): pulling 8193 blocks (4 MiB + 512B header)..." >&2
    adb exec-out "dd if=$dev bs=512 count=8193 2>/dev/null" > "$out.bin"
    echo "$dev: read 8193 blocks ($(stat -c %s "$out.bin") bytes)" >&2
    ;;
userdata)
    bytes=$(adb shell blockdev --getsize64 "$dev" | tr -d '\r')
    skip=$((bytes / 4096 - 1025))
    adb exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$out.bin"
    echo "$dev: $bytes bytes, read blocks $skip.. ($(stat -c %s "$out.bin") bytes)" >&2
    ;;
*)
    echo "unexpected partition selection: $sel" >&2
    exit 1
    ;;
esac

python3 "$(dirname "$0")/sweet-log.py" "$out.bin" "$out"
