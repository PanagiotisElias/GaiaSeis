#!/usr/bin/env python3
"""Minimal, dependency-free Markdown → HTML for the GaiaSeis docs (headings,
paragraphs, fenced code, tables, lists, blockquotes, rules, bold/italic/code,
links, images embedded as data URIs). Used to build GaiaSeis_Manual.docx via
LibreOffice when pandoc/python-docx are not available:
    python3 _md2html.py MANUAL.md > _manual.html
"""
import re, sys, html, base64, pathlib

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<i>\1</i>', t)
    t = re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', lambda m: img(m.group(2), m.group(1)), t)
    t = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', t)
    return t

def img(path, alt):
    p = pathlib.Path(path)
    if p.exists() and p.suffix.lower() in ('.png', '.jpg', '.jpeg'):
        mime = 'image/png' if p.suffix.lower() == '.png' else 'image/jpeg'
        return f'<img src="data:{mime};base64,{base64.b64encode(p.read_bytes()).decode()}" alt="{html.escape(alt)}" width="600">'
    return f'<i>[image: {html.escape(alt or path)}]</i>'

def convert(md):
    out = []; lines = md.split('\n'); i = 0; para = []
    def flush():
        if para: out.append('<p>' + inline(' '.join(para)) + '</p>'); para.clear()
    while i < len(lines):
        l = lines[i]
        if l.startswith('```'):
            flush(); j = i + 1; buf = []
            while j < len(lines) and not lines[j].startswith('```'): buf.append(lines[j]); j += 1
            out.append('<pre>' + html.escape('\n'.join(buf)) + '</pre>'); i = j + 1; continue
        m = re.match(r'^(#{1,6})\s+(.*)', l)
        if m: flush(); n = len(m.group(1)); out.append(f'<h{n}>{inline(m.group(2))}</h{n}>'); i += 1; continue
        if re.match(r'^\s*(---|\*\*\*)\s*$', l): flush(); out.append('<hr>'); i += 1; continue
        if l.startswith('|') and i + 1 < len(lines) and re.match(r'^\|?\s*:?-+', lines[i+1]):
            flush(); hdr = [c.strip() for c in l.strip().strip('|').split('|')]; j = i + 2; rows = []
            while j < len(lines) and lines[j].startswith('|'): rows.append([c.strip() for c in lines[j].strip().strip('|').split('|')]); j += 1
            # width="100%": LibreOffice otherwise sizes the table to its content
            # and wide cells run past the page edge in the .docx (2026-10-06).
            out.append('<table width="100%"><tr>' + ''.join(f'<th>{inline(c)}</th>' for c in hdr) + '</tr>' +
                       ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in rows) + '</table>'); i = j; continue
        if l.startswith('>'):
            flush(); j = i; buf = []
            while j < len(lines) and lines[j].startswith('>'): buf.append(lines[j][1:].strip()); j += 1
            out.append('<div class="note">' + inline(' '.join(buf)) + '</div>'); i = j; continue
        m = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)', l)
        if m:
            flush(); ordered = m.group(2)[0].isdigit(); tag = 'ol' if ordered else 'ul'; j = i; items = []
            while j < len(lines):
                mm = re.match(r'^(\s*)([-*]|\d+\.)\s+(.*)', lines[j])
                if mm: items.append(mm.group(3)); j += 1
                elif lines[j].startswith('   ') or lines[j].startswith('  ') and lines[j].strip() and items: items[-1] += ' ' + lines[j].strip(); j += 1
                else: break
            out.append(f'<{tag}>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + f'</{tag}>'); i = j; continue
        if not l.strip(): flush(); i += 1; continue
        para.append(l.strip()); i += 1
    flush(); return '\n'.join(out)

if __name__ == '__main__':
    src = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
    css = pathlib.Path('_style.css').read_text() if pathlib.Path('_style.css').exists() else ''
    title = re.search(r'^#\s+(.*)', src, re.M); title = title.group(1) if title else 'Document'
    sys.stdout.write(f'<html><head><meta charset="utf-8"><title>{html.escape(title)}</title><style>{css}</style></head><body>\n{convert(src)}\n</body></html>')
