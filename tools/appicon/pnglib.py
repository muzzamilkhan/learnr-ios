"""Minimal PNG read/write. Stock python3 only - no PIL on this Mac."""
import struct, zlib

def read_rgba(path):
    d = open(path, 'rb').read()
    i = 8; idat = b''; plte = None; trns = None; w = h = 0; ct = bd = 0
    while i < len(d):
        ln = struct.unpack(">I", d[i:i+4])[0]
        typ = d[i+4:i+8].decode('latin1')
        data = d[i+8:i+8+ln]
        if typ == "IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", data[:10])
        elif typ == "PLTE": plte = data
        elif typ == "tRNS": trns = data
        elif typ == "IDAT": idat += data
        i += 12 + ln
    assert bd == 8, "only 8-bit supported"
    nch = {0:1, 2:3, 3:1, 4:2, 6:4}[ct]
    raw = zlib.decompress(idat)
    stride = w * nch
    rows = []; prev = bytearray(stride); pos = 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if f == 1:
            for x in range(nch, stride): line[x] = (line[x] + line[x-nch]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x-nch] if x >= nch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x-nch] if x >= nch else 0
                b = prev[x]; c = prev[x-nch] if x >= nch else 0
                pp = a + b - c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line)); prev = line
    px = bytearray(w * h * 4)
    for y in range(h):
        r = rows[y]
        for x in range(w):
            o = (y*w + x) * 4
            if ct == 3:
                idx = r[x]
                px[o:o+3] = plte[idx*3:idx*3+3]
                px[o+3] = trns[idx] if (trns and idx < len(trns)) else 255
            elif ct == 6:
                px[o:o+4] = r[x*4:x*4+4]
            elif ct == 2:
                px[o:o+3] = r[x*3:x*3+3]; px[o+3] = 255
            elif ct == 0:
                v = r[x]; px[o] = px[o+1] = px[o+2] = v; px[o+3] = 255
            elif ct == 4:
                v = r[x*2]; px[o] = px[o+1] = px[o+2] = v; px[o+3] = r[x*2+1]
    return w, h, px

def write_rgb(path, w, h, px, alpha=False):
    """px is RGBA bytes; writes truecolour (alpha=False drops the alpha channel)."""
    nch = 4 if alpha else 3
    ct = 6 if alpha else 2
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        if alpha:
            raw += px[y*w*4:(y+1)*w*4]
        else:
            row = px[y*w*4:(y+1)*w*4]
            for x in range(w):
                raw += row[x*4:x*4+3]
    def chunk(t, data):
        c = t.encode() + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk("IHDR", struct.pack(">IIBBBBB", w, h, 8, ct, 0, 0, 0))
    out += chunk("IDAT", zlib.compress(bytes(raw), 9))
    out += chunk("IEND", b'')
    open(path, 'wb').write(out)
