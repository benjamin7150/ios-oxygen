/*
 * Milestone 4: act as iBoot for xnu on Cortex-A53 (MSM8937 / santoni).
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload in the ABL ramdisk (or embedded),
 * copy the segments to phys_base + (vmaddr - virt_base), place the ADT and
 * boot_args behind the kernel with 4 KiB page alignment, and jump to the entry
 * point with the MMU and caches off, x0 = boot_args (physical).
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "loader.h"
#include "wdt.h"

#define BOOT_LINE_LENGTH	608
#define PAGE_4K			0x1000UL

struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = "SWEETXNU";
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

typedef void (*xnu_entry_t)(uint64_t boot_args_pa);

/* build.sh appends the payload to the Image at the first 4K boundary after _end */
extern char _end[];

/*
 * Traverse Apple Device Tree buffer at base, finding every "device_type" == "cpu"
 * node. If its "reg" property matches boot_phys, mark "state" = "running".
 * Otherwise mark "state" = "stopped". Both strings are 8 bytes ('running\0' / 'stopped\0').
 */
static uintptr_t adt_walk_fix_cpus(uintptr_t base, uintptr_t off, uintptr_t total_size, uint32_t boot_phys)
{
	if (off + 8 > total_size)
		return total_size;

	volatile const uint32_t *hdr = (volatile const uint32_t *)(base + off);
	uint32_t nprops = hdr[0];
	uint32_t nchildren = hdr[1];
	off += 8;

	if (nprops > 256 || nchildren > 256)
		return total_size;

	uintptr_t state_val_off = 0;
	int is_cpu = 0;
	uint32_t reg_val = 0xffffffff;

	for (uint32_t i = 0; i < nprops; i++) {
		if (off + 36 > total_size)
			return total_size;

		volatile const char *pname = (volatile const char *)(base + off);
		volatile const uint32_t *psize = (volatile const uint32_t *)(base + off + 32);
		uint32_t ln = *psize & 0x7fffffff;
		uintptr_t val_off = off + 36;
		uint32_t padded_ln = (ln + 3) & ~3;

		if (val_off + padded_ln > total_size)
			return total_size;

		if (pname[0] == 'd' && pname[1] == 'e' && pname[2] == 'v' &&
		    pname[3] == 'i' && pname[4] == 'c' && pname[5] == 'e' &&
		    pname[6] == '_' && pname[7] == 't' && pname[8] == 'y' &&
		    pname[9] == 'p' && pname[10] == 'e' && pname[11] == '\0') {
			volatile const char *v = (volatile const char *)(base + val_off);
			if (ln >= 4 && v[0] == 'c' && v[1] == 'p' && v[2] == 'u' && v[3] == '\0')
				is_cpu = 1;
		} else if (pname[0] == 'r' && pname[1] == 'e' && pname[2] == 'g' && pname[3] == '\0') {
			if (ln >= 4)
				reg_val = *(volatile const uint32_t *)(base + val_off);
		} else if (pname[0] == 's' && pname[1] == 't' && pname[2] == 'a' && pname[3] == 't' && pname[4] == 'e' && pname[5] == '\0') {
			if (ln >= 8)
				state_val_off = val_off;
		}

		off += 36 + padded_ln;
	}

	if (is_cpu && state_val_off) {
		volatile char *s = (volatile char *)(base + state_val_off);
		if (reg_val == boot_phys) {
			s[0] = 'r'; s[1] = 'u'; s[2] = 'n'; s[3] = 'n'; s[4] = 'i'; s[5] = 'n'; s[6] = 'g'; s[7] = '\0';
		} else {
			s[0] = 's'; s[1] = 't'; s[2] = 'o'; s[3] = 'p'; s[4] = 'p'; s[5] = 'e'; s[6] = 'd'; s[7] = '\0';
		}
	}

	for (uint32_t i = 0; i < nchildren; i++) {
		off = adt_walk_fix_cpus(base, off, total_size, boot_phys);
	}
	return off;
}

