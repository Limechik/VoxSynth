// Использование: ./voxtest "текст" [файл.wav] [темп]
#include "FormantCore.h"
#include "Phonemes.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void wr32(FILE*f,uint32_t v){fwrite(&v,4,1,f);}
static void wr16(FILE*f,uint16_t v){fwrite(&v,2,1,f);}

static size_t utf8to32(const unsigned char *s, uint32_t *o) {
    size_t n = 0;
    while (*s) {
        uint32_t c = *s;
        if (c < 0x80)               { s += 1; }
        else if ((c >> 5) == 0x6)   { c = ((c & 0x1F) << 6)  | (s[1] & 0x3F); s += 2; }
        else if ((c >> 4) == 0xE)   { c = ((c & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F); s += 3; }
        else                        { c = ((c & 0x07) << 18) | ((s[1] & 0x3F) << 12) | ((s[2] & 0x3F) << 6) | (s[3] & 0x3F); s += 4; }
        o[n++] = c;
    }
    return n;
}

int main(int argc, char **argv) {
    const char *text = argc > 1 ? argv[1] : "мама мыла раму";
    const char *name = argc > 2 ? argv[2] : "speech.wav";
    float speed = argc > 3 ? (float)atof(argv[3]) : 1.0f;
    const float fs = 22050;

    uint32_t *cps = malloc((strlen(text) + 1) * 4);
    size_t nc = utf8to32((const unsigned char *)text, cps);
    FCSegment *segs = malloc((8 * nc + 16) * sizeof(FCSegment));
    size_t ns = PHTextToSegments(cps, nc, segs, 8 * nc + 16, speed);
    size_t cap = FCTotalSamples(segs, ns, fs) + 100;
    int16_t *buf = malloc(cap * 2);
    size_t n = FCRender(segs, ns, buf, cap, fs);

    FILE *f = fopen(name, "wb");
    fwrite("RIFF",1,4,f); wr32(f,36+n*2); fwrite("WAVEfmt ",1,8,f);
    wr32(f,16); wr16(f,1); wr16(f,1); wr32(f,(uint32_t)fs); wr32(f,(uint32_t)fs*2);
    wr16(f,2); wr16(f,16); fwrite("data",1,4,f); wr32(f,n*2);
    fwrite(buf,2,n,f); fclose(f);
    printf("сегментов: %zu, сэмплов: %zu, файл: %s\n", ns, n, name);
    return 0;
}
