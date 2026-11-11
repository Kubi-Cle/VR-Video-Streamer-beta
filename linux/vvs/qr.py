"""QR codes for the links, so a phone can open one by pointing its camera at the screen.

A port of app/QrCode.cs: text as bytes, medium error correction (15% of the code can be covered or misread),
versions 1 to 40, the mask with the fewest problem patterns. Follows the layout in ISO/IEC 18004 as described
by Project Nayuki's reference generator.
"""

# Per version (1-40), for medium error correction
ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28,
                 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28,
          29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
MEDIUM_FORMAT_BITS = 0


def encode(text):
    """Returns the code as rows of booleans (True = dark), indexed [y][x]."""
    data_bytes = text.encode("utf-8")
    version = next((v for v in range(1, 41)
                    if 4 + (8 if v < 10 else 16) + len(data_bytes) * 8 <= _data_codewords(v) * 8), None)
    if version is None:
        raise ValueError("Too long for a QR code")

    # Byte mode, length, the bytes, then end marker and padding
    bits = []
    _append(bits, 4, 4)
    _append(bits, len(data_bytes), 8 if version < 10 else 16)
    for b in data_bytes:
        _append(bits, b, 8)
    capacity = _data_codewords(version) * 8
    _append(bits, 0, min(4, capacity - len(bits)))
    _append(bits, 0, (8 - len(bits) % 8) % 8)
    pad = 0xEC
    while len(bits) < capacity:
        _append(bits, pad, 8)
        pad ^= 0xEC ^ 0x11
    data = bytearray(len(bits) // 8)
    for i, bit in enumerate(bits):
        if bit:
            data[i >> 3] |= 0x80 >> (i & 7)

    qr = _Matrix(version)
    qr.draw_function_patterns()
    qr.draw_codewords(_add_ecc_and_interleave(data, version))

    # Try every mask and keep the one with the lowest penalty
    best, best_penalty = 0, None
    for mask in range(8):
        qr.apply_mask(mask)
        qr.draw_format_bits(mask)
        penalty = qr.penalty()
        if best_penalty is None or penalty < best_penalty:
            best, best_penalty = mask, penalty
        qr.apply_mask(mask)  # undoes it
    qr.apply_mask(best)
    qr.draw_format_bits(best)
    return qr.modules


def to_svg(modules, border=4):
    """Black on white with the 4-module quiet zone scanners need around it."""
    n = len(modules)
    size = n + border * 2
    path = "".join(f"M{x + border},{y + border}h1v1h-1z" for y in range(n) for x in range(n) if modules[y][x])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" shape-rendering="crispEdges">'
            f'<rect width="100%" height="100%" fill="#fff"/><path d="{path}" fill="#000"/></svg>')


def _append(bits, value, count):
    for i in range(count - 1, -1, -1):
        bits.append(((value >> i) & 1) != 0)


def _raw_data_modules(version):
    result = (16 * version + 128) * version + 64
    if version >= 2:
        align = version // 7 + 2
        result -= (25 * align - 10) * align - 55
        if version >= 7:
            result -= 36
    return result


def _data_codewords(version):
    return _raw_data_modules(version) // 8 - ECC_PER_BLOCK[version] * BLOCKS[version]


def _add_ecc_and_interleave(data, version):
    num_blocks, ecc_len = BLOCKS[version], ECC_PER_BLOCK[version]
    raw = _raw_data_modules(version) // 8
    num_short = num_blocks - raw % num_blocks
    short_len = raw // num_blocks
    divisor = _rs_divisor(ecc_len)
    blocks, k = [], 0
    for i in range(num_blocks):
        dat_len = short_len - ecc_len + (0 if i < num_short else 1)
        dat = data[k:k + dat_len]
        k += dat_len
        block = bytearray(short_len + 1)
        block[:dat_len] = dat
        block[len(block) - ecc_len:] = _rs_remainder(dat, divisor)
        blocks.append(block)
    result = bytearray()
    for i in range(len(blocks[0])):
        for j in range(num_blocks):
            if i != short_len - ecc_len or j >= num_short:
                result.append(blocks[j][i])
    return result


