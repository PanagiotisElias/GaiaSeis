"""
Build NtripClient_Manual.docx from MANUAL.md.

Pipeline:
1. Tweak pandoc's default reference docx — switch body font to Cambria,
   code to Consolas, set page numbers in the footer.
2. Run pandoc to convert MANUAL.md → main_body.docx using the styled reference.
3. Build a cover-page docx with title block + funding line.
4. Insert a TOC field after the cover.
5. Concatenate cover + TOC + body into the final NtripClient_Manual.docx.

Requires `pypandoc-binary` and `python-docx`.
"""

import os
import shutil
import subprocess
from copy import deepcopy
from pathlib import Path

import pypandoc
from docx import Document
from docx.shared import Pt, Cm, Inches, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml.ns import qn, nsmap
from docx.oxml import OxmlElement

ROOT          = Path(__file__).resolve().parent
MD_FILE       = ROOT / "MANUAL.md"
MD_STRIPPED   = ROOT / "_manual_body.md"
OUT_DOCX      = ROOT / "GaiaSeis_Manual.docx"
REF_DOCX      = ROOT / "_ref.docx"
BODY_DOCX     = ROOT / "_body.docx"
GAIASEIS_LOGO = ROOT / "assets" / "GaiaSeis_logo.png"          # software mark + wordmark
DGL_LOGO      = ROOT / "assets" / "DeformingGaia_logo.png"     # parent-lab oval


# ---------------------------------------------------------------------------
# Step 0. Strip the markdown's own title block + TOC so they don't duplicate
#         the cover page and the Word-native TOC field we'll insert later.
# ---------------------------------------------------------------------------

def strip_markdown_preamble():
    """
    Remove everything before `## 1. Introduction` (title, metadata, MD TOC).
    Write the result to `_manual_body.md` for pandoc to consume.
    """
    txt = MD_FILE.read_text(encoding="utf-8")
    marker = "## 1. Introduction"
    idx = txt.find(marker)
    if idx == -1:
        raise SystemExit(f"Could not find '{marker}' in {MD_FILE}")
    stripped = txt[idx:]
    MD_STRIPPED.write_text(stripped, encoding="utf-8")


# ---------------------------------------------------------------------------
# Step 1. Customise pandoc's reference docx — fonts + footer page numbers.
# ---------------------------------------------------------------------------

def customise_reference():
    """Edit `_ref.docx` so body = Cambria, code = Consolas, footer = page no."""
    doc = Document(str(REF_DOCX))

    def set_font(style_name, font, size_pt=None):
        try:
            style = doc.styles[style_name]
        except KeyError:
            return
        rpr = style.element.find(qn("w:rPr"))
        if rpr is None:
            rpr = OxmlElement("w:rPr")
            style.element.insert(0, rpr)
        for tag in list(rpr):
            if tag.tag == qn("w:rFonts"):
                rpr.remove(tag)
        rfonts = OxmlElement("w:rFonts")
        rfonts.set(qn("w:ascii"),    font)
        rfonts.set(qn("w:hAnsi"),    font)
        rfonts.set(qn("w:cs"),       font)
        rfonts.set(qn("w:eastAsia"), font)
        rpr.append(rfonts)
        if size_pt is not None:
            for tag in list(rpr):
                if tag.tag in (qn("w:sz"), qn("w:szCs")):
                    rpr.remove(tag)
            sz = OxmlElement("w:sz");   sz.set(qn("w:val"),  str(int(size_pt * 2)))
            szc = OxmlElement("w:szCs"); szc.set(qn("w:val"), str(int(size_pt * 2)))
            rpr.append(sz); rpr.append(szc)

    # Body — Cambria 11
    set_font("Normal", "Cambria", 11)
    # Headings — same family for visual unity
    for hn in ("Heading 1", "Heading 2", "Heading 3", "Heading 4"):
        set_font(hn, "Cambria")
    # Code blocks + inline code — Consolas
    for name in ("Source Code", "Verbatim Char", "Code"):
        try:
            doc.styles[name]
            set_font(name, "Consolas", 9)
        except KeyError:
            pass

    # Add page-number footer to the default section.
    section = doc.sections[0]
    footer  = section.footer
    p = footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    # Clear any existing content
    for r in list(p.runs):
        p._p.remove(r._r)
    run = p.add_run("Page ")
    fldChar1 = OxmlElement("w:fldChar"); fldChar1.set(qn("w:fldCharType"), "begin")
    instrText = OxmlElement("w:instrText"); instrText.set(qn("xml:space"), "preserve")
    instrText.text = "PAGE \\* MERGEFORMAT"
    fldChar2 = OxmlElement("w:fldChar"); fldChar2.set(qn("w:fldCharType"), "end")
    run._r.append(fldChar1)
    run._r.append(instrText)
    run._r.append(fldChar2)
    run2 = p.add_run(" of ")
    fldChar3 = OxmlElement("w:fldChar"); fldChar3.set(qn("w:fldCharType"), "begin")
    instrText2 = OxmlElement("w:instrText"); instrText2.set(qn("xml:space"), "preserve")
    instrText2.text = "NUMPAGES \\* MERGEFORMAT"
    fldChar4 = OxmlElement("w:fldChar"); fldChar4.set(qn("w:fldCharType"), "end")
    run2._r.append(fldChar3)
    run2._r.append(instrText2)
    run2._r.append(fldChar4)

    doc.save(str(REF_DOCX))