const char *loader_boot(uintptr_t dtb)
{
	uint64_t rd_start, rd_end;
	uintptr_t emb = 0;

	/*
	 * Payload can ride either behind the shim in the kernel Image (embedded),
	 * or inside the ABL-passed initrd via /chosen. The embedded path is only
	 * meaningful in the freestanding image; the host unit test uses the
	 * initrd mock and has no mapped shim Image behind _end.
	 */
#if !__STDC_HOSTED__
	emb = ((uintptr_t)_end + 0xfff) & ~0xfffUL;
#endif
	if (emb && magic_ok((const char *)emb)) {
		rd_start = emb;
		rd_end = emb + 0x8000000;
		con_hex("EMBED", emb);
	} else {
		if (!fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start) ||
		    !fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end))
			return "no initrd in /chosen";
		con_hex2("INITRD", "lo=", rd_start, "hi=", rd_end);
	}

	uintptr_t hit = 0;
	for (uintptr_t a = rd_start; a + 8 <= rd_end; a++)
		if (magic_ok((const char *)a)) {
			hit = a;
			break;
		}
	if (!hit)
		return "no SWEETXNU payload";
	if (hit != rd_start) {
		uintptr_t dst = (rd_start + 7) & ~7UL;
		volatile uint8_t *d = (volatile uint8_t *)dst;
		volatile const uint8_t *src = (volatile const uint8_t *)hit;

		con_hex2("PAYLOAD", "at=", hit, "to=", dst);
		for (uint64_t i = 0; i < rd_end - hit; i++)
			d[i] = src[i];
		rd_end = dst + (rd_end - hit);
		rd_start = dst;
	}
	const struct payload *p = (const struct payload *)rd_start;
	if (p->version != 1 || (p->adt_off & 7) || (rd_start & 7))
		return "bad payload header";
	if (p->nsegs > 32)
		return "too many segments";

	uint64_t pa_of_va_base = p->phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", p->phys_base, "size=", p->mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);

	/* The payload must not overlap where the kernel goes. */
	if (rd_end > p->phys_base && rd_start < p->phys_base + p->mem_size)
		return "ramdisk overlaps kernel memory";

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		if (dst < p->phys_base || dst + s->vmsize > p->phys_base + p->mem_size)
			return "segment outside physical memory";
		copy64(dst, rd_start + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL), s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);

	/* ADT, then boot_args, behind the kernel; 4 KiB page aligned for Cortex-A53 */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, rd_start + p->adt_off, p->adt_size);

#if !__STDC_HOSTED__
	uint64_t mpidr;
	__asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
	uint32_t boot_phys = (uint32_t)(mpidr & 0xffff);
#else
#ifndef LOADER_TEST_BOOT_PHYS
#define LOADER_TEST_BOOT_PHYS 0x100
#endif
	uint32_t boot_phys = LOADER_TEST_BOOT_PHYS;
#endif
	adt_walk_fix_cpus(adt_pa, 0, p->adt_size, boot_phys);
	con_hex2("BOOT_CPU", "mpidr=", boot_phys, "adt=", adt_pa);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_4K - 1) & ~(PAGE_4K - 1);
	uintptr_t top = ba_pa + PAGE_4K;
	if (top > p->phys_base + p->mem_size)
		return "kernel data exceeds physical memory";

	zero64(ba_pa, PAGE_4K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_VIDEO_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_VIDEO_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = FB_VIDEO_BPP * 8;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);
	con_str("XNU", "jumping (fbcon clears screen)");

#if !__STDC_HOSTED__
	/*
	 * Last chance to touch the APPS watchdog: the copy above can take a
	 * while and XNU has no Qualcomm watchdog driver yet, so pet it once
	 * and leave it disabled (LK leaves whatever it inherited untouched).
	 */
	wdt_pet();
	wdt_disable();

	/* Clean loaded segments and ADT from cache to PoC before jump */
	uint64_t ctr;
	__asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
	uintptr_t line = 4UL << ((ctr >> 16) & 0xf);
	for (uintptr_t paddr = p->phys_base; paddr < top; paddr += line)
		__asm__ volatile("dc cvac, %0" : : "r"(paddr) : "memory");

	/* Invalidate I-cache, barrier, and jump with x0 = boot_args PA */
	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	return "xnu returned";
#else
	(void)entry_pa;
	return "ok";
#endif
}
