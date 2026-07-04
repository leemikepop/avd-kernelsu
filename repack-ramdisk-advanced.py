import sys, os, io, subprocess

def decompress_lz4_legacy(data):
    # Android LZ4 legacy: magic(4) + blocks of [size(4) + compressed_data]
    # We will just write all blocks to a raw file and use lz4 -dc
    pos = 0
    out = b""
    while pos < len(data):
        magic = data[pos:pos+4]
        if magic == b'\x02\x21\x4c\x18':
            pos += 4
            while pos < len(data):
                bsz = int.from_bytes(data[pos:pos+4], 'little')
                pos += 4
                if bsz == 0 or bsz > len(data): break
                out += data[pos:pos+bsz]
                pos += bsz
            # After a legacy frame, there might be another!
        else:
            break
    
    with open('temp.raw', 'wb') as f:
        f.write(out)
    
    res = subprocess.run(['lz4', '-dc', 'temp.raw'], capture_output=True)
    if res.returncode == 0 or len(res.stdout) > 0:
        return res.stdout
    return None

ramdisk_path = sys.argv[1]
data = open(ramdisk_path, 'rb').read()

cpio_data = b""
if data.startswith(b'\x02\x21\x4c\x18'):
    print("Detected LZ4 Legacy...")
    cpio_data = decompress_lz4_legacy(data)
elif data.startswith(b'\x1f\x8b'):
    print("Detected GZIP...")
    import gzip
    cpio_data = gzip.decompress(data)
else:
    print("Assuming raw CPIO...")
    cpio_data = data

if not cpio_data:
    print("Failed to decompress!")
    sys.exit(1)

with open('ramdisk_full.cpio', 'wb') as f:
    f.write(cpio_data)
print(f"Extracted {len(cpio_data)} bytes of CPIO.")
