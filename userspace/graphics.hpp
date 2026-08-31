#pragma once
#include "libzigos.hpp"

namespace graphics {

struct Color {
    uint8_t b, g, r, a;
    static Color from_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
        return {b, g, r, a};
    }
};

class Canvas {
public:
    uint32_t* buffer;
    uint32_t width, height, pitch;

    Canvas(zigos::FramebufferInfo& fb) 
        : buffer((uint32_t*)fb.base), width(fb.width), height(fb.height), pitch(fb.pitch / 4) {}

    void clear(Color color) {
        uint32_t c = *(uint32_t*)&color;
        for (uint32_t i = 0; i < width * height; ++i) {
            buffer[i] = c;
        }
    }

    void draw_pixel(int x, int y, Color color) {
        if (x < 0 || x >= (int)width || y < 0 || y >= (int)height) return;
        buffer[y * pitch + x] = *(uint32_t*)&color;
    }

    void draw_rect(int x, int y, int w, int h, Color color) {
        for (int j = 0; j < h; ++j) {
            for (int i = 0; i < w; ++i) {
                draw_pixel(x + i, y + j, color);
            }
        }
    }

    void draw_image(int x, int y, int w, int h, const uint32_t* data, bool alpha = true) {
        for (int j = 0; j < h; ++j) {
            for (int i = 0; i < w; ++i) {
                uint32_t pixel = data[j * w + i];
                if (alpha) {
                    uint8_t a = (pixel >> 24) & 0xFF;
                    if (a == 0) continue;
                    if (a < 255) {
                        // Simple alpha blending
                        uint32_t bg = buffer[(y + j) * pitch + (x + i)];
                        uint8_t br = (bg >> 16) & 0xFF, bg_g = (bg >> 8) & 0xFF, bb = bg & 0xFF;
                        uint8_t fr = (pixel >> 16) & 0xFF, fg = (pixel >> 8) & 0xFF, fb = pixel & 0xFF;
                        uint8_t rr = (fr * a + br * (255 - a)) / 255;
                        uint8_t rg = (fg * a + bg_g * (255 - a)) / 255;
                        uint8_t rb = (fb * a + bb * (255 - a)) / 255;
                        pixel = (0xFF << 24) | (rr << 16) | (rg << 8) | rb;
                    }
                }
                draw_pixel(x + i, y + j, *(Color*)&pixel);
            }
        }
    }

    void draw_char(int x, int y, char c, Color color, const uint8_t* font_data) {
        if (c < 32 || c > 127) return;
        const uint8_t* glyph = &font_data[(c - 32) * 16];
        for (int j = 0; j < 16; ++j) {
            uint8_t row = glyph[j];
            for (int i = 0; i < 8; ++i) {
                if ((row >> (7 - i)) & 1) {
                    draw_pixel(x + i, y + j, color);
                }
            }
        }
    }

    void draw_string(int x, int y, const char* s, Color color, const uint8_t* font_data) {
        while (*s) {
            draw_char(x, y, *s, color, font_data);
            x += 8;
            s++;
        }
    }
};

} // namespace graphics