# ---------------------------------------------------------------------------
# Step 2. Run pandoc — MANUAL.md → _body.docx
# ---------------------------------------------------------------------------

def pandoc_convert():
    # `--shift-heading-level-by=-1` so the Markdown's `## 1. Introduction`
    # becomes Heading 1 in Word (each MD `###` becomes Heading 2).
    # This makes the Word-native TOC field show one entry per chapter +
    # one per subsection — exactly matching the document's section
    # numbering 1, 1.1, 1.2, …, 12.
    pypandoc.convert_file(
        str(MD_STRIPPED),
        "docx",
        format="markdown+pipe_tables+fenced_code_blocks+tex_math_dollars+yaml_metadata_block",
        outputfile=str(BODY_DOCX),
        extra_args=[
            f"--reference-doc={REF_DOCX}",
            "--standalone",
            "--shift-heading-level-by=-1",
        ],
    )


# ---------------------------------------------------------------------------
# Step 3 + 4 + 5. Assemble final document.
#   - Cover page (title block)
#   - TOC field
#   - Page break
#   - Body (copy-paste paragraphs from _body.docx)
# ---------------------------------------------------------------------------

def add_toc_field(paragraph):
    """Insert a Word TOC field that the user can right-click → Update."""
    run = paragraph.add_run()
    fldChar1 = OxmlElement("w:fldChar"); fldChar1.set(qn("w:fldCharType"), "begin")
    instrText = OxmlElement("w:instrText"); instrText.set(qn("xml:space"), "preserve")
    # TOC for Heading 1..3 with hyperlinks + page numbers + dotted leaders.
    instrText.text = r'TOC \o "1-3" \h \z \u'
    fldChar2 = OxmlElement("w:fldChar"); fldChar2.set(qn("w:fldCharType"), "separate")
    fldChar3 = OxmlElement("w:t")
    fldChar3.text = "Right-click and select “Update Field” to populate the table of contents."
    fldChar4 = OxmlElement("w:fldChar"); fldChar4.set(qn("w:fldCharType"), "end")
    run._r.append(fldChar1)
    run._r.append(instrText)
    run._r.append(fldChar2)
    run._r.append(fldChar3)
    run._r.append(fldChar4)


