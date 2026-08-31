from PIL import Image
import os

def convert(src, dst, size):
    if not os.path.exists(src):
        print(f"Error: {src} not found")
        return
    img = Image.open(src).convert("RGBA").resize(size)
    with open(dst, "wb") as f:
        f.write(img.tobytes())
    print(f"Converted {src} to {dst} ({size[0]}x{size[1]})")

os.makedirs("/home/ubuntu/zigos/assets", exist_ok=True)

convert("/home/ubuntu/upload/search_images/GAONFwADb6xp.jpg", "/home/ubuntu/zigos/assets/wallpaper.raw", (1280, 800))
convert("/home/ubuntu/zigos/assets/icon_folder.png", "/home/ubuntu/zigos/assets/icon_folder.raw", (64, 64))
convert("/home/ubuntu/zigos/assets/icon_file.png", "/home/ubuntu/zigos/assets/icon_file.raw", (64, 64))
convert("/home/ubuntu/zigos/assets/icon_settings.png", "/home/ubuntu/zigos/assets/icon_settings.raw", (64, 64))
convert("/home/ubuntu/zigos/assets/cursor_arrow.png", "/home/ubuntu/zigos/assets/cursor_arrow.raw", (32, 32))
