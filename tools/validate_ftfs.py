import struct
import sys

BLOCK = 4096
INODE_SIZE = 16544
MAGIC = struct.unpack("<Q", b"FTFS\0\0\0\0")[0]

def validate(path):
    with open(path, "rb") as f:
        data = f.read()
    
    magic = struct.unpack("<Q", data[0:8])[0]
    version = struct.unpack("<I", data[8:12])[0]
    block_size = struct.unpack("<I", data[12:16])[0]
    inode_count = struct.unpack("<I", data[16:20])[0]
    root_inode = struct.unpack("<I", data[20:24])[0]
    data_block_count = struct.unpack("<I", data[24:28])[0]
    inode_table_offset = struct.unpack("<Q", data[32:40])[0]
    data_offset = struct.unpack("<Q", data[40:48])[0]
    checksum = struct.unpack("<I", data[80:84])[0]
    bitmap_offset = struct.unpack("<Q", data[88:96])[0]
    journal_offset = struct.unpack("<Q", data[96:104])[0]
    v2_checksum = struct.unpack("<I", data[128:132])[0]
    
    print(f"Magic: {hex(magic)}")
    print(f"Version: {version}")
    print(f"Block Size: {block_size}")
    print(f"Inode Count: {inode_count}")
    print(f"Inode Table Offset: {hex(inode_table_offset)}")
    print(f"Data Offset: {hex(data_offset)}")
    print(f"Checksum: {hex(checksum)}")
    print(f"V2 Checksum: {hex(v2_checksum)}")
    
    if magic != MAGIC:
        print("ERROR: Magic mismatch!")
        return False
    
    # Check the flat /apps layout emitted by mkftfs.py.
    inode_table = data[inode_table_offset : inode_table_offset + inode_count * INODE_SIZE]
    for i in range(inode_count):
        inode_data = inode_table[i*INODE_SIZE : (i+1)*INODE_SIZE]
        kind = inode_data[0]
        size = struct.unpack("<Q", inode_data[8:16])[0]
        name = inode_data[16:80].split(b"\x00")[0].decode()
        if name == "gui":
            print(f"Found 'gui' at inode {i}, size {size}, kind {kind}")
            return True
            
    print("ERROR: /apps/gui not found!")
    return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_ftfs.py <ramdisk.bin>")
        sys.exit(1)
    if not validate(sys.argv[1]):
        sys.exit(1)
