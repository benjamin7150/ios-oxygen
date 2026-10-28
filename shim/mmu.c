/*
 * Cortex-A53 Stage-1 MMU driver for MSM8937 (santoni):
 * 4 KiB translation granule (TCR_EL1.TG0 = 0b00, PAGE_SHIFT = 12, 36-bit IPS and VA).
 *
 * T0SZ=28 gives a 36-bit VA whose walk starts at Level 1:
 *   - Level 1: 512 x 1 GiB descriptors (first 64 entries cover 64 GiB)
 *   - Level 2: 512 x 2 MiB descriptors for DRAM Bank 0 (0x80000000 - 0xBFFFFFFF)
 *   - Level 3: 512 x 4 KiB descriptors for the shim image block
 *
 * Qualcomm XPUs fault on speculative reads of protected carve-outs (TZ, SMEM, modem...),
 * so everything is mapped Device-nGnRnE by default except:
 *   - shim image pages (Normal WB RW-alloc)
 *   - splash framebuffer blocks at 0x90000000 (Normal Non-cacheable)
 */
#include <stdint.h>
#include "mmu.h"

#define PG_SHIFT	12
#define PG_SIZE		(1UL << PG_SHIFT)		/* 4 KiB */
#define L2_BLK_SHIFT	21
#define L2_BLK_SIZE	(1UL << L2_BLK_SHIFT)		/* 2 MiB level-2 block */
#define L1_BLK_SHIFT	30
#define L1_BLK_SIZE	(1UL << L1_BLK_SHIFT)		/* 1 GiB level-1 block */
#define NENT		512

#define ATTR_DEV	0	/* MAIR attr0 = 0x00 Device-nGnRnE */
#define ATTR_WB		1	/* MAIR attr1 = 0xff Normal WB RW-alloc */
#define ATTR_NC		2	/* MAIR attr2 = 0x44 Normal non-cacheable */
#define MAIR_VAL	0x44ff00UL

#define D_BLOCK		1UL
#define D_TABLE		3UL
#define D_PAGE		3UL
#define D_ATTR(i)	((uint64_t)(i) << 2)
#define D_SH_OUTER	(2UL << 8)
#define D_SH_INNER	(3UL << 8)
#define D_AF		(1UL << 10)
#define D_PXN		(1UL << 53)
#define D_UXN		(1UL << 54)

#define DEV_FLAGS	(D_ATTR(ATTR_DEV) | D_AF | D_PXN | D_UXN)
#define WB_FLAGS	(D_ATTR(ATTR_WB) | D_SH_INNER | D_AF | D_UXN)
#define NC_FLAGS	(D_ATTR(ATTR_NC) | D_SH_OUTER | D_AF | D_PXN | D_UXN)

/* TCR: T0SZ=28, IRGN0/ORGN0=WBWA, SH0=inner, TG0=4K (0b00), T1SZ=28, EPD1=1, TG1=4K (0b10), IPS=36-bit (0b001) */
#define TCR_VAL		(28UL | (1UL << 8) | (1UL << 10) | (3UL << 12) | (0UL << 14) | \
			 (28UL << 16) | (1UL << 23) | (2UL << 30) | (1UL << 32))

#define SCTLR_M		(1UL << 0)
#define SCTLR_A		(1UL << 1)
#define SCTLR_C		(1UL << 2)
#define SCTLR_I		(1UL << 12)
#define SCTLR_WXN	(1UL << 19)

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })
#define wsr(r, v) __asm__ volatile("msr " r ", %0" : : "r"((uint64_t)(v)))

extern char _head[], _end[];

/* 1 L1 (root) + 2 L2 (GiB 0 & GiB 2) + 2 L3 tables, 4 KiB aligned */
static uint64_t pt_pool[6 * NENT] __attribute__((aligned(4096)));

