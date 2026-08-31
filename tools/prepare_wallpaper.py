from PIL import Image
import os

def prepare():
    src = '/home/ubuntu/upload/search_images/Mj7TEOlOn4Yj.jpg'
    dst_png = '/home/ubuntu/zigos/assets/wallpaper.png'
    dst_raw = '/home/ubuntu/zigos/assets/wallpaper.raw'
    
    if not os.path.exists('/home/ubuntu/zigos/assets'):
        os.makedirs('/home/ubuntu/zigos/assets')
        
    img = Image.open(src)
    img = img.resize((1024, 768), Image.Resampling.LANCZOS)
    img.save(dst_png)
    
    # Save as 32-bit BGRA for easy blitting
    with open(dst_raw, 'wb') as f:
        f.write(img.convert('RGBA').tobytes())
    print(f"Wallpaper prepared: {dst_png} and {dst_raw}")

if __name__ == "__main__":
    prepare()
