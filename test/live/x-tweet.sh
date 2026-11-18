#!/usr/bin/env bash
# A live check, run by hand (it reaches x.com, which no suite and no nix
# build may): the built fetcher brings lux's tweet as Danbooru would, and
# the stripper takes its image.
#
#	nix-shell --run test/live/x-tweet.sh
#
# What it should say of the tweet, as of 2026-11-18. X may change what its
# embeds' endpoint answers; when this fails, that is the first suspect.
set -euo pipefail

link=https://x.com/diluxiie/status/2038458551392182434
image=c8fd73e7bb137419d71c130468cc0d359e6ee9b134548190e197138a38e8b10a

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf '%s\n' "$link" | ike-fetch 20000000 >"$work/answer"
head -c 3 "$work/answer" | grep -qx 'ok ' || { head -n1 "$work/answer"; exit 1; }

python3 - "$work" "$image" <<'PY'
import hashlib, json, sys
work = sys.argv[1]
raw = open(f"{work}/answer", "rb").read()
line, rest = raw.split(b"\n", 1)
n = int(line.split()[1])
said = json.loads(rest[:n])
files = rest[n:]
want = {
    "site": "twitter",
    "source": "https://x.com/diluxiie/status/2038458551392182434",
    "artist": "lux",
    "artist_url": "https://x.com/diluxiie",
    "commentary": "Why isn't anything meant for him to read?",
}
for k, v in want.items():
    assert said[k] == v, (k, said[k], v)
[f] = said["files"]
assert f["url"] == "https://pbs.twimg.com/media/HEoPP8pWkAAb2zG?format=png&name=orig", f
assert f["type"] == "image/png" and f["length"] == len(files) == 44803, f
assert hashlib.sha256(files).hexdigest() == sys.argv[2], "not the image it was"
open(f"{work}/image", "wb").write(files)
print("fetched: the image, as it was")
PY

ike-strip 20000000 16384 50000000 256 <"$work/image" >"$work/stripped"
head -n1 "$work/stripped" | grep '^ok png 318 505 '
echo "ok: the tweet, its words, its author and its image, stripped"