def build_final():
    body = Document(str(BODY_DOCX))

    # ---------- Build cover-page contents BEFORE the existing body ----------
    # We do this by reading the body's first sectPr, prepending cover paragraphs
    # in front of the very first body block, then inserting a page break + TOC.
    cover_paragraphs = []

    def make_p(text, *, bold=False, italic=False, size=None, align=None,
               space_before=0, space_after=0):
        p = body.add_paragraph()
        body._body._element.remove(p._p)   # detach, we re-insert at top
        run = p.add_run(text)
        run.font.name = "Cambria"
        if bold:    run.bold = True
        if italic:  run.italic = True
        if size:    run.font.size = Pt(size)
        if align is not None: p.alignment = align
        pf = p.paragraph_format
        if space_before: pf.space_before = Pt(space_before)
        if space_after:  pf.space_after  = Pt(space_after)
        return p

    def add_image_p(image_path, width_cm, space_after_pt=18):
        """Centred image paragraph, detached from the body for later prepend."""
        p = body.add_paragraph()
        body._body._element.remove(p._p)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.add_run().add_picture(str(image_path), width=Cm(width_cm))
        p.paragraph_format.space_after = Pt(space_after_pt)
        return p

    # Top spacer
    cover_paragraphs.append(make_p("",  space_before=60))

    # === GaiaSeis software logo (icon + wordmark) at the top ===
    if GAIASEIS_LOGO.exists():
        cover_paragraphs.append(add_image_p(GAIASEIS_LOGO, width_cm=8.0, space_after_pt=24))
    else:
        print(f"  WARNING: GaiaSeis logo not found at {GAIASEIS_LOGO}")
        cover_paragraphs.append(make_p("GaiaSeis",
                                        bold=True, size=36, align=WD_ALIGN_PARAGRAPH.CENTER,
                                        space_after=8))

    cover_paragraphs.append(make_p("User Manual",
                                    bold=True, size=22, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=6))
    cover_paragraphs.append(make_p(
        "GNSS-based Real-time Seismogeodesy via the Variometric Approach",
        italic=True, size=14, align=WD_ALIGN_PARAGRAPH.CENTER,
        space_after=4))
    cover_paragraphs.append(make_p("(formerly NtripClient.jl)",
                                    italic=True, size=11, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=36))
    cover_paragraphs.append(make_p("Version 0.1.0",
                                    size=12, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=24))
    cover_paragraphs.append(make_p("Panagiotis Elias",
                                    bold=True, size=14, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=4))
    cover_paragraphs.append(make_p("pelias@upatras.gr",
                                    size=11, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=24))

    # === Parent-organisation block: Deforming Gaia Lab + Department ===
    cover_paragraphs.append(make_p("Deforming Gaia Lab",
                                    bold=True, size=12, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=4))
    if DGL_LOGO.exists():
        cover_paragraphs.append(add_image_p(DGL_LOGO, width_cm=5.5, space_after_pt=6))
    cover_paragraphs.append(make_p("Department of Geology, University of Patras, Greece",
                                    size=11, align=WD_ALIGN_PARAGRAPH.CENTER,
                                    space_after=48))
    cover_paragraphs.append(make_p(
        "Partly funded by the European Union under Horizon Europe project TRANSFORM²",
        italic=True, size=10, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=2))
    cover_paragraphs.append(make_p(
        "(Grant Agreement No. GAP-101188365)",
        italic=True, size=10, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=4))
    cover_paragraphs.append(make_p(
        "Licensed under Creative Commons Attribution-NonCommercial 4.0 International",
        italic=True, size=9, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=4))
    cover_paragraphs.append(make_p(
        "(CC BY-NC 4.0)",
        italic=True, size=9, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=0))

    # Page break after the cover.
    p_break = body.add_paragraph()
    body._body._element.remove(p_break._p)
    p_break.add_run().add_break(WD_BREAK.PAGE)

    # TOC heading + TOC field.
    p_toc_h = body.add_paragraph("Table of contents", style="Heading 1")
    body._body._element.remove(p_toc_h._p)
    p_toc = body.add_paragraph(style="TOC Heading" if "TOC Heading" in [s.name for s in body.styles] else None)
    body._body._element.remove(p_toc._p)
    add_toc_field(p_toc)
    p_toc_break = body.add_paragraph()
    body._body._element.remove(p_toc_break._p)
    p_toc_break.add_run().add_break(WD_BREAK.PAGE)

    # Insert in order at the very start of the body XML.
    body_el = body._body._element
    insert_idx = 0
    for new_p in (cover_paragraphs + [p_break, p_toc_h, p_toc, p_toc_break]):
        body_el.insert(insert_idx, new_p._p)
        insert_idx += 1

    # Also drop the body's own duplicate "Table of contents" heading (we
    # supply a real Word TOC field, so the Markdown-rendered placeholder
    # is redundant). Find the first body Heading-2 that says "Table of
    # contents" — if Pandoc rendered MD's `## Table of contents` we strip it
    # plus its sibling list.
    # (Skipped — kept as-is because the markdown TOC also serves as a
    # quick visual index that doesn't depend on Word field updates.)

    global OUT_DOCX
    try:
        body.save(str(OUT_DOCX))
    except PermissionError:
        # Word probably has the old file open. Write a timestamped copy
        # so we still produce output the user can inspect.
        import datetime as _dt
        alt = OUT_DOCX.with_name(
            OUT_DOCX.stem + "_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S") + OUT_DOCX.suffix
        )
        body.save(str(alt))
        print(f"  WARNING: target was locked; saved as {alt.name} instead")
        OUT_DOCX = alt


# ---------------------------------------------------------------------------
def main():
    if not REF_DOCX.exists():
        raise SystemExit(f"Missing {REF_DOCX}; run pandoc --print-default-data-file=reference.docx first.")
    print("[1/5] Stripping markdown preamble (title + TOC)...")
    strip_markdown_preamble()
    print("[2/5] Customising reference docx (fonts + footer)...")
    customise_reference()
    print("[3/5] Running pandoc on _manual_body.md...")
    pandoc_convert()
    print("[4/5] Building cover page + Word TOC field...")
    build_final()
    print(f"[5/5] Done -> {OUT_DOCX} ({OUT_DOCX.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
