from PIL import Image
import sys

def convert(input_path, output_path):
    # PPM (Portable Pixmap) rawbits format (P6)
    with open(input_path, "rb") as f:
        header = f.readline().decode().strip()
        if header != "P6":
            print(f"Error: Expected P6 header, got {header}")
            return
        
        line = f.readline().decode().strip()
        while line.startswith("#"):
            line = f.readline().decode().strip()
        
        width, height = map(int, line.split())
        max_val = int(f.readline().decode().strip())
        
        data = f.read()
        img = Image.frombytes("RGB", (width, height), data)
        img.save(output_path)

if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2])
