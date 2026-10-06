"""Render the production FBInk text bands locally for visual review.

Pillow and FBInk use different font rasterizers; sizes use the same TrueType
ascent/descent scaling. The physical Kindle remains the final layout check.
"""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent


def em_scale(path):
    data = path.read_bytes()
    count = struct.unpack_from('>H', data, 4)[0]
    tables = {}
    for i in range(count):
        tag, _, offset, size = struct.unpack_from('>4sIII', data, 12 + i * 16)
        tables[tag] = offset
    units = struct.unpack_from('>H', data, tables[b'head'] + 18)[0]
    ascent, descent = struct.unpack_from('>hh', data, tables[b'hhea'] + 4)
    return units / (ascent - descent)


def main():
    state = Path(sys.argv[1])
    output = Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / 'weather'
        shutil.copytree(ROOT / 'kindle-weather', base)
        shutil.copytree(state, base / 'state', dirs_exist_ok=True)
        mock = Path(tmp) / 'fbink'
        ops = Path(tmp) / 'ops.jsonl'
        mock.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['PREVIEW_OPS'], 'a') as out:
    out.write(json.dumps(sys.argv[1:]) + '\\n')
''')
        mock.chmod(0o755)
        subprocess.run(['sh', str(base / 'display.sh'), '--paint', str(mock)],
                       check=True, env={**os.environ, 'WEATHER_BASE': str(base),
                                        'PREVIEW_OPS': str(ops)})
        image = Image.new('L', (1072, 1448), 255)
        draw = ImageDraw.Draw(image)
        for line in ops.read_text().splitlines():
            args = json.loads(line)
            if '-t' not in args:
                continue
            opts = dict(item.split('=', 1) for item in args[args.index('-t') + 1].split(',')
                        if '=' in item)
            font_path = Path(opts['regular'])
            px = int(opts['px'])
            font = ImageFont.truetype(str(font_path), round(px * em_scale(font_path)))
            top, left, bottom, right = (int(opts[key]) for key in ('top', 'left', 'bottom', 'right'))
            width = 1072 - left - right
            height = 1448 - top - bottom
            text = args[-1]
            lines = []
            for paragraph in text.splitlines():
                current = ''
                for word in paragraph.split():
                    candidate = (current + ' ' + word).strip()
                    if current and draw.textlength(candidate, font=font) > width:
                        lines.append(current)
                        current = word
                    else:
                        current = candidate
                lines.append(current)
            if len(lines) * px > height:
                raise ValueError(f'Band too short for {text!r}: {len(lines)} lines, {height}px')
            for index, value in enumerate(lines):
                if draw.textlength(value, font=font) > width:
                    raise ValueError(f'Text exceeds band width: {value!r}')
                draw.text((left + width / 2, top + index * px), value,
                          font=font, fill=0, anchor='mt')
        output.parent.mkdir(exist_ok=True)
        image.save(output)
        print(output)


if __name__ == '__main__':
    main()
