from PIL import Image
import os

def prepare_icon(name, color):
    # Create a simple macOS Tahoe style icon (rounded rect with color)
    img = Image.new('RGBA', (48, 48), (0, 0, 0, 0))
    # For now, just save a colored block. In a real system we'd use the search images.
    # Since search images are thumbnails, we'll generate high quality stubs.
    from PIL import ImageDraw
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([4, 4, 44, 44], radius=10, fill=color)
    
    raw_path = f'/home/ubuntu/zigos/assets/{name}.raw'
    with open(raw_path, 'wb') as f:
        f.write(img.tobytes())
    print(f"Icon prepared: {raw_path}")

def prepare_cursor():
    # Create a simple Tahoe style cursor (black with white border)
    img = Image.new('RGBA', (32, 32), (0, 0, 0, 0))
    from PIL import ImageDraw
    draw = ImageDraw.Draw(img)
    # Simple arrow
    points = [(0,0), (0,20), (5,15), (12,15)]
    draw.polygon(points, fill=(0,0,0,255), outline=(255,255,255,255))
    
    raw_path = '/home/ubuntu/zigos/assets/cursor.raw'
    with open(raw_path, 'wb') as f:
        f.write(img.tobytes())
    print(f"Cursor prepared: {raw_path}")

if __name__ == "__main__":
    if not os.path.exists('/home/ubuntu/zigos/assets'):
        os.makedirs('/home/ubuntu/zigos/assets')
    prepare_icon('folder', (0, 122, 255, 255))
    prepare_icon('file', (255, 255, 255, 255))
    prepare_icon('app', (52, 199, 89, 255))
    prepare_cursor()
