#!/usr/bin/env python3
"""Read back actual Vulkan glass compute shaders on controlled synthetic input.

This is an offline unit/integration suite, NOT an Android demo, HAL test, or proof
of Android scene capture. The scalar oracle checks optics/coordinate mapping;
all assertions below inspect the actual SPIR-V dispatch's RGBA8/SSBO readback.
Only Python's standard library is needed. See test_glass_shaders.sh to build/run.
"""
import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import random
import struct
import subprocess
import tempfile


@dataclass
class Frame:
    width: int
    height: int
    comp: bytes
    overlays: tuple
    bg: bytes
    count: int = 3
    level: int = 2
    bg_valid: int = 0
    bg_swizzle: int = 0
    blur_px: int = 0
    reserved: int = 0x13579BDF
    boxes: object = None  # None = dispatch detector; list = explicit apply unit input


def clamp(value, lo=0.0, hi=1.0):
    return min(max(value, lo), hi)


def paint(image, width, height, rect, rgba):
    x0, y0, x1, y1 = rect
    x0, x1 = max(0, x0), min(width, x1)
    row = bytes(rgba) * max(0, x1 - x0)
    for y in range(max(0, y0), min(height, y1)):
        start = (y * width + x0) * 4
        image[start:start + len(row)] = row


def backdrop(width, height, shift=0, ramp=False):
    data = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            if ramp:
                rgb = (20 + ((x + shift) * 11 + y * 3) % 171,
                       15 + ((x + shift) * 5 + y * 13) % 191,
                       25 + ((x + shift) * 7 + y * 11) % 181)
            else:
                rgb = (224 if ((x + shift) // 18) & 1 else 28,
                       206 if ((y + shift // 2) // 18) & 1 else 44,
                       232 if ((x + y + shift) // 22) & 1 else 36)
            off = (y * width + x) * 4
            data[off:off + 4] = bytes((*rgb, 255))
    return bytes(data)


def compose(base, overlays, count=3):
    result = bytearray(base)
    for off in range(0, len(base), 4):
        rgb = list(base[off:off + 3])
        for layer in overlays[:count]:
            a = layer[off + 3] / 255.0
            rgb = [v * (1.0 - a) + layer[off + channel]
                   for channel, v in enumerate(rgb)]
        result[off:off + 3] = bytes(int(clamp(v, 0, 255) + 0.5) for v in rgb)
    return bytes(result)


def pack_boxes(boxes):
    result = bytearray(272)
    struct.pack_into('<4I', result, 0, len(boxes), 0, 0, 0)
    for index, (rect, params) in enumerate(boxes):
        struct.pack_into('<4i', result, 16 + index * 16, *rect)
        struct.pack_into('<4f', result, 144 + index * 16, *params)
    return result


def unpack_boxes(data):
    assert len(data) == 272, 'box SSBO readback size'
    count = struct.unpack_from('<I', data)[0]
    assert count <= 8, 'detector exceeded box capacity'
    return [(struct.unpack_from('<4i', data, 16 + i * 16),
             struct.unpack_from('<4f', data, 144 + i * 16)) for i in range(count)]


def pixel(data, width, x, y):
    off = (y * width + x) * 4
    return tuple(c / 255.0 for c in data[off:off + 4])


def overlay_at(frame, x, y):
    rgb, a = (0.0, 0.0, 0.0), 0.0
    for layer in frame.overlays[:frame.count]:
        value = pixel(layer, frame.width, x, y)
        rgb = tuple(v * (1.0 - value[3]) + value[i] for i, v in enumerate(rgb))
        a += value[3] * (1.0 - a)
    return (*rgb, a)


def carrier(value):
    if value[3] < 0.94:
        return False
    colors = ((17, 25, 39), (39, 25, 17), (235, 243, 255), (255, 243, 235))
    return min(max(abs(value[i] - c[i] / 255.0) for i in range(3)) for c in colors) <= 0.036


def clean_sample(frame, x, y):
    x = int(clamp(x, 0, frame.width - 1))
    y = int(clamp(y, 0, frame.height - 1))
    ov = overlay_at(frame, x, y)
    trans = 1.0 - ov[3]
    if trans >= 0.42:
        comp = pixel(frame.comp, frame.width, x, y)
        return tuple(clamp((comp[i] - ov[i]) / trans) for i in range(3))
    if frame.bg_valid and carrier(ov):
        rgb = pixel(frame.bg, frame.width, x, y)[:3]
        return rgb[::-1] if frame.bg_swizzle else rgb
    return None


def optical_sample(frame, pos, wrong_half_pixel=False):
    texel = tuple(v - (0.0 if wrong_half_pixel else 0.5) for v in pos)
    base = tuple(math.floor(v) for v in texel)
    fract = tuple(texel[i] - base[i] for i in range(2))
    rgb = [0.0, 0.0, 0.0]
    for y in range(2):
        for x in range(2):
            weight = (fract[0] if x else 1.0 - fract[0]) * (fract[1] if y else 1.0 - fract[1])
            if weight == 0.0:
                continue
            tap = clean_sample(frame, base[0] + x, base[1] + y)
            if tap is None:
                return None
            rgb = [rgb[i] + tap[i] * weight for i in range(3)]
    return rgb


def sdf(point, half, radius):
    q = tuple(abs(point[i]) - (half[i] - radius) for i in range(2))
    return math.hypot(max(q[0], 0), max(q[1], 0)) + min(max(q), 0) - radius


def normalize(vector):
    length = math.sqrt(sum(v * v for v in vector))
    return tuple(v / length for v in vector)


def reference(frame, boxes, x, y, wrong_half_pixel=False):
    """Scalar, double-precision oracle; no shader output is used as an input."""
    off = (y * frame.width + x) * 4
    original = tuple(frame.comp[off:off + 4])
    pf = x + 0.5, y + 0.5
    hit = None
    for rect, params in boxes:
        x0, y0, x1, y1 = rect
        if x < x0 - 1 or x > x1 + 1 or y < y0 - 1 or y > y1 + 1:
            continue
        center = (0.5 * (x0 + x1), 0.5 * (y0 + y1))
        half = (0.5 * (x1 - x0), 0.5 * (y1 - y0))
        radius = min(params[0], *half)
        rel = tuple(pf[i] - center[i] for i in range(2))
        distance = sdf(rel, half, radius)
        if distance <= 0.5:
            hit = distance, rel, half, radius, max(params[1], 14.0), params[2]
    if hit is None:
        return original
    distance, rel, half, radius, bevel, kind = hit
    ov = overlay_at(frame, x, y)
    opaque_carrier = kind < 1.5 and carrier(ov)
    if ov[3] < 0.085 or (not frame.bg_valid if opaque_carrier else 1.0 - ov[3] < 0.42):
        return original
    dx = sdf((rel[0] + 1, rel[1]), half, radius) - sdf((rel[0] - 1, rel[1]), half, radius)
    dy = sdf((rel[0], rel[1] + 1), half, radius) - sdf((rel[0], rel[1] - 1), half, radius)
    grad = normalize((dx, dy)) if dx * dx + dy * dy > 1e-5 else (0.0, -1.0)
    t = clamp(-distance / bevel)
    sin_theta = clamp((1.0 - t) ** 1.65 * 0.93, 0.0, 0.93)
    rn = tuple(rel[i] / max(half[i], 1.0) for i in range(2))
    convex = tuple(v * (0.24 + 0.16 * sum(q * q for q in rn)) for v in rn)
    wave = (math.sin(rel[1] * 0.032 + rel[0] * 0.014) * 0.048 * t,
            math.cos(rel[0] * 0.032 - rel[1] * 0.014) * 0.048 * t)
    tile_tilt, tile_rim = (0.0, 0.0), 0.0
    if kind >= 1.5:
        def alpha(cx, cy):
            value = overlay_at(frame, int(clamp(cx, 0, frame.width - 1)),
                               int(clamp(cy, 0, frame.height - 1)))[3]
            return value if value <= 0.56 else 0.22
        g = alpha(x + 3, y) - alpha(x - 3, y), alpha(x, y + 3) - alpha(x, y - 3)
        gm = math.hypot(*g)
        if gm > 0.018:
            tile_tilt = tuple(-v / gm * clamp(gm * 3.4, 0.0, 0.58) for v in g)
            tile_rim = clamp(gm * 2.2, 0.0, 0.30)
    slope = tuple(grad[i] * sin_theta + convex[i] + wave[i] + tile_tilt[i] for i in range(2))
    slope_sq = sum(v * v for v in slope)
    normal = normalize((*slope, math.sqrt(max(1.0 - min(slope_sq, 0.88), 0.12))))
    eta = 1.0 / 1.54
    k = 1.0 - eta * eta * (1.0 - normal[2] * normal[2])
    factor = eta * normal[2] - math.sqrt(k)
    depth = 34.0 if frame.level == 1 else 76.0 if frame.level == 3 else 54.0
    disp = tuple(normal[i] * factor * depth for i in range(2))
    samples = [optical_sample(frame, tuple(pf[i] + disp[i] * scale for i in range(2)), wrong_half_pixel)
               for scale in (0.985, 1.0, 1.015)]
    if any(sample is None for sample in samples):
        return original
    rgb = [samples[i][i] for i in range(3)]
    blur = clamp(frame.blur_px, 0, 24)
    if blur:
        rgb = [v * 0.40 for v in rgb]
        for direction in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sample = optical_sample(frame, tuple(pf[i] + disp[i] + direction[i] * blur for i in range(2)), wrong_half_pixel)
            if sample is None:
                return original
            rgb = [rgb[i] + sample[i] * 0.15 for i in range(3)]
    luma = sum(rgb[i] * weight for i, weight in enumerate((0.2126, 0.7152, 0.0722)))
    vibrant = [clamp(luma + 1.30 * (v - luma)) for v in rgb]
    fresnel = (1.0 - normal[2]) ** 2.8 * 0.30
    light = normalize((-0.58, -0.81))
    dot = sum(normal[i] * light[i] for i in range(2))
    spec_tl = max(dot, 0.0) ** 3.5 * (1.0 - t) * 0.50
    spec_br = max(-dot, 0.0) ** 4.5 * (1.0 - t) * 0.24
    rim_t = clamp((distance + 2.4) / 2.2)
    crisp = rim_t * rim_t * (3.0 - 2.0 * rim_t) * 0.32
    glass = [clamp(vibrant[i] + fresnel + spec_tl + crisp + tile_rim * 0.65 +
                   color * (spec_br + tile_rim * 0.35))
             for i, color in enumerate((0.76, 0.88, 1.0))]
    if opaque_carrier:
        final = [glass[i] * 0.84 + ov[i] * 0.16 for i in range(3)]
    else:
        final = [glass[i] * (1.0 - ov[3]) + ov[i] for i in range(3)]
    aa = clamp(0.5 - distance)
    result = tuple(int(clamp(original[i] / 255.0 * (1.0 - aa) + final[i] * aa) * 255.0 + 0.5)
                   for i in range(3))
    return (*result, original[3])


def count_diff(a, b, threshold=0, region=None, width=0):
    count = 0
    for off in range(0, len(a), 4):
        if region and not region((off // 4) % width, (off // 4) // width):
            continue
        if sum(abs(a[off + c] - b[off + c]) for c in range(3)) > threshold:
            count += 1
    return count


def check_exact_mask(frame, output, predicate, label):
    errors, checked = 0, 0
    for y in range(frame.height):
        for x in range(frame.width):
            if predicate(x, y):
                checked += 1
                off = (y * frame.width + x) * 4
                errors += output[off:off + 4] != frame.comp[off:off + 4]
    assert checked and errors == 0, '%s: %d changed of %d protected pixels' % (label, errors, checked)
    return checked


class Suite:
    def __init__(self, args):
        self.runner = Path(args.runner).resolve()
        self.shaders = Path(args.shaders).resolve()
        root = Path(args.work_dir).resolve()
        root.mkdir(parents=True, exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix='synthetic-', dir=root))
        self.cases = self.frames = self.oracle_points = 0
        print('Controlled synthetic Vulkan shader tests; NOT Android integration evidence.', flush=True)
        print('Readbacks: ' + str(self.work), flush=True)

    def dispatch(self, name, frames):
        directory = self.work / name
        directory.mkdir()
        width, height = frames[0].width, frames[0].height
        for number, frame in enumerate(frames):
            assert (frame.width, frame.height) == (width, height)
            prefix = directory / ('frame-%03d' % number)
            def write(suffix, data):
                Path(str(prefix) + '.' + suffix).write_bytes(data)
            write('pc', struct.pack('<8i', width, height, frame.count, frame.level,
                                    frame.bg_valid, frame.bg_swizzle, frame.blur_px, frame.reserved))
            write('comp.rgba', frame.comp)
            for i in range(3):
                write('ov%d.rgba' % i, frame.overlays[i])
            write('bg.rgba', frame.bg)
            if frame.boxes is not None:
                write('boxes.in', pack_boxes(frame.boxes))
        subprocess.run([str(self.runner), str(self.shaders), str(directory), str(width), str(height),
                        str(len(frames)), '--synthetic-input'], check=True)
        outputs, boxes = [], []
        for number, frame in enumerate(frames):
            prefix = directory / ('frame-%03d' % number)
            data = Path(str(prefix) + '.out.rgba').read_bytes()
            assert len(data) == width * height * 4, name + ': output byte count'
            assert data[3::4] == frame.comp[3::4], name + ': output alpha changed'
            outputs.append(data)
            boxes.append(unpack_boxes(Path(str(prefix) + '.boxes.out').read_bytes()))
        self.cases += 1
        self.frames += len(frames)
        return outputs, boxes

    def oracle(self, frame, output, boxes, points):
        max_error = 0
        half_pixel_sensitive = 0
        for x, y in points:
            expected = reference(frame, boxes, x, y)
            off = (y * frame.width + x) * 4
            actual = tuple(output[off:off + 4])
            error = max(abs(a - b) for a, b in zip(actual, expected))
            max_error = max(error, max_error)
            assert error <= 2, 'scalar oracle (%d,%d): got %r expected %r' % (x, y, actual, expected)
            wrong = reference(frame, boxes, x, y, wrong_half_pixel=True)
            half_pixel_sensitive += max(abs(a - b) for a, b in zip(expected, wrong)) > 4
        self.oracle_points += len(points)
        return max_error, half_pixel_sensitive

    def moving_scene(self):
        width, height = 641, 483  # deliberately not workgroup or detector-grid multiples
        layers = [bytearray(width * height * 4) for _ in range(3)]
        paint(layers[0], width, height, (36, 56, 288, 356), (3, 4, 6, 38))
        paint(layers[0], width, height, (80, 412, 560, 468), (17, 25, 39, 255))
        paint(layers[0], width, height, (108, 428, 126, 450), (66, 133, 244, 255))
        paint(layers[0], width, height, (120, 160, 146, 186), (234, 67, 53, 255))
        paint(layers[0], width, height, (180, 280, 196, 300), (0, 0, 0, 0))  # transparent interior hole
        paint(layers[1], width, height, (336, 56, 604, 356), (3, 4, 8, 38))
        paint(layers[1], width, height, (360, 160, 480, 220), (10, 15, 24, 68))
        paint(layers[1], width, height, (420, 104, 520, 122), (250, 252, 255, 255))
        paint(layers[1], width, height, (512, 252, 560, 255), (240, 240, 245, 255))
        paint(layers[2], width, height, (100, 200, 260, 260), (2, 5, 3, 26))
        layers = tuple(bytes(layer) for layer in layers)
        frames = []
        for i, shift in enumerate((0, 19, 19, 0)):
            actual_bg = backdrop(width, height, shift)
            poison = bytes((255, 0, 220 if i & 1 else 0, 255)) * (width * height)
            frames.append(Frame(width, height, compose(actual_bg, layers), layers, poison,
                                blur_px=4, reserved=i))
        outputs, boxes = self.dispatch('moving-real-comp', frames)
        assert outputs[0] == outputs[3], 'same scene differs after intervening moving frames (feedback/history)'
        assert outputs[1] == outputs[2], 'bg_valid=0 consumed unrelated u_bg or reserved PC member'
        assert all(len(value) == 2 for value in boxes), 'expected just App Menu and CC; unvalidated opaque taskbar must not detect'
        outside_checked = icons_checked = 0
        for frame, output in zip(frames, outputs):
            outside_checked += check_exact_mask(frame, output,
                lambda x, y: all(layer[(y * width + x) * 4 + 3] == 0 for layer in layers), 'outside/transparent gaps')
            icons_checked += check_exact_mask(frame, output,
                lambda x, y: any(layer[(y * width + x) * 4 + 3] == 255 for layer in layers), 'opaque icons/taskbar')
        panel = lambda x, y: (36 <= x < 288 or 336 <= x < 604) and 56 <= y < 356
        changed = count_diff(outputs[0], frames[0].comp, 14, panel, width)
        moving = count_diff(outputs[0], outputs[1], 14, panel, width)
        assert changed > 10000 and moving > 10000, 'glass did not track changing current composition'
        inner = count_diff(outputs[0], frames[0].comp, 14,
                           lambda x, y: 370 <= x < 470 and 170 <= y < 210, width)
        assert inner > 500, 'inner QS tile optics inactive'
        points = [(x, y) for x in (44, 72, 96, 156, 204, 268, 344, 388, 452, 540, 592)
                  for y in (64, 88, 136, 192, 212, 256, 320, 348)]
        for index in (0, 1):
            self.oracle(frames[index], outputs[index], boxes[index], points)
        print('PASS moving composition: refracted=%d moving=%d inner_QS=%d outside_exact=%d opaque_exact=%d; no feedback or invalid-bg dependence' %
              (changed, moving, inner, outside_checked, icons_checked), flush=True)

    def opaque_gating(self):
        width, height = 257, 193
        overlay = bytearray(width * height * 4)
        paint(overlay, width, height, (20, 156, 236, 192), (17, 25, 39, 255))
        paint(overlay, width, height, (60, 164, 78, 184), (66, 133, 244, 255))
        empty = bytes(width * height * 4)
        layers = (bytes(overlay), empty, empty)
        actual = backdrop(width, height)
        comp = compose(actual, layers)
        manual = [((20, 156, 236, 192), (12.0, 22.0, 1.0, 0.0))]
        poison_a = bytes((255, 0, 0, 255)) * (width * height)
        poison_b = bytes((0, 255, 0, 255)) * (width * height)
        frames = [Frame(width, height, comp, layers, poison_a),
                  Frame(width, height, comp, layers, poison_b),
                  Frame(width, height, comp, layers, poison_a, boxes=manual)]
        unknown = bytearray(overlay)
        paint(unknown, width, height, (20, 156, 236, 192), (70, 65, 90, 255))
        unknown_layers = (bytes(unknown), empty, empty)
        frames.append(Frame(width, height, compose(actual, unknown_layers), unknown_layers,
                            poison_a, bg_valid=1, boxes=manual))
        frames.append(Frame(width, height, comp, layers, actual, bg_valid=1))
        swapped = bytearray(actual)
        swapped[0::4], swapped[2::4] = actual[2::4], actual[0::4]
        frames.append(Frame(width, height, comp, layers, bytes(swapped), bg_valid=1, bg_swizzle=1))
        moved = backdrop(width, height, 13)
        frames.append(Frame(width, height, compose(moved, layers), layers, moved, bg_valid=1))
        outputs, boxes = self.dispatch('opaque-backdrop-contract', frames)
        assert all(outputs[i] == frames[i].comp for i in range(4)), 'opaque or unknown carrier guessed a backdrop'
        assert not boxes[0] and not boxes[1], 'unvalidated opaque dock detected'
        assert outputs[4] == outputs[5], 'validated backdrop R/B swizzle mismatch'
        assert len(boxes[4]) == len(boxes[5]) == len(boxes[6]) == 1, 'known-scene dock detection'
        region = lambda x, y: 20 <= x < 236 and 156 <= y < 192
        changed = count_diff(outputs[4], frames[4].comp, 14, region, width)
        moving = count_diff(outputs[4], outputs[6], 14, region, width)
        assert changed > 2000 and moving > 1000, 'explicit known scene not sampled live'
        for index in (4, 5, 6):
            check_exact_mask(frames[index], outputs[index], lambda x, y: not region(x, y), 'outside known carrier')
            check_exact_mask(frames[index], outputs[index], lambda x, y: 60 <= x < 78 and 164 <= y < 184, 'known-carrier icon')
        points = [(x, y) for x in range(25, 234, 13) for y in range(158, 191, 4)]
        self.oracle(frames[4], outputs[4], boxes[4], points)
        print('PASS opaque contract: invalid/unknown=bit-exact pass-through (including forced apply box); explicit known-scene refracted=%d moving=%d swizzle=exact' %
              (changed, moving), flush=True)

    def unavailable_samples(self):
        width, height = 97, 81
        empty = bytes(width * height * 4)
        overlay = bytearray(bytes((70, 65, 90, 255)) * (width * height))
        # Current pixel is invertible, but its displaced/blur footprint is not.
        paint(overlay, width, height, (49, 40, 50, 41), (3, 4, 6, 38))
        layers = (bytes(overlay), empty, empty)
        base = backdrop(width, height)
        comp = compose(base, layers)
        boxes = [((-20, -15, 100, 90), (12.0, 34.0, 1.0, 0.0))]
        frames = [Frame(width, height, comp, layers, base, bg_valid=valid, blur_px=blur, boxes=boxes)
                  for valid, blur in ((0, 0), (0, 8), (1, 8))]
        outputs, _ = self.dispatch('noninvertible-footprint', frames)
        assert all(out == comp for out in outputs), 'unavailable footprint used probes, u_bg fallback, or recursive comp'
        for frame in frames:
            assert reference(frame, boxes, 49, 40) == tuple(comp[(40 * width + 49) * 4:(40 * width + 49) * 4 + 4])
        print('PASS unavailable optical samples: exact original returned, even with bg_valid=1 behind unrelated opaque pixels', flush=True)

    def clipping_coordinates(self):
        width, height = 131, 99
        base = backdrop(width, height, ramp=True)
        layer = bytes((5, 9, 15, 51)) * (width * height)
        layers = (layer, bytes(width * height * 4), bytes(width * height * 4))
        comp = bytearray(compose(base, layers))
        # Composition alpha is not assumed to be 1 by the output path.
        comp[3::4] = bytes(160 + (i % 96) for i in range(width * height))
        poison = bytes((255, 0, 255, 255)) * (width * height)
        specifications = [((-25, -19, 105, 89), 2, 0),
                          ((-25, -19, 105, 89), 2, 6),
                          ((29, 17, 164, 125), 3, 0),
                          ((-50, -40, 181, 139), 1, 0),
                          ((-25, -19, 105, 89), 2, -8),
                          ((-25, -19, 105, 89), 2, 24),
                          ((-25, -19, 105, 89), 2, 100)]
        frames = [Frame(width, height, bytes(comp), layers, poison, level=level, bg_valid=1,
                        blur_px=blur, boxes=[(rect, (17.0, 34.0, 1.0, 0.0))])
                  for rect, level, blur in specifications]
        outputs, boxes = self.dispatch('clipped-optical-coordinates', frames)
        assert outputs[0] == outputs[4], 'negative blur radius must clamp to zero'
        assert outputs[5] == outputs[6], 'large blur radius must clamp to 24'
        assert count_diff(outputs[0], outputs[1], 4) > 2000, 'blur_px has no visible dynamic effect'
        rng = random.Random(0xF1DE)
        points = {(rng.randrange(width), rng.randrange(height)) for _ in range(400)}
        points.update((x, y) for x in (0, 1, 2, 64, 128, 129, 130) for y in (0, 1, 2, 48, 96, 97, 98))
        points = sorted(points)
        worst, sensitive = 0, 0
        for frame, output, detected in zip(frames, outputs, boxes):
            error, wrong = self.oracle(frame, output, detected, points)
            worst, sensitive = max(worst, error), sensitive + wrong
            rect, params = detected[0]
            center = ((rect[0] + rect[2]) * 0.5, (rect[1] + rect[3]) * 0.5)
            half = ((rect[2] - rect[0]) * 0.5, (rect[3] - rect[1]) * 0.5)
            radius = min(params[0], *half)
            def outside(x, y):
                return sdf((x + 0.5 - center[0], y + 0.5 - center[1]), half, radius) > 0.5
            if any(outside(x, y) for x in (0, width - 1) for y in (0, height - 1)):
                check_exact_mask(frame, output, outside, 'outside clipped SDF')
        assert sensitive > 500, 'oracle fixtures do not distinguish the old half-pixel coordinate error'
        print('PASS clipped edges/odd dimensions/blur/alpha: scalar max_error=%d/255; %d oracle points reject missing -0.5 texel-centre conversion' %
              (worst, sensitive), flush=True)

    def tiny_empty(self):
        for width, height in ((1, 1), (3, 5), (17, 19)):
            base = backdrop(width, height)
            empty = bytes(width * height * 4)
            layers = (empty, empty, empty)
            ignored = (bytes((17, 25, 39, 255)) * (width * height), empty, empty)
            frames = [Frame(width, height, base, layers, base, bg_valid=1),
                      Frame(width, height, base, ignored, base, count=0, boxes=[])]
            outputs, boxes = self.dispatch('empty-%dx%d' % (width, height), frames)
            assert outputs == [base, base] and not any(boxes), 'empty/tiny inputs must copy exactly'
        print('PASS tiny images, no overlays and empty boxes: bit-exact pass-through', flush=True)

    def run(self):
        self.moving_scene()
        self.opaque_gating()
        self.unavailable_samples()
        self.clipping_coordinates()
        self.tiny_empty()
        print('GLASS_SHADER_TEST_PASS: %d cases, %d actual compute frames, %d scalar-oracle pixels; controlled synthetic input only' %
              (self.cases, self.frames, self.oracle_points), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', required=True)
    parser.add_argument('--shaders', required=True)
    parser.add_argument('--work-dir', required=True)
    args = parser.parse_args()
    Suite(args).run()


if __name__ == '__main__':
    main()