static void dcache_inval_range(uintptr_t start, uintptr_t end)
{
	uint64_t line = 4UL << ((rsr("ctr_el0") >> 16) & 0xf);

	for (uintptr_t a = start & ~(line - 1); a < end; a += line)
		__asm__ volatile("dc ivac, %0" : : "r"(a) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static void zero_table(uint64_t *t)
{
	for (int i = 0; i < NENT; i++)
		t[i] = 0;
}

int mmu_enable(struct mmu_info *info)
{
	uintptr_t img_lo = (uintptr_t)_head & ~(PG_SIZE - 1);
	uintptr_t img_hi = ((uintptr_t)_end + PG_SIZE - 1) & ~(PG_SIZE - 1);
	uintptr_t pool = (uintptr_t)pt_pool;

	uint64_t *l1   = (uint64_t *)(pool + 0 * PG_SIZE);
	uint64_t *l2_0 = (uint64_t *)(pool + 1 * PG_SIZE);
	uint64_t *l2_2 = (uint64_t *)(pool + 2 * PG_SIZE);
	int n_l3 = 0;

	info->img_lo = img_lo;
	info->img_hi = img_hi;
	info->ttbr = pool;

	/* Level 1: covers 64 GiB (first 64 entries used with 36-bit VA) */
	zero_table(l1);
	/* Entry 0: 0x00000000 - 0x3FFFFFFF (1 GiB, MMIO & DRAM Bank 0) -> L2 table */
	l1[0] = (uintptr_t)l2_0 | D_TABLE;
	/* Entry 1: 0x40000000 - 0x7FFFFFFF (1 GiB, MMIO) */
	l1[1] = 0x40000000UL | DEV_FLAGS | D_BLOCK;
	/* Entry 2: 0x80000000 - 0xBFFFFFFF (1 GiB, DRAM Bank 1 / Framebuffer) -> L2 table */
	l1[2] = (uintptr_t)l2_2 | D_TABLE;
	/* Entry 3: 0xC0000000 - 0xFFFFFFFF (1 GiB, DRAM Bank 2) */
	l1[3] = 0xC0000000UL | DEV_FLAGS | D_BLOCK;
	/* Entry 4: 0x100000000 - 0x13FFFFFFF (1 GiB, DRAM Bank 3) */
	l1[4] = 0x100000000UL | DEV_FLAGS | D_BLOCK;

	/* Level 2 (GiB 0): 512 x 2 MiB blocks covering 0x00000000 - 0x3FFFFFFF */
	zero_table(l2_0);
	for (uint64_t i = 0; i < NENT; i++) {
		uint64_t pa = i << L2_BLK_SHIFT;
		/* Lower 512 MiB is MMIO / GIC; upper 512 MiB (0x20000000 - 0x3FFFFFFF) is DRAM */
		uint64_t flags = (pa < 0x20000000UL) ? DEV_FLAGS : WB_FLAGS;
		l2_0[i] = pa | flags | D_BLOCK;
	}

	/* Level 2 (GiB 2): 512 x 2 MiB blocks covering 0x80000000 - 0xBFFFFFFF */
	zero_table(l2_2);
	for (uint64_t i = 0; i < NENT; i++) {
		uint64_t pa = 0x80000000UL + (i << L2_BLK_SHIFT);
		l2_2[i] = pa | DEV_FLAGS | D_BLOCK;
	}

	/*
	 * Framebuffer blocks: mark the splash window Normal-NC so the CPU-written
	 * console pixels are visible. Cover the whole 2 MiB-aligned span the board
	 * framebuffer lives in (santoni 4 MiB @ 0x90000000; oxygen ~8.3 MiB @
	 * 0x90001000, so 0x90000000 .. 0x90800000 i.e. four 2 MiB blocks).
	 */
	uint64_t fb_span_beg = FB_PHYS & ~(L2_BLK_SIZE - 1);
	uint64_t fb_span_end = (FB_PHYS + (uint64_t)FB_W * FB_H * FB_BPP + L2_BLK_SIZE - 1) & ~(L2_BLK_SIZE - 1);
	for (uint64_t a = fb_span_beg; a < fb_span_end; a += L2_BLK_SIZE) {
		uint64_t i = (a - 0x80000000UL) >> L2_BLK_SHIFT;
		l2_2[i] = a | NC_FLAGS | D_BLOCK;
	}

	/* Map shim image with 4 KiB L3 table */
	if (img_lo >= 0x20000000UL && img_hi <= 0x40000000UL) {
		/* Image placed in GiB 0 DRAM by Qualcomm LK (santoni default) */
		uint64_t blk_first = img_lo >> L2_BLK_SHIFT;
		uint64_t blk_last  = (img_hi - 1) >> L2_BLK_SHIFT;
		if (blk_last - blk_first > 1)
			return -2;
		for (uint64_t blk = blk_first; blk <= blk_last; blk++) {
			uint64_t *l3 = (uint64_t *)(pool + (3 + n_l3++) * PG_SIZE);
			uint64_t base = blk << L2_BLK_SHIFT;
			zero_table(l3);
			for (int i = 0; i < NENT; i++) {
				uint64_t pa = base + ((uint64_t)i << PG_SHIFT);
				l3[i] = pa | WB_FLAGS | D_PAGE;
			}
			l2_0[blk] = (uintptr_t)l3 | D_TABLE;
		}
	} else if (img_lo >= 0x80000000UL && img_hi <= 0xC0000000UL) {
		/* Image placed in GiB 2 DRAM */
		uint64_t blk_first = (img_lo - 0x80000000UL) >> L2_BLK_SHIFT;
		uint64_t blk_last  = (img_hi - 1 - 0x80000000UL) >> L2_BLK_SHIFT;
		if (blk_last - blk_first > 1)
			return -2;
		for (uint64_t blk = blk_first; blk <= blk_last; blk++) {
			uint64_t *l3 = (uint64_t *)(pool + (3 + n_l3++) * PG_SIZE);
			uint64_t base = 0x80000000UL + (blk << L2_BLK_SHIFT);
			zero_table(l3);
			for (int i = 0; i < NENT; i++) {
				uint64_t pa = base + ((uint64_t)i << PG_SHIFT);
				int ours = pa >= img_lo && pa < img_hi;
				l3[i] = pa | (ours ? WB_FLAGS : DEV_FLAGS) | D_PAGE;
			}
			l2_2[blk] = (uintptr_t)l3 | D_TABLE;
		}
	} else {
		return -1;
	}
	info->n_l3 = n_l3;

	/* Image lines may be stale in cache from ABL; we wrote memory directly */
	dcache_inval_range(img_lo, img_hi);
	__asm__ volatile("ic iallu; dsb sy; isb" ::: "memory");

	wsr("mair_el1", MAIR_VAL);
	wsr("tcr_el1", TCR_VAL);
	wsr("ttbr0_el1", pool);
	__asm__ volatile("isb; tlbi vmalle1; dsb nsh; isb" ::: "memory");

	uint64_t sctlr = rsr("sctlr_el1");
	info->sctlr_before = sctlr;
	sctlr &= ~(SCTLR_A | SCTLR_WXN);
	sctlr |= SCTLR_M | SCTLR_C | SCTLR_I;
	wsr("sctlr_el1", sctlr);
	__asm__ volatile("isb" ::: "memory");
	info->sctlr_after = rsr("sctlr_el1");
	return 0;
}

/* Translate a VA with AT S1E1R; returns PAR_EL1 */
uint64_t mmu_probe(uintptr_t va)
{
	__asm__ volatile("at s1e1r, %0; isb" : : "r"(va) : "memory");
	return rsr("par_el1");
}
