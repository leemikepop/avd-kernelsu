import sys
try:
    import lz4.block
except ImportError:
    print("lz4 not installed in python")
    sys.exit(1)

data = open(sys.argv[1],'rb').read()
pos = 4
out_raw = b''
out_dec = b''
while pos < len(data):
    bsz = int.from_bytes(data[pos:pos+4], 'little')
    pos += 4
    if bsz == 0 or bsz > len(data): break
    chunk = data[pos:pos+bsz]
    out_raw += chunk
    
    # Try to decompress the block
    try:
        # standard lz4 legacy block size is usually 8MB uncompressed max
        dec = lz4.block.decompress(chunk, uncompressed_size=8*1024*1024)
        out_dec += dec
    except Exception as e:
        print(f"Error at pos {pos}: {e}")
        break
    
    pos += bsz

print(f"Decompressed size: {len(out_dec)}")
open('test.lz4.dec','wb').write(out_dec)
