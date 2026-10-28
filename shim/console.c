/*
 * Minimal text console on the ABL splash framebuffer.
 * Both boards: 24-bit BGR (b8g8r8): santoni 720x1280, oxygen 1080x1920.
 * With the MMU off every access is Device memory: byte writes ensure strict alignment.
 */
#include "console.h"
#include "font.h"

#define SCALE		2
#define CH_W		(8 * SCALE)
#define CH_H		(16 * SCALE)
#define MARGIN		16
#define LABEL_COLS	8

volatile uint8_t *con_fb = (volatile uint8_t *)FB_BASE;
static uint32_t con_bg;
static int row;

static inline void put_pixel(int x, int y, uint32_t c)
{
	if (x < 0 || x >= FB_W || y < 0 || y >= FB_H)
		return;
	volatile uint8_t *p = con_fb + (y * FB_STRIDE) + (x * FB_BPP);
	/* BGR byte order on both boards (ABL cont-splash). */
	p[0] = (uint8_t)(c & 0xff);		/* blue */
	p[1] = (uint8_t)((c >> 8) & 0xff);	/* green */
	p[2] = (uint8_t)((c >> 16) & 0xff);	/* red */
#if FB_BPP >= 4
	p[3] = 0xff;				/* alpha (ignored by the panel scanout) */
#endif
}

void con_clear(uint32_t bg)
{
	for (int y = 0; y < FB_H; y++) {
		for (int x = 0; x < FB_W; x++)
			put_pixel(x, y, bg);
	}
	con_bg = bg;
	row = 0;
}

static void put_char(int col, char ch, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	int x0 = MARGIN + col * CH_W, y0 = MARGIN + row * CH_H;
	if (x0 + CH_W > FB_W || y0 + CH_H > FB_H)
		return;
	for (int gy = 0; gy < 16; gy++) {
		for (int gx = 0; gx < 8; gx++) {
			uint32_t c = (g[gy] & (0x80 >> gx)) ? fg : con_bg;
			for (int sy = 0; sy < SCALE; sy++) {
				for (int sx = 0; sx < SCALE; sx++)
					put_pixel(x0 + gx * SCALE + sx, y0 + gy * SCALE + sy, c);
			}
		}
	}
}

static int put_str(int col, const char *s, uint32_t fg)
{
	while (*s)
		put_char(col++, *s++, fg);
	return col;
}

static void fmt_hex(char *buf, uint64_t v, int digits)
{
	static const char hex[] = "0123456789ABCDEF";
	for (int i = 0; i < digits; i++)
		buf[i] = hex[(v >> (4 * (digits - 1 - i))) & 0xf];
	buf[digits] = 0;
}

void con_skip(void)
{
	row++;
}

void con_rewind(int n)
{
	row -= n;
	if (row < 0)
		row = 0;
}

void con_str(const char *label, const char *s)
{
	put_str(0, label, YELLOW);
	put_str(LABEL_COLS, s, WHITE);
	row++;
}

void con_hex(const char *label, uint64_t v)
{
	char buf[17];
	fmt_hex(buf, v, 16);
	con_str(label, buf);
}

void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb)
{
	char buf[9];
	int col = put_str(0, label, YELLOW);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	col = put_str(col, a, YELLOW);
	fmt_hex(buf, va, 8);
	col = put_str(col, buf, WHITE);
	if (b) {
		col = put_str(col + 1, b, YELLOW);
		fmt_hex(buf, vb, 8);
		put_str(col, buf, WHITE);
	}
	row++;
}
