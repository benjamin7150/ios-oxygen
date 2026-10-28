/*
 * Host unit test for Mach-O 64-bit segment unroller and boot_args builder.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include "console.h"
#include "loader.h"

char _end[4096] __attribute__((aligned(4096)));
volatile uint8_t *con_fb = NULL;

void con_clear(uint32_t bg) { (void)bg; }
void con_skip(void) {}
void con_rewind(int n) { (void)n; }
void con_str(const char *label, const char *s) { (void)label; (void)s; }
void con_hex(const char *label, uint64_t v) { (void)label; (void)v; }
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb)
{
	(void)label; (void)a; (void)va; (void)b; (void)vb;
}

static uintptr_t mock_rd_start;
static uintptr_t mock_rd_end;

int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out)
{
	(void)fdt;
	if (strcmp(prop, "linux,initrd-start") == 0) {
		*out = mock_rd_start;
		return 1;
	}
	if (strcmp(prop, "linux,initrd-end") == 0) {
		*out = mock_rd_end;
		return 1;
	}
	return 0;
}

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
	struct payload_seg segs[1];
};

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

static uint8_t fake_ram[0x20000] __attribute__((aligned(4096)));
static uint8_t fake_payload[0x10000] __attribute__((aligned(4096)));

int main(void)
{
	memset(fake_ram, 0x55, sizeof(fake_ram));
	memset(fake_payload, 0, sizeof(fake_payload));

	struct payload *p = (struct payload *)fake_payload;
	memcpy(p->magic, "SWEETXNU", 8);
	p->version = 1;
	p->nsegs = 1;
	p->virt_base = 0xfffffff007000000UL;
	p->phys_base = (uintptr_t)fake_ram;
	p->mem_size = sizeof(fake_ram);
	p->entry_va = 0xfffffff007000000UL;
	p->kernel_end = p->virt_base + 0x2000UL;
	p->adt_off = 0x500;
	p->adt_size = 0x80;
	snprintf(p->cmdline, sizeof(p->cmdline), "console=null santoni");

	p->segs[0].vmaddr = 0xfffffff007000000UL;
	p->segs[0].vmsize = 0x2000UL;
	p->segs[0].file_off = 0x800;
	p->segs[0].file_size = 0x1000UL;

	memset(fake_payload + 0x800, 0xaa, 0x1000);
	memset(fake_payload + 0x500, 0xbb, 0x80);

	mock_rd_start = (uintptr_t)fake_payload;
	mock_rd_end = (uintptr_t)fake_payload + sizeof(fake_payload);

	const char *res = loader_boot(0x1234);
	assert(res != NULL);
	assert(strcmp(res, "ok") == 0);

	/* Check segment data copied */
	for (size_t i = 0; i < 0x1000; i++) {
		assert(fake_ram[i] == 0xaa);
	}
	/* Check zero-fill */
	for (size_t i = 0x1000; i < 0x2000; i++) {
		assert(fake_ram[i] == 0x00);
	}

	/* Check ADT */
	for (size_t i = 0; i < 0x80; i++) {
		assert(fake_ram[0x2000 + i] == 0xbb);
	}

	/* Check boot_args */
	uintptr_t adt_pa = (uintptr_t)fake_ram + 0x2000;
	uintptr_t ba_pa = (adt_pa + 0x80 + PAGE_4K - 1) & ~(PAGE_4K - 1);
	assert((ba_pa & 0xfff) == 0);

	struct boot_args *ba = (struct boot_args *)ba_pa;
	assert(ba->Video.v_depth == FB_BPP * 8);
	assert(ba->Video.v_rowBytes == FB_STRIDE);
	assert(ba->Video.v_width == FB_W);
	assert(ba->Video.v_height == FB_H);
	assert(ba->Video.v_baseAddr == FB_BASE);
	assert((ba_pa & 0xfff) == 0);
	assert(ba->Revision == 2 && ba->Version == 2);
	assert(strcmp(ba->CommandLine, "console=null santoni") == 0);

	/* Test bounds validation (T-03-07) */
	p->nsegs = 33;
	assert(strcmp(loader_boot(0x1234), "too many segments") == 0);
	p->nsegs = 1;

	p->segs[0].vmsize = sizeof(fake_ram) + 0x1000;
	assert(strcmp(loader_boot(0x1234), "segment outside physical memory") == 0);
	p->segs[0].vmsize = 0x2000UL;

	printf("loader_test PASSED\n");
	return 0;
}