def _rs_divisor(degree):
    result = [0] * degree
    result[degree - 1] = 1
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _multiply(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _multiply(root, 2)
    return result


def _rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result[0]
        result = result[1:] + [0]
        for i in range(len(result)):
            result[i] ^= _multiply(divisor[i], factor)
    return bytes(result)


def _multiply(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z & 0xFF


class _Matrix:
    def __init__(self, version):
        self.version = version
        self.size = version * 4 + 17
        self.modules = [[False] * self.size for _ in range(self.size)]
        self.is_function = [[False] * self.size for _ in range(self.size)]

    def _set(self, x, y, dark):
        self.modules[y][x] = dark
        self.is_function[y][x] = True

    def draw_function_patterns(self):
        size = self.size
        for i in range(size):
            self._set(6, i, i % 2 == 0)
            self._set(i, 6, i % 2 == 0)
        self._finder(3, 3)
        self._finder(size - 4, 3)
        self._finder(3, size - 4)
        align = self._alignment_positions()
        last = len(align) - 1
        for i in range(len(align)):
            for j in range(len(align)):
                if not ((i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0)):
                    self._alignment(align[i], align[j])
        self.draw_format_bits(0)  # reserves the area; drawn for real once the mask is chosen
        if self.version >= 7:
            rem = self.version
            for _ in range(12):
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
            bits = self.version << 12 | rem
            for i in range(18):
                bit = ((bits >> i) & 1) != 0
                a, b = size - 11 + i % 3, i // 3
                self._set(a, b, bit)
                self._set(b, a, bit)

    def _finder(self, x, y):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                dist = max(abs(dx), abs(dy))
                xx, yy = x + dx, y + dy
                if 0 <= xx < self.size and 0 <= yy < self.size:
                    self._set(xx, yy, dist != 2 and dist != 4)

    def _alignment(self, x, y):
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                self._set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1)

    def _alignment_positions(self):
        if self.version == 1:
            return []
        count = self.version // 7 + 2
        step = (self.version * 8 + count * 3 + 5) // (count * 4 - 4) * 2
        result = [0] * count
        result[0] = 6
        pos = self.size - 7
        for i in range(count - 1, 0, -1):
            result[i] = pos
            pos -= step
        return result

    def draw_format_bits(self, mask):
        size = self.size
        data = MEDIUM_FORMAT_BITS << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412

        def bit(i):
            return ((bits >> i) & 1) != 0

        for i in range(6):
            self._set(8, i, bit(i))
        self._set(8, 7, bit(6))
        self._set(8, 8, bit(7))
        self._set(7, 8, bit(8))
        for i in range(9, 15):
            self._set(14 - i, 8, bit(i))
        for i in range(8):
            self._set(size - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self._set(8, size - 15 + i, bit(i))
        self._set(8, size - 8, True)

    def draw_codewords(self, data):
        size, i = self.size, 0
        right = size - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(size):
                for j in range(2):
                    x = right - j
                    upward = ((right + 1) & 2) == 0
                    y = size - 1 - vert if upward else vert
                    if not self.is_function[y][x] and i < len(data) * 8:
                        self.modules[y][x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0
                        i += 1
            right -= 2

    def apply_mask(self, mask):
        masks = [
            lambda x, y: (x + y) % 2 == 0,
            lambda x, y: y % 2 == 0,
            lambda x, y: x % 3 == 0,
            lambda x, y: (x + y) % 3 == 0,
            lambda x, y: (x // 3 + y // 2) % 2 == 0,
            lambda x, y: x * y % 2 + x * y % 3 == 0,
            lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
            lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
        ]
        invert = masks[mask]
        for y in range(self.size):
            for x in range(self.size):
                if not self.is_function[y][x] and invert(x, y):
                    self.modules[y][x] = not self.modules[y][x]

    def penalty(self):
        """Long runs, 2x2 blocks and an uneven balance of dark and light all make a code harder to scan."""
        size, m, result = self.size, self.modules, 0
        for line in m + [list(col) for col in zip(*m)]:
            run, last = 0, None
            for b, cell in enumerate(line):
                if b > 0 and cell == last:
                    run += 1
                    if run == 5:
                        result += 3
                    elif run > 5:
                        result += 1
                else:
                    run = 1
                last = cell
        for y in range(size - 1):
            for x in range(size - 1):
                c = m[y][x]
                if c == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    result += 3
        dark = sum(sum(row) for row in m)
        total = size * size
        k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
        return result + max(0, k) * 10
