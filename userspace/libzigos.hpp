#pragma once

typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;
typedef unsigned long size_t;

namespace zigos {

extern "C" {
    uint64_t syscall0(uint64_t nr);
    uint64_t syscall1(uint64_t nr, uint64_t a1);
    uint64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2);
    uint64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3);
}

enum class PixelFormat : uint32_t {
    rgb = 0,
    bgr = 1,
    bitmask = 2
};

struct FramebufferInfo {
    uint64_t base;
    uint32_t width;
    uint32_t height;
    uint32_t pitch;
    PixelFormat format;
    uint32_t mask_red;
    uint32_t mask_green;
    uint32_t mask_blue;
    uint8_t shift_red;
    uint8_t shift_green;
    uint8_t shift_blue;
    // No padding here to match Zig's extern struct FramebufferInfo in types.zig
};

inline size_t strlen(const char* s) {
    size_t len = 0;
    while (s[len]) len++;
    return len;
}

inline void exit(int status) {
    syscall1(0, (uint64_t)status);
    while(true);
}

inline void write(int fd, const char* s, size_t len) {
    syscall3(1, (uint64_t)fd, (uint64_t)s, (uint64_t)len);
}

inline void print(const char* s) {
    write(1, s, strlen(s));
}

inline bool get_fb_info(FramebufferInfo* info) {
    return syscall1(30, (uint64_t)info) == 0;
}

inline void yield() {
    syscall0(11);
}

} // namespace zigos
