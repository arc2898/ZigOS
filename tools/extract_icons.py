from PIL import Image
import os

def extract_icon(sheet_path, output_dir, x, y, size, name):
    sheet = Image.open(sheet_path).convert("RGBA")
    icon = sheet.crop((x, y, x + size, y + size))
    
    # Save as preview
    icon.save(os.path.join(output_dir, f"{name}.png"))
    
    # Save as raw RGBA for kernel
    with open(os.path.join(output_dir, f"{name}.raw"), "wb") as f:
        for iy in range(size):
            for ix in range(size):
                r, g, b, a = icon.getpixel((ix, iy))
                f.write(bytes([r, g, b, a]))
    print(f"Extracted icon: {name}")

if __name__ == "__main__":
    sheet_path = "/home/ubuntu/zigos/assets/icons_glass.png"
    output_dir = "/home/ubuntu/zigos/assets"
    
    # Based on standard icon sheets, let's try 64x64 extraction
    # We'll extract a few common ones
    icons = [
        (0, 0, 64, "icon_computer"),
        (64, 0, 64, "icon_network"),
        (128, 0, 64, "icon_trash"),
        (192, 0, 64, "icon_zide"),
        (0, 64, 64, "icon_settings"),
        (64, 64, 64, "icon_folder"),
        (128, 64, 64, "icon_file"),
    ]
    
    for x, y, size, name in icons:
        extract_icon(sheet_path, output_dir, x, y, size, name)
