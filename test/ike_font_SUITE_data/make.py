# The suites' fonts, made here rather than found, so that they are ike's
# own to keep: an F and an A of rectangles, credits that must not
# survive stripping (SECRET-*), the same font credited to someone else,
# a WOFF2 with its own metadata block, and a variable one with a weight
# axis. Run with fontTools and brotli:
#	python3 make.py DIR
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import Glyph
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.ttLib.woff2 import WOFF2FlavorData


def boxes(*rects):
    pen = TTGlyphPen(None)
    for x0, y0, x1, y1 in rects:
        pen.moveTo((x0, y0))
        pen.lineTo((x0, y1))
        pen.lineTo((x1, y1))
        pen.lineTo((x1, y0))
        pen.closePath()
    return pen.glyph()


def build(path, names, vendor, variable=False):
    glyphs = [".notdef", "space", "F", "A"]
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(glyphs)
    fb.setupCharacterMap({32: "space", 70: "F", 65: "A"})
    fb.setupGlyf(
        {
            ".notdef": boxes((50, 0, 450, 700)),
            "space": Glyph(),
            "F": boxes((100, 0, 200, 700), (100, 600, 500, 700), (100, 300, 400, 380)),
            "A": boxes((100, 0, 500, 700)),
        }
    )
    fb.setupHorizontalMetrics({g: (600, 50) for g in glyphs})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable(names)
    fb.setupOS2(sTypoAscender=800, usWinAscent=800, usWinDescent=200, achVendID=vendor)
    fb.setupPost()
    if variable:
        fb.setupFvar([("wght", 100, 400, 900, "Weight")], [])
        fb.setupGvar(
            {"F": [TupleVariation({"wght": (0, 1, 1)}, [(0, 0), (0, 0), (100, 0), (100, 0)] + [(0, 0)] * 12)]}
        )
    fb.font["head"].created = fb.font["head"].modified = 3600 * 24 * 365 * 70
    fb.font.recalcTimestamp = False
    fb.save(path)


out = sys.argv[1]
credits = dict(
    familyName="Ike Test",
    styleName="Regular",
    fullName="Ike Test Regular",
    psName="IkeTest-Regular",
    copyright="SECRET-COPYRIGHT",
    designer="SECRET-DESIGNER",
    manufacturer="SECRET-MANUFACTURER",
    description="SECRET-DESCRIPTION",
    vendorURL="https://secret.example/vendor",
    designerURL="https://secret.example/designer",
    licenseDescription="SECRET-LICENSE",
    licenseInfoURL="https://secret.example/license",
)
build(out + "/font.ttf", credits, "SCRT")
build(
    out + "/font-other.ttf",
    dict(credits, copyright="SECRET-OTHER", designer="SECRET-OTHER-DESIGNER"),
    "OTHR",
)
build(
    out + "/variable.ttf",
    dict(credits, familyName="Ike Var", fullName="Ike Var Regular", psName="IkeVar-Regular"),
    "SCRT",
    variable=True,
)
woff2 = TTFont(out + "/font.ttf")
woff2.recalcTimestamp = False
woff2.flavor = "woff2"
woff2.flavorData = WOFF2FlavorData()
woff2.flavorData.metaData = b'<?xml version="1.0"?><metadata version="1.0"><credits><credit name="SECRET-META"/></credits></metadata>'
woff2.save(out + "/font.woff2")
