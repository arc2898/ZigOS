import sys
from PIL import Image

def convert(input_path, output_path, width=None, height=None):
    img = Image.open(input_path).convert("RGBA")
    if width and height:
        img = img.resize((width, height))
    
    with open(output_path, "wb") as f:
        for y in range(img.height):
            for x in range(img.width):
                r, g, b, a = img.getpixel((x, y))
                # Store as 32-bit RGBA (kernel will swap to BGR if needed)
                f.write(bytes([r, g, b, a]))

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: img_to_raw.py <input> <output> [width] [height]")
        sys.exit(1)
    
    w = int(sys.argv[3]) if len(sys.argv) > 3 else None
    h = int(sys.argv[4]) if len(sys.argv) > 4 else None
    convert(sys.argv[1], sys.argv[2], w, h)
