#pragma once
/*
 * Per-board hardware constants for the boot shim.
 *
 * Select the target with -DBOARD_OXYGEN or -DBOARD_SANTONI (default SANTONI).
 * Everything not listed here is identical across the two phones (same SoC
 * family: SDCC at 0x7824000/0x7824900, QGIC2 at 0xb000000, APPS watchdog at
 * 0xb017000, GCC at 0x1800000, boot cluster1 core0 MPIDR 0x100).
 */

#if defined(BOARD_OXYGEN)

/*
 * Xiaomi Mi Max 2 "oxygen" (MSM8953).
 *
 * Framebuffer: 1080x1920 continuous splash at 0x90001000. The stock DTB's
 * panel nodes say qcom,mdss-dsi-bpp = 0x18 (24 bpp), and the first 32bpp
 * shim boot came up white/garbled: the buffer ABL keeps scanning is packed
 * BGR24, not BGRA32. Android's later fb0 is 32bpp but that is the mdss
 * driver's own buffer, not the continuous-splash window. If the panel turns
 * out to be 32bpp after all, set FB_BPP 4 and FB_STRIDE (1080*4).
 */
#	define FB_BASE		0x90001000UL
#	define FB_W			1080
#	define FB_H			1920
#	define FB_BPP		3		/* bytes per pixel, BGR24 */
#	define FB_STRIDE	(FB_W * FB_BPP)

/* Kernel-managed RAM: above every Qualcomm carve-out incl. the live splash.
 * Free gap 0x91400000 .. 0xb0000000 (492 MiB) before ramoops@0xb0000000. */
#	define PHYS_BASE	0x91400000UL
#	define MEM_SIZE		0x1ec00000UL	/* 492 MiB safe budget */

#else /* BOARD_SANTONI (default) */

/* Xiaomi Redmi 4X "santoni" (MSM8937). */
#	define FB_BASE		0x90001000UL
#	define FB_W			720
#	define FB_H			1280
#	define FB_BPP		3		/* BGR24 */
#	define FB_STRIDE	(FB_W * FB_BPP)

#	define PHYS_BASE	0x98000000UL
#	define MEM_SIZE		0x28000000UL	/* 640 MiB safe budget */

#endif
