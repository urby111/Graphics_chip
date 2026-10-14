// Minimal uncached EL3 runtime, initialized through JTAG.
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include "xil_types.h"
#include "xil_assert.h"

volatile uint32_t *const report = (volatile uint32_t *)0x0ff00000UL;

void *memset(void *p, int c, size_t n)
{
    unsigned char *d = p;
    while (n--) *d++ = (unsigned char)c;
    return p;
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    if (a < b) return memcpy(d, s, n);

    while (n) {
        --n;
        a[n] = b[n];
    }
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    while (n--) {
        if (*x != *y) return *x - *y;
        ++x;
        ++y;
    }
    return 0;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n]) ++n;
    return n;
}

static uint64_t ticks(void)
{
    uint64_t n;
    __asm__ volatile("mrs %0,cntpct_el0" : "=r"(n));
    return n;
}

int usleep(unsigned long us)
{
    uint64_t hz = *(volatile uint32_t *)0xff260020UL;
    uint64_t until = ticks() + (us * hz + 999999) / 1000000;
    while (ticks() < until) __asm__ volatile("nop");
    return 0;
}

// Poll UART TX space before writing a byte.
void outbyte(char c)
{
    volatile uint32_t *u = (volatile uint32_t *)0xff010000UL;
    for (unsigned t = 0; t < 1000000; ++t)
        if (!(u[0x2c / 4] & 16)) {
            u[0x30 / 4] = (unsigned char)c;
            return;
        }
}

static void number(uint64_t value, unsigned base, unsigned width)
{
    char b[32];
    unsigned n = 0;

    do {
        b[n++] = "0123456789abcdef"[value % base];
        value /= base;
    } while (value);

    while (n < width) b[n++] = '0';
    while (n) outbyte(b[--n]);
}

void xil_printf(const char *f, ...)
{
    va_list a;
    va_start(a, f);

    while (*f) {
        if (*f != '%') {
            outbyte(*f++);
            continue;
        }
        ++f;

        unsigned width = 0;
        if (*f == '0') ++f;
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');

        unsigned lng = 0;
        while (*f == 'l') {
            ++lng;
            ++f;
        }

        char c = *f++;
        if (c == 's') {
            const char *s = va_arg(a, const char *);
            if (!s) s = "(null)";
            while (*s) outbyte(*s++);
        } else if (c == 'c') {
            outbyte(va_arg(a, int));
        } else if (c == 'd' || c == 'i') {
            int64_t v = lng ? va_arg(a, int64_t) : va_arg(a, int);
            if (v < 0) {
                outbyte('-');
                v = -v;
            }
            number((uint64_t)v, 10, width);
        } else if (c == 'u' || c == 'x' || c == 'X') {
            uint64_t v = lng ? va_arg(a, uint64_t) : va_arg(a, unsigned);
            number(v, c == 'u' ? 10 : 16, width);
        } else if (c == '%') outbyte('%');
    }

    va_end(a);
}

u32 Xil_AssertStatus;

void Xil_Assert(const char8 *file, s32 line)
{
    (void)file;
    report[1] = 0xed;
    report[2] = (uint32_t)line;
    __asm__ volatile("dsb sy");
    for (;;) __asm__ volatile("wfe");
}

// Caches stay disabled; barriers publish shared DDR writes.
void Xil_DCacheDisable(void) {}

void Xil_DCacheFlushRange(INTPTR address, u32 length)
{
    (void)address;
    (void)length;
    __asm__ volatile("dsb sy" ::: "memory");
}

void Xil_DCacheInvalidateRange(INTPTR address, u32 length)
{
    (void)address;
    (void)length;
    __asm__ volatile("dsb sy" ::: "memory");
}

// Small math routines used by the CPU matrix calculator.
double round(double x)
{
    if (!__builtin_isfinite(x) || x > 9e18 || x < -9e18) return x;
    return (double)(int64_t)(x >= 0 ? x + 0.5 : x - 0.5);
}

double sin(double x)
{
    if (!__builtin_isfinite(x)) return x;
    const double pi = 3.14159265358979323846;

    while (x > pi) x -= 2 * pi;
    while (x < -pi) x += 2 * pi;

    double term = x, sum = x;
    for (int k = 1; k < 16; ++k) {
        term *= -x * x / ((2 * k) * (2 * k + 1));
        sum += term;
    }
    return sum;
}

double cos(double x)
{
    return sin(x + 1.57079632679489661923);
}

double ceil(double x)
{
    int64_t n = (int64_t)x;
    return (double)(n + (x > (double)n));
}

double floor(double x)
{
    int64_t n = (int64_t)x;
    return (double)(n - (x < (double)n));
}

double fabs(double x)
{
    return x < 0 ? -x : x;
}
