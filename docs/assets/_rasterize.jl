# Rasterize / resize logo assets to the pre-rendered banner heights the
# GUI expects (`<name>_28.png`, `_40.png`, `_84.png`, `_120.png`).
# Run from the project root:
#   julia --project=. docs/assets/_rasterize.jl
#
# History note: this script used to pull `Gtk4.Rsvg` + `Gtk4.Cairo` to
# rasterize SVG sources. As of Gtk4.jl ≥ 0.7 those sub-modules were
# dropped from the package's public API, so we now do everything through
# `GdkPixbufLib`, which can both read SVG/PNG and resize bitmaps in one
# call (`Pixbuf_new_from_file_at_size`).

using Gtk4
using Gtk4.GdkPixbufLib

const HERE = @__DIR__

# Load `src_path`, resize so the longest edge fits within (width=∞, height=h),
# preserving aspect ratio, then save to `dst_path` as PNG. GdkPixbuf's
# `_new_from_file_at_size` interprets the dimensions as a bounding box
# when called with (-1, h) — the SVG/PNG renderer chooses a width that
# preserves aspect.
function resize_to_height(src_path::String, dst_path::String, h::Int)
    pb = GdkPixbufLib.G_.Pixbuf_new_from_file_at_size(src_path, -1, h)
    GdkPixbufLib.G_.savev(pb, dst_path, "png", String[], String[])
    println("  ", lpad(filesize(dst_path), 7), " B  ", basename(dst_path))
end

# Sources → output basename (the GUI then appends `_<NN>.png` per size).
# Each tuple is (source_filename, basename_used_by_GUI).
sources = [
    ("GaiaSeis_icon.png",     "GaiaSeis_icon"),
    ("DeformingGaia_logo.png", "DeformingGaia_logo"),
    ("CRL-logo.png",          "CRL_logo"),
]

for (src, base) in sources
    src_path = joinpath(HERE, src)
    isfile(src_path) || (@warn "missing source"; continue)
    for h in (28, 40, 56, 84, 120)
        resize_to_height(src_path, joinpath(HERE, "$(base)_$(h).png"), h)
    end
end

# -------------------------------------------------------------------------
# Windows .ico container: build a multi-resolution gaiaseis.ico from a set
# of square PNGs.  GdkPixbuf's bundled loader set has no ICO encoder, so we
# assemble the container by hand (the format is a short fixed header + a
# directory of entries + the PNG payloads back-to-back).  Modern Windows
# (Vista+) accepts PNG-embedded ICOs, which keeps the file tiny vs. the
# legacy BMP/AND-mask encoding.
#
# Format reference:
#   ICONDIR     (6 bytes): reserved(2)=0, type(2)=1, count(2)=N
#   ICONDIRENT  (16 bytes per image):
#     width(1) (0 = 256), height(1) (0 = 256), palette(1)=0,
#     reserved(1)=0, planes(2)=1, bitcount(2)=32,
#     image_size(4), offset(4)
#   image bytes... (PNG file content)
function _square_png(svg_path::String, png_path::String, edge::Int)
    pb = GdkPixbufLib.G_.Pixbuf_new_from_file_at_size(svg_path, edge, edge)
    GdkPixbufLib.G_.savev(pb, png_path, "png", String[], String[])
end

function build_ico(svg_src::String, dst_ico::String, sizes::Vector{Int})
    # 1. rasterize each size as a temporary PNG in memory (write to tmpdir).
    payloads = Vector{UInt8}[]
    tmpdir = mktempdir()
    for e in sizes
        p = joinpath(tmpdir, "gaiaseis_$(e).png")
        _square_png(svg_src, p, e)
        push!(payloads, read(p))
    end

    # 2. compute header + directory + offsets
    n = length(sizes)
    header_size = 6 + 16 * n
    offsets = Int[]
    cur = header_size
    for buf in payloads
        push!(offsets, cur)
        cur += length(buf)
    end

    # 3. write the .ico file
    open(dst_ico, "w") do io
        # ICONDIR
        write(io, UInt16(0))   # reserved
        write(io, UInt16(1))   # type = 1 (icon)
        write(io, UInt16(n))
        # ICONDIRENTRY * n
        for (i, e) in enumerate(sizes)
            write(io, UInt8(e == 256 ? 0 : e))   # width
            write(io, UInt8(e == 256 ? 0 : e))   # height
            write(io, UInt8(0))                  # palette
            write(io, UInt8(0))                  # reserved
            write(io, UInt16(1))                 # planes
            write(io, UInt16(32))                # bitcount
            write(io, UInt32(length(payloads[i])))
            write(io, UInt32(offsets[i]))
        end
        # payloads
        for buf in payloads
            write(io, buf)
        end
    end
    println("  ", lpad(filesize(dst_ico), 7), " B  ", basename(dst_ico),
            "  (", join(sizes, "/"), " px)")
end

# gaiaseis.ico — the file Win32's `LoadImageW` reads to get the per-HWND
# icon used by the Windows taskbar / Alt-Tab / title bar.
build_ico(joinpath(HERE, "GaiaSeis_icon.svg"),
          joinpath(HERE, "icons", "gaiaseis.ico"),
          [16, 24, 32, 48, 64, 128, 256])
