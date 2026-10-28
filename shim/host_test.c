/* Render the console layout on the host: ./out/host_test && view out/host.ppm */
#include <stdio.h>
#include "console.h"

static uint8_t host_fb[FB_H * FB_STRIDE];

int main(void)
{
	con_fb = host_fb;
	con_clear(RED);
	con_str("SHIM", "bare-metal shim bring-up");
	con_hex("MMFR0", 0x0000000000101122ULL);
	con_hex2("PSCI", "ver=", 0x10001, "smccc=", 0x10002);
	con_clear(BLUE);
	con_str("PANIC", "sync exception");
	con_hex("ESR", 0x96000010);
	FILE *f = fopen("out/host.ppm", "wb");
	if (!f)
		return 1;
	fprintf(f, "P6 %d %d 255\n", FB_W, FB_H);
	/* Emit RGB24 regardless of FB_BPP: drop the alpha byte on 32bpp boards. */
	for (int y = 0; y < FB_H; y++) {
		const uint8_t *row = host_fb + y * FB_STRIDE;
		for (int x = 0; x < FB_W; x++) {
			fwrite(row + x * FB_BPP, 1, 3, f);
		}
	}
	fclose(f);
	return 0;
}
