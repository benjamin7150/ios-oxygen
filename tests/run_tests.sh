#!/bin/bash
# Host tests + patch validation for the Santoni bring-up.
#
# Called by shim/build.sh (and the xnu workflow) so that the three phase 4
# host tests and the unified-diff structure of the Santoni patches are checked
# on every build. Everything here is host-only: no device, no XNU tree.
#
#   tests/run_tests.sh            # normal run, binaries in out/
#   OUT_DIR=/tmp/t tests/run_tests.sh
#
# Exit status is non-zero if a test fails, a patch has a malformed hunk, or a
# requirement asserted below is missing from the code that the patch ships.
set -euo pipefail

cd "$(dirname "$0")/.."

CC="${HOST_CC:-${CC:-clang}}"
OUT="${OUT_DIR:-out}"
mkdir -p "$OUT"

P142="xnu/patches/0142-santoni-sdhci-emmc-driver.patch"
P143="xnu/patches/0143-santoni-persistent-console-log.patch"
P144="xnu/patches/0144-santoni-4k-unsigned-dyld-cache.patch"
P145="xnu/patches/0145-oxygen-board-target.patch"
P146="xnu/patches/0146-iig-kernelcontent.patch"
P147="xnu/patches/0147-oxygen-sweet-boot-cpu.patch"
P148="xnu/patches/0148-sweet-hfs-sysctl-macros.patch"
P155="xnu/patches/0155-santoni-sdhci-bounce-race.patch"
P156="xnu/patches/0156-sweet-boot-rm-corrupt-db.patch"

