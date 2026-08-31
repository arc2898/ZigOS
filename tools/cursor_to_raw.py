from PIL import Image

def crop_and_convert(input_path, output_path):
    img = Image.open(input_path).convert("RGBA")
    # Arrow tip is at (260, 335)
    cursor = img.crop((260, 335, 260+32, 335+32))
    cursor.save("/home/ubuntu/zigos/assets/cursor_preview.png")
    
    with open(output_path, "wb") as f:
        for y in range(cursor.height):
            for x in range(cursor.width):
                r, g, b, a = cursor.getpixel((x, y))
                f.write(bytes([r, g, b, a]))

if __name__ == "__main__":
    crop_and_convert("/home/ubuntu/zigos/assets/cursors.png", "/home/ubuntu/zigos/assets/cursor.raw")
