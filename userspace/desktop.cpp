#include "libzigos.hpp"
#include "graphics.hpp"

// External binary assets linked into the executable
extern "C" const uint8_t _binary_assets_wallpaper_raw_start[];
extern "C" const uint8_t _binary_assets_icon_folder_raw_start[];
extern "C" const uint8_t _binary_assets_icon_file_raw_start[];
extern "C" const uint8_t _binary_assets_icon_settings_raw_start[];
extern "C" const uint8_t _binary_assets_cursor_arrow_raw_start[];
extern "C" const uint8_t _binary_assets_font_raw_start[];

namespace desktop {

using namespace graphics;

class DesktopCanvas : public Canvas {
public:
    DesktopCanvas(zigos::FramebufferInfo& fb) : Canvas(fb) {}

    void draw_char(int x, int y, char c, Color color) {
        if (c < 32 || c > 127) return;
        const uint8_t* font_glyph = _binary_assets_font_raw_start + ((uint8_t)(c - 32) * 16);
        
        for (int row = 0; row < 16; ++row) {
            uint8_t bits = font_glyph[row];
            for (int col = 0; col < 8; ++col) {
                if ((bits >> (7 - col)) & 1) {
                    draw_pixel(x + col, y + row, color);
                }
            }
        }
    }

    void draw_text(int x, int y, const char* text, Color color) {
        int curr_x = x;
        while (*text) {
            draw_char(curr_x, y, *text, color);
            curr_x += 9; // 8 pixels + 1 spacing
            text++;
        }
    }
};

void render(DesktopCanvas& canvas) {
    // 1. Draw nature wallpaper (1280x800)
    canvas.draw_image(0, 0, 1280, 800, (const uint32_t*)_binary_assets_wallpaper_raw_start, false);

    // 2. Draw Taskbar (macOS-style dock at bottom)
    int dock_w = 600;
    int dock_h = 70;
    int dock_x = (canvas.width - dock_w) / 2;
    int dock_y = canvas.height - dock_h - 20;
    canvas.draw_rect(dock_x, dock_y, dock_w, dock_h, Color::from_rgba(255, 255, 255, 180));

    // 3. Draw Icons on Dock
    canvas.draw_image(dock_x + 30, dock_y + 3, 64, 64, (const uint32_t*)_binary_assets_icon_folder_raw_start);
    canvas.draw_image(dock_x + 130, dock_y + 3, 64, 64, (const uint32_t*)_binary_assets_icon_file_raw_start);
    canvas.draw_image(dock_x + 230, dock_y + 3, 64, 64, (const uint32_t*)_binary_assets_icon_settings_raw_start);

    // 4. Draw Login Box
    int login_w = 350;
    int login_h = 220;
    int login_x = (canvas.width - login_w) / 2;
    int login_y = (canvas.height - login_h) / 2 - 50;
    canvas.draw_rect(login_x, login_y, login_w, login_h, Color::from_rgba(255, 255, 255, 220));
    
    // Header
    canvas.draw_rect(login_x, login_y, login_w, 40, Color::from_rgba(0, 102, 204, 255));
    canvas.draw_text(login_x + 20, login_y + 12, "ZigOS Professional Login", Color::from_rgba(255, 255, 255, 255));
    
    // Labels and Fields
    canvas.draw_text(login_x + 40, login_y + 55, "Username:", Color::from_rgba(50, 50, 50, 255));
    canvas.draw_rect(login_x + 40, login_y + 70, login_w - 80, 30, Color::from_rgba(240, 240, 240, 255));
    canvas.draw_text(login_x + 50, login_y + 77, "root", Color::from_rgba(0, 0, 0, 255));
    
    canvas.draw_text(login_x + 40, login_y + 115, "Password:", Color::from_rgba(50, 50, 50, 255));
    canvas.draw_rect(login_x + 40, login_y + 130, login_w - 80, 30, Color::from_rgba(240, 240, 240, 255));
    canvas.draw_text(login_x + 50, login_y + 137, "********", Color::from_rgba(0, 0, 0, 255));
    
    // Login button
    canvas.draw_rect(login_x + 100, login_y + 175, 150, 30, Color::from_rgba(0, 153, 76, 255));
    canvas.draw_text(login_x + 155, login_y + 182, "Login", Color::from_rgba(255, 255, 255, 255));

    // 5. Draw Cursor
    canvas.draw_image(canvas.width / 2 + 50, canvas.height / 2 + 50, 32, 32, (const uint32_t*)_binary_assets_cursor_arrow_raw_start);
}

} // namespace desktop

extern "C" __attribute__((section(".text._start"))) void _start() {
    // ZIGOS-105: Direct serial write for earliest possible proof.
    // We use a simpler loop and ensure the port is ready.
    const char* msg = "GUI_START\n";
    for (int i = 0; i < 10; i++) {
        // Wait for Transmit Holding Register to be empty
        uint8_t status = 0;
        do {
            asm volatile("inb %1, %0" : "=a"(status) : "Nd"((uint16_t)0x3FD));
        } while ((status & 0x20) == 0);
        asm volatile("outb %0, %1" : : "a"(msg[i]), "Nd"((uint16_t)0x3F8));
    }

    zigos::print("ZigOS C++ Professional Desktop initializing...\n");
    
    zigos::FramebufferInfo fb;
    if (!zigos::get_fb_info(&fb)) {
        zigos::print("GUI: Critical Error - Failed to obtain framebuffer info\n");
        zigos::exit(1);
    }

    desktop::DesktopCanvas canvas(fb);
    desktop::render(canvas);

    zigos::print("ZigOS C++ Professional Desktop is now live.\n");
    
    while (true) {
        zigos::yield();
    }
}