echo "== host unit tests (-Wall -Wextra) =="
for t in test_sdhci_mock test_gpt_parser test_log_ring; do
	"$CC" -O2 -Wall -Wextra -I. "tests/$t.c" -o "$OUT/$t"
	case "$OUT" in
		/*) "$OUT/$t" ;;
		*)  "./$OUT/$t" ;;
	esac
done

echo "== unified diff structure (all xnu/patches) =="
python3 tools/check_patch.py xnu/patches/*.patch > "$OUT/check_patch.log"
tail -3 "$OUT/check_patch.log"

echo "== STOR-03: GPT CRC32 + SYSTEM parse + fenced log writes (0142) =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:0xEDB88320u' \
	--added-contains 'bsd/dev/santoni_sdhci.c:santoni_crc32(hdr_raw, hdr.header_size)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:santoni_crc32(b, entry_bytes)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:uint64_t sys_first_block, sys_nblocks;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:strcmp(name, "system")' \
	--added-contains 'bsd/dev/santoni_sdhci.c:SANTONI_LOG_SYSTEM_BLOCKS 8193u' \
	--added-contains 'bsd/dev/santoni_sdhci.c:int santoni_sdhci_write_log_blocks(' \
	--added-contains 'bsd/dev/santoni_sdhci.c:lba < se.sys_first_block' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = sdhci_write_pio((uint32_t)lba, count, buf);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:su.dma'
echo "ok   0142 ships CRC32, system partition and the 8193-sector log fence"

echo "== STOR-04: log flusher on SYSTEM, no Sweet userdata ring (0143) =="
python3 tools/check_patch.py "$P143" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:santoni_log_start();' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = santoni_sdhci_write_log_blocks(base + 1 + blk,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = santoni_sdhci_write_log_blocks(base, 1, bounce);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:PE_parse_boot_argn("sweetlog", &on, sizeof(on));' \
	--added-contains 'osfmk/console/serial_console.c:santoni_log_append(c, size);' \
	--added-contains 'osfmk/console/serial_console.c:#if !defined(ARM64_BOARD_CONFIG_SANTONI)' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:base = sys.first_block;' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:se.dma' \
	--added-lacks 'osfmk/console/serial_console.c:sweet_log_append(c, size);'
echo "ok   0143 routes Santoni to SYSTEM and not to sweet_log_append"

echo "== STOR-05: 4 KiB pages with a 16 KiB-signed dyld cache (0144) =="
python3 tools/check_patch.py "$P144" -q \
	--added-contains 'bsd/kern/ubc_subr.c:cd->pageSize != 14' \
	--added-contains 'bsd/kern/ubc_subr.c:cd->pageSize > PAGE_SHIFT' \
	--added-contains 'osfmk/vm/vm_shared_region.c:vm_map_cs_enforcement_set(vm_shared_region_vm_map(shared_region), false);'
echo "ok   0144 allows pageSize 14, skips 16 KiB hashing, disables CS enforcement"

echo "== STOR-06: SDHCI consensus fixes (CMD12-after-BLK_CNT_EN, DATA_INHIBIT, ==="
echo "==          recover, R2 CRC strip, SEC_COUNT fence, idempotent probe,     =="
echo "==          HC-mode takeover from LK's legacy MCI mode)                  =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_poll_state(SDHCI_CMD_INHIBIT | SDHCI_DATA_INHIBIT,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_recover(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_rd(SDHCI_RESPONSE + 4 * (3 - i))' \
	--added-contains 'bsd/dev/santoni_sdhci.c:se.sec_count = sec_count;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:lba + (uint64_t)count > se.sec_count' \
	--added-contains 'bsd/dev/santoni_sdhci.c:static bool attempted;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:int init_error;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_core_check(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define SDHCI_CTRL_8BITBUS' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_enter_hc_mode(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:core_wr(CORE_HC_MODE, (hc_mode & ~CORE_HC_MODE_EN) | CORE_HC_MODE_EN);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:core_wr(CORE_HC_MODE, hc_mode | CORE_HC_MODE_EN | CORE_FF_CLK_SW_RST_DIS);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:HC_MODE_EN reads back 0' \
	--added-contains 'bsd/dev/santoni_sdhci.c:FF_CLK_SW_RST_DIS did not stick' \
	--added-contains 'bsd/dev/santoni_sdhci.c:card clock gate was closed' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr(SDHCI_INT_ENABLE, 0xffffffffu);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:core not in HC mode' \
	--added-contains 'iokit/bsddev/IOKitBSDInit.cpp:santoni_sdhci_probe();' \
	--added-contains 'iokit/bsddev/IOKitBSDInit.cpp:IOLog("SANTONI: eMMC probe failed' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:return sdhci_stop_transmission();'
echo "ok   0142 fixes DATA_INHIBIT, CMD12/recover, R2 order, SEC_COUNT and probe"
python3 tools/check_patch.py "$P143" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:uint32_t on = 0;' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:uint32_t on = 1;'
echo "ok   0143 defaults the console log OFF (sweetlog=1 enables it)"

echo "== STOR-07: addressed commands carry LK's RCA, R2 is CRC-stripped, and  =="
echo "==          the RCA ladder diagnoses itself (VENDOR_SPEC, CMD5, CMD0)   =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define SANTONI_CARD_RCA' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_send_status(uint32_t rca, uint32_t *r1)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_cmd(13, rca << 16, 0,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_read_response128(9, se.rca << 16, csd)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:out[i] = (lo << 8) | (hi >> 24);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr(CORE_VENDOR_SPEC, CORE_VENDOR_SPEC_BOARD_VAL);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_sleep_awake(uint32_t rca, uint32_t *r1)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_restore_state(uint32_t *r1)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_restore_controller(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr16(SDHCI_HOST_CONTROL2, handoff_hc2);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:hc_wr(CORE_VENDOR_SPEC, CORE_VENDOR_SPEC_POR_VAL);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:CMD0 did not complete either: no SDCLK' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:core_wr(CORE_VENDOR_SPEC' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:sdhci_cmd(13, 0, 0,' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:sdhci_read_response128(10,' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:card is not in transfer state'
echo "ok   0142 addresses CMD13/CMD9 with RCA and removes illegal TRAN-state CMD10"

echo "== STOR-08: HC datapath clock - vendor MCLK select, DLL CK_OUT_EN,    =="
echo "==          and status-enable all ones for the polled loop (0142)      =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define CORE_DLL_CONFIG         0x100' \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define CORE_CK_OUT_EN          0x00040000u' \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define CORE_DLL_OFF            (CORE_DLL_RST | CORE_DLL_PDN)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr(CORE_VENDOR_SPEC, CORE_VENDOR_SPEC_BOARD_VAL);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_select_hc_clock(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:vs |= CORE_HC_MCLK_SEL_DFLT;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_clock_output(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:bool dll_live = (dll & CORE_DLL_EN) && !(dll & CORE_DLL_OFF) &&' \
	--added-contains 'bsd/dev/santoni_sdhci.c:CORE_DLL_CONFIG 0x%08x CORE_DLL_STATUS 0x%08x' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr(SDHCI_SIGNAL_ENABLE, 0);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:card clock gate did not' \
	--added-contains 'bsd/dev/santoni_sdhci.c:hc_wr16(SDHCI_CLOCK_CONTROL, SDHCI_CLOCK_INT_EN);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:SDHCI_CLOCK_DIV' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:core_wr(CORE_VENDOR_SPEC' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:hc_wr(SDHCI_INT_ENABLE, 0);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:core_wr(CORE_HC_MODE, hc_mode | want);'
echo "ok   0142 clocks the HC datapath, follows the DLL and enables status"

echo "== STOR-09: card clock comes from GCC sdcc1_apps_clk_src, not the    =="
echo "==          ignored SDHCI divider (mapped RCG page, M/N/D, UPDATE)     =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define GCC_SDCC1_APPS_PHYS      0x01842000u' \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define GCC_SDCC1_APPS_CMD_RCGR  0x004u' \
	--added-contains 'bsd/dev/santoni_sdhci.c:se.gcc = ml_io_map(GCC_SDCC1_APPS_PHYS, GCC_SDCC1_APPS_SIZE);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_gcc_set_apps(const struct santoni_gcc_rate *r)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:gcc_wr(GCC_SDCC1_APPS_M, r->m);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:gcc_wr(GCC_SDCC1_APPS_N, r->n);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:gcc_wr(GCC_SDCC1_APPS_D, r->d);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:cfg &= ~(GCC_CFG_DIV_MASK | GCC_CFG_SEL_MASK | GCC_CFG_MODE_MASK);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:gcc_wr(GCC_SDCC1_APPS_CMD_RCGR, cmd | GCC_CMD_UPDATE);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:{ "400 kHz", 0x01u, 0xfcu, 0xfbu, 0x2017u },' \
	--added-contains 'bsd/dev/santoni_sdhci.c:{ "25 MHz",  0x01u, 0xfeu, 0xfdu, 0x211fu },' \
	--added-contains 'bsd/dev/santoni_sdhci.c:absolutetime_to_nanoseconds(mach_absolute_time() - start, &ns);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:CMD0 -> error %d, %llu ns' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:gcc_wr(GCC_SDCC1_APPS_CBCR' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:SDHCI_DIVIDER_400KHZ'
echo "ok   0142 programs the GCC RCG and keeps the branch/AHB gates untouched"

echo "== STOR-10: 400 kHz uses UHS=0 feedback clock, 1-bit bus, DLL off;   =="
echo "==          CMD13/CMD5 precede CMD0 and CMD1 polls only while busy    =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define SDHCI_CTRL_UHS_MASK' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_snapshot_untouched(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_snapshot_standard(const char *tag)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_set_legacy_host(const char *why)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:new_hc2 = (uint16_t)(hc2 & ~SDHCI_CTRL_UHS_MASK);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:SDHCI_CTRL_DMA_MASK |' \
	--added-contains 'bsd/dev/santoni_sdhci.c:(dll | CORE_DLL_RST | CORE_DLL_PDN) &' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_cmd1_poll(uint32_t *ocr)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:if (*ocr & 0x80000000u)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:command timeout is not "busy"' \
	--added-contains 'bsd/dev/santoni_sdhci.c:probe step 2: CMD5 awake RCA 2' \
	--added-contains 'bsd/dev/santoni_sdhci.c:GO_PRE_IDLE retry' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_set_legacy_host("rung 3 controller restore");' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:hc_wr(CORE_VENDOR_SPEC, CORE_VENDOR_SPEC_HS400_DIV2_VAL);'
echo "ok   0142 uses the low-speed feedback path and a bounded CMD1 poll"

echo "== STOR-11: CMD2/CMD3/CMD9/CMD7/CMD8 enumeration and 25 MHz 8-bit HS =="
echo "==          switch; R2 has no index check and CMD6 waits for DAT0        =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_read_response128(uint8_t index, uint32_t arg, uint32_t out[4])' \
	--added-contains 'bsd/dev/santoni_sdhci.c:SDHCI_CMD_RESP_LONG | SDHCI_CMD_CRC, NULL);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_enumerate_card(void)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_read_response128(2, 0, cid)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_cmd(3, SANTONI_CARD_RCA << 16, 0,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_read_response128(9, se.rca << 16, csd)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_select_card(se.rca)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_read_pio(8, 0, 1, (void *)(se.dma + DMA_BOUNCE))' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_gcc_set_apps(&santoni_gcc_rates[SANTONI_GCC_RATE_25M])' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_switch_ext_csd(EXT_CSD_BUS_WIDTH,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:EXT_CSD_BUS_WIDTH_8, SDHCI_CTRL_8BITBUS, SDHCI_CTRL_BUS_MASK,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_switch_ext_csd(EXT_CSD_HS_TIMING,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:EXT_CSD_TIMING_HS, SDHCI_CTRL_HISPD, 0, "HS_TIMING=1")' \
	--added-contains 'bsd/dev/santoni_sdhci.c:SDHCI_DATA_0_LVL_MASK' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_wait_card_ready(uint32_t rca, const char *what)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define SDHCI_R1_SWITCH_ERROR' \
	--added-contains 'bsd/dev/santoni_sdhci.c:if (r1 & SDHCI_R1_SWITCH_ERROR) {' \
	--added-contains 'bsd/dev/santoni_sdhci.c:se.enumerated = true;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = sdhci_enumerate_card();' \
	--added-contains 'bsd/dev/santoni_sdhci.c:if (se.enumerated) {' \
	--added-contains 'bsd/dev/santoni_sdhci.c:not downgrading the card bus' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:SDHCI_CMD_RESP_LONG | SDHCI_CMD_CRC | SDHCI_CMD_INDEX'
echo "ok   0142 enumerates READY->TRAN, reads EXT_CSD 1-bit, then switches 25 MHz/8-bit/HS"

echo "== STOR-12: CMD17 single-block, CMD18/25 AUTO_CMD12, and 8-bit bus verification (0142) =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:#define SDHCI_TRNS_AUTO_CMD12   0x0004' \
	--added-contains 'bsd/dev/santoni_sdhci.c:SDHCI_TRNS_AUTO_CMD12' \
	--added-contains 'bsd/dev/santoni_sdhci.c:sdhci_verify_highspeed_bus(uint32_t expected_sec_count)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = sdhci_verify_highspeed_bus(se.sec_count);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:return sdhci_read_pio(count == 1 ? 17 : 18, (uint32_t)lba, count, buf);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:sdhci_card_check(void)'
echo "ok   0142 uses CMD17 for 1 block, AUTO_CMD12 for multi-block, and verifies 8-bit bus"

echo "== STOR-13: cdev I/O uses uiomove, not physio/user-VA memcpy; B_PHYS ==="
echo "==          strategy buffers use copyin/copyout (0142)                  =="
python3 tools/check_patch.py "$P142" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:santoni_sdhci_uio(struct uio *uio, bool rd)' \
	--added-contains 'bsd/dev/santoni_sdhci.c:return santoni_sdhci_uio(uio, true);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:kmem_alloc(kernel_map, &bounce, bsize, KMA_DATA,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = uiomove(buf + skip, (int)want, uio);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:!santoni_kernel_address(vaddr);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = copyout(bounce + skip,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:error = copyin((user_addr_t)(vaddr + done),' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:return physio('
echo "ok   0142 never hands a user VA to memcpy and keeps the cdev lock off uiomove"

echo "== OXY-01: oxygen is a santoni sibling with a 1080x1920 BGR24 panel (0145) =="
python3 tools/check_patch.py "$P145" -q \
	--added-contains 'pexpert/pexpert/arm64/OXYGEN.h:#define OXYGEN                        1' \
	--added-contains 'pexpert/pexpert/arm64/OXYGEN.h:#define SANTONI                       1' \
	--added-contains 'pexpert/pexpert/arm64/board_config.h:#ifdef ARM64_BOARD_CONFIG_OXYGEN' \
	--added-contains 'makedefs/MakeInc.def:MACHINE_FLAGS_ARM64_OXYGEN = -DARM64_BOARD_CONFIG_OXYGEN -DARM64_BOARD_CONFIG_SWEET' \
	--added-contains 'config/MASTER.arm64.oxygen:# oxygen (Xiaomi Mi Max 2, MSM8953)' \
	--added-contains 'osfmk/arm64/start.s:Stage 0: white first 32 rows of the 1080x1920 BGR24 panel' \
	--added-contains 'osfmk/arm64/sweet_early.c:#define EARLY_W 1080u' \
	--added-contains 'osfmk/arm64/sweet_early.c:#define EARLY_H 1920u' \
	--added-contains 'osfmk/arm64/sweet_early.c:#define EARLY_STRIDE 3240u' \
	--added-contains 'osfmk/arm64/arm_vm_init.c:0x90000000ULL + (uint64_t)i * ARM_TT_L2_SIZE' \
	--added-contains 'osfmk/console/serial_console.c:#if defined(ARM64_BOARD_CONFIG_SANTONI) || defined(ARM64_BOARD_CONFIG_OXYGEN)'
echo "ok   0145 adds the OXYGEN target, 1080x1920 BGR24 early console and four-block NC alias"

echo "== OXY-02: oxygen runs the SWEET source-staging scripts (0019/0020/0026) =="
for s in xnu/patches/0019-stage-libpthread.sh \
         xnu/patches/0020-stage-bearssl.sh \
         xnu/patches/0026-stage-hfs.sh; do
	if ! grep -q 'OXYGEN' "$s"; then
		echo "error: $s does not run for OXYGEN" >&2
		exit 1
	fi
done
python3 tools/check_patch.py xnu/patches/0019-sweet-builtin-pthread.patch -q \
	--added-contains 'bsd/conf/Makefile.template:ifneq ($(filter SWEET SANTONI OXYGEN,$(CURRENT_MACHINE_CONFIG)),)'
python3 tools/check_patch.py xnu/patches/0020-sweet-portable-aes-cbc.patch -q \
	--added-contains 'libkern/conf/Makefile.template:ifneq ($(filter SWEET SANTONI OXYGEN,$(CURRENT_MACHINE_CONFIG)),)'
python3 tools/check_patch.py xnu/patches/0026-sweet-builtin-hfs.patch -q \
	--added-contains 'bsd/conf/Makefile.template:-include $(SWEET_HFS_ROOT)/sweet_hfs_compat.h' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#include <sys/vnode_internal.h>' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#include <libkern/sysctl.h>'
echo "ok   0019/0020/0026 stage libpthread, BearSSL and HFS for oxygen"
echo "ok   the Makefile gates enable their include paths for OXYGEN"

echo "== OXY-03: the shim ADT walker marks the live boot CPU (0x100 and 0x0) =="
for boot_phys in 0x100 0x0; do
	bin="$OUT/loader_test_${boot_phys#0x}"
	"$CC" -O2 -Wall -Wextra -Ishim -DBOARD_OXYGEN \
		-DLOADER_TEST_BOOT_PHYS="$boot_phys" \
		shim/loader_test.c shim/loader.c -o "$bin"
	case "$bin" in
		/*) "$bin" ;;
		*)  "./$bin" ;;
	esac
done
echo "ok   the shim changes only the executing CPU's /cpus state"

echo "== OXY-04: oxygen's SweetCPU boot-core check uses MPIDR 0x0 (0147) =="
python3 tools/check_patch.py "$P147" -q \
	--added-contains 'iokit/Kernel/arm/SweetCPU.cpp:#if defined(ARM64_BOARD_CONFIG_OXYGEN)' \
	--added-contains 'iokit/Kernel/arm/SweetCPU.cpp:const uint32_t expected_boot_phys = 0x0;' \
	--added-contains 'iokit/Kernel/arm/SweetCPU.cpp:expected_boot_phys, topology->boot_cpu->phys_id'
echo "ok   0147 accepts the ABL boot core 0x0 only for OXYGEN"

echo "== OXY-05: built-in HFS keeps public, manually registered sysctls (0148) =="
python3 tools/check_patch.py "$P148" -q \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#undef SYSCTL_OID' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#undef SYSCTL_NODE' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#define SYSCTL_OID(parent, nbr, name, kind, a1, a2, handler, fmt, descr)' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:#define SYSCTL_NODE(parent, nbr, name, access, handler, descr)' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:CTLFLAG_PERMANENT' \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_compat.h:hfs_sysctl_register()'
python3 tools/check_patch.py xnu/patches/0026-sweet-builtin-hfs.patch -q \
	--added-contains 'bsd/sweet_hfs/sweet_hfs_iokit.c:hfs_sysctl_register();'
echo "ok   0148 restores non-permanent OIDs for HFS's late explicit registration"

echo "== OXY-06: strategy() keeps the shared bounce under the lock across  =="
echo "==          PIO + memcpy, and user buffers get a private bounce (0155) =="
python3 tools/check_patch.py "$P155" -q \
	--added-contains 'bsd/dev/santoni_sdhci.c:vm_offset_t user_bounce = 0;' \
	--added-contains 'bsd/dev/santoni_sdhci.c:user_bounce_size = roundup(user_bounce_size, SDHCI_BLOCK);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:kmem_alloc(kernel_map, &user_bounce, user_bounce_size,' \
	--added-contains 'bsd/dev/santoni_sdhci.c:char *bounce = user ? (char *)user_bounce :' \
	--added-contains 'bsd/dev/santoni_sdhci.c:if (!error && !user) {' \
	--added-contains 'bsd/dev/santoni_sdhci.c:memcpy(vaddr + done, bounce + skip, want);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:memcpy(bounce + skip, vaddr + done, want);' \
	--added-contains 'bsd/dev/santoni_sdhci.c:kmem_free(kernel_map, user_bounce, user_bounce_size);' \
	--added-lacks 'bsd/dev/santoni_sdhci.c:char *bounce = (char *)(se.dma + DMA_BOUNCE);'
echo "ok   0155 serializes shared-bounce PIO+copy and isolates user copyin/copyout"

echo "== OXY-07: sweetrm= unlinks boot-arg paths once, before launchd (0156) =="
python3 tools/check_patch.py "$P156" -q \
	--added-contains 'bsd/kern/bsd_init.c:#include <sys/uio.h>' \
	--added-contains 'bsd/kern/bsd_init.c:PE_parse_boot_argn("sweetrm", list, sizeof(list))' \
	--added-contains 'bsd/kern/bsd_init.c:error = unlink1(vfs_context_kernel(), NULLVP,' \
	--added-contains 'bsd/kern/bsd_init.c:CAST_USER_ADDR_T(path), UIO_SYSSPACE, 0);' \
	--added-contains 'bsd/kern/bsd_init.c:printf("SWEET CLEANUP: unlink %s -> %d\n", path, error);' \
	--added-contains 'bsd/kern/bsd_init.c:sweet_boot_remove_files();'
python3 - "$P156" <<'PY'
import sys
patch = open(sys.argv[1], encoding="utf-8").read()
seq = "+\tsweet_boot_remove_files();\n+\n \tload_init_program(p);"
if seq not in patch:
    sys.exit("0156: sweet_boot_remove_files() is not immediately before load_init_program()")
PY
echo "ok   0156 unlinks comma-separated sweetrm paths in the kernel context before init"

echo "== CI-01: Xcode 16 iig expects the kernel-side IORPC.kernelContent field (0146) =="
python3 tools/check_patch.py "$P146" -q \
	--added-contains 'iokit/IOKit/IORPC.h:#ifdef KERNEL' \
	--added-contains 'iokit/IOKit/IORPC.h:IORPCMessage     * kernelContent;'
echo "ok   0146 adds IORPC.kernelContent for Xcode 16 iig builds"

# Optional deep check: if a patched XNU source tree is provided, the patches
# must also apply to it as-is (git apply --check).
if [ -n "${XNU_SRC:-}" ]; then
	echo "== git apply --check against XNU_SRC=$XNU_SRC =="
	(cd "$XNU_SRC" && git apply --check \
	    "$OLDPWD/$P142" "$OLDPWD/$P143" "$OLDPWD/$P144" "$OLDPWD/$P145" \
	    "$OLDPWD/$P146" "$OLDPWD/$P147")
	echo "ok   all six patches apply to $XNU_SRC"
fi

echo "run_tests: all hosts tests, patch checks and shipped-code assertions passed"
