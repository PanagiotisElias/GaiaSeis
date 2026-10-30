# Gtk4 GUI — profile picker, edit form, start/stop, live status panel.
#
# Loaded lazily from GaiaSeis.launch_gui() so users without Gtk4 installed
# can still use the library headlessly.
#
# Expects `Gtk4` to be available in the calling module's namespace (the launcher
# does `@eval Main using Gtk4` first).

# ---------------------------------------------------------------------------
# Callback guard
#
# On Julia 1.12+ Gtk4.jl does not run the GLib main loop in a `while` loop —
# `glib_main` installs a `Timer` that calls `g_main_context_iteration` every
# 2 ms (Gtk4's src/GLib/loop.jl).  A Julia exception thrown inside ANY GTK
# callback propagates out through that timer callback, and a throwing Timer
# callback is closed by Julia.  The GLib loop then stops for good.
#
# The failure is silent and total: the process stays alive, background tasks
# (NTRIP readers, miniSEED writers, the periodic diagnostic dump) keep running,
# but the GUI never repaints and never answers a click again.  Seen from
# outside, X events pile up unread on the display socket — a window that
# cannot be restored from the taskbar, at 0% CPU.
#
# `@gs_guarded` wraps a callback body so nothing escapes into the loop.  It
# rewrites only the do-block *body* and leaves the argument list untouched,
# so the closure keeps the exact arity Gtk4.jl's GValue marshaller expects.
#
#     @gs_guarded Gtk4.signal_connect(btn, "clicked") do _
#         ...
#     end
#
# An optional first argument is the value returned when the body throws
# (default `nothing`).  GLib *timeout* callbacks must pass `true`: returning
# anything else removes the source, so one failure would stop the updates
# permanently — the very thing this guard exists to prevent.
macro gs_guarded(ex)
    return _gs_guard(ex, nothing, __source__)
end

macro gs_guarded(retval, ex)
    return _gs_guard(ex, retval, __source__)
end

function _gs_guard(ex, retval, src)
    (ex isa Expr && ex.head === :do) ||
        error("@gs_guarded expects a `f(...) do ... end` call")
    lam = ex.args[2]
    (lam isa Expr && lam.head === :->) ||
        error("@gs_guarded: malformed do-block")
    site   = string(src.file, ":", src.line)
    errsym = gensym("gs_err")
    handler = Expr(:block,
        :(_gs_report_callback_error($errsym, catch_backtrace(), $site)),
        retval)
    newbody = Expr(:try, lam.args[2], errsym, handler)
    return esc(Expr(:do, ex.args[1], Expr(:->, lam.args[1], newbody)))
end

# A callback that fails once normally fails on every subsequent event, so the
# first failure per site is reported loudly and the rest go to @debug.  An
# unthrottled @error here would bury the console at the GUI's 2 Hz tick rate.
const _GS_REPORTED_SITES = Set{String}()

function _gs_report_callback_error(err, bt, site::AbstractString)
    if site in _GS_REPORTED_SITES
        @debug "GaiaSeis: GUI callback failed again" site exception=(err, bt)
        return nothing
    end
    push!(_GS_REPORTED_SITES, site)
    @error "GaiaSeis: GUI callback raised — swallowed so the GLib main loop \
            survives. Further failures at this site log at debug level." site exception=(err, bt)
    return nothing
end

# Asset paths for the two logos. We ship pre-rasterised PNGs at the
# exact pixel sizes the GUI uses (28, 40, 120 px) because GtkImage
# displays files at their *native* size — which is exactly what we
# want for header bars and toolbars; the picture-with-width-request
# approach lets the natural size leak through and inflates the
# header height, which also pushes the buttons to grow.
# Resolved through `app_root()` (see src/paths.jl) rather than `@__DIR__`
# so a compiled app or a system-wide install finds its own assets.
_assets_dir()     = assets_dir()
_icon_theme_dir() = icon_theme_dir()
# Application icon name resolved against the bundled icon-theme tree
# under `docs/assets/icons/` — see `_install_app_icon!` below.
const _APP_ICON_NAME = "gaiaseis"
# .ico file used by the Win32 taskbar/title-bar icon plumbing.  The
# rasterizer (`docs/assets/_rasterize.jl`) builds this from the GaiaSeis
# SVG at 16/24/32/48/64/128/256 px so Windows can pick the best fit.
_app_icon_ico_path() = joinpath(_icon_theme_dir(), "gaiaseis.ico")

# ---------- Windows: per-HWND taskbar icon override ----------------------
# GTK4 on Windows maps `set_icon_name` to WM_SETICON, but only if the icon
# lookup succeeds against the GTK icon theme.  In practice the lookup can
# be flaky (the GaiaSeis icon-theme tree we register isn't always picked
# up before the first window is realized), which leaves the taskbar group
# showing julia.exe's three-coloured-dots icon.  The Win32 path is more
# reliable: we set a unique AppUserModelID so Windows treats GaiaSeis as
# its own app group (independent of julia.exe), then attach an HICON
# loaded from `gaiaseis.ico` directly to each window's HWND.
@static if Sys.iswindows()

const _W_USER32  = "user32"
const _W_SHELL32 = "shell32"
const _W_GDK     = "libgdk-4-1"      # provided by Gtk4_jll, loaded on import

const _WM_SETICON       = Cuint(0x0080)
const _ICON_SMALL       = Csize_t(0)
const _ICON_BIG         = Csize_t(1)
const _IMAGE_ICON       = Cuint(1)
const _LR_LOADFROMFILE  = Cuint(0x00000010)
const _LR_SHARED        = Cuint(0x00008000)

# Set a per-process AppUserModelID. Without this, Windows uses the
# executable path (= julia.exe) as the identity key, which is why every
# Julia GUI inherits the Julia logo in the taskbar. Idempotent — multiple
# calls just overwrite the previous ID.
function _win_set_aumid(id::AbstractString)
    try
        ccall((:SetCurrentProcessExplicitAppUserModelID, _W_SHELL32),
              Clong, (Cwstring,), id)
    catch err
        @debug "SetCurrentProcessExplicitAppUserModelID failed" err
    end
end

# Load an HICON of the requested square `size` (in pixels; 0 = OS-default
# size) from a .ico file. Returns C_NULL on failure.
function _win_load_icon(path::AbstractString, size::Int)
    try
        ccall((:LoadImageW, _W_USER32), Ptr{Cvoid},
              (Ptr{Cvoid}, Cwstring, Cuint, Cint, Cint, Cuint),
              C_NULL, path, _IMAGE_ICON,
              Cint(size), Cint(size),
              _LR_LOADFROMFILE | _LR_SHARED)
    catch err
        @debug "LoadImageW failed" path size err
        return Ptr{Cvoid}(C_NULL)
    end
end

# Resolve the HWND backing a GtkWindow. Returns C_NULL if the window
# hasn't been realized yet (no GdkSurface) — or if any of the calls into
# Gtk4.jl / libgdk-4-1 throw (different Gtk4_jll DLL naming on the user's
# machine, missing symbol, etc.).  Failure here MUST NOT crash GUI
# startup; the caller just retries / gives up.
function _win_hwnd(Gtk4, win)
    surface = try
        Gtk4.G_.get_surface(win)
    catch
        nothing
    end
    surface === nothing && return Ptr{Cvoid}(C_NULL)
    sptr = try
        convert(Ptr{Cvoid}, surface.handle)
    catch
        return Ptr{Cvoid}(C_NULL)
    end
    sptr == C_NULL && return Ptr{Cvoid}(C_NULL)
    return try
        ccall((:gdk_win32_surface_get_handle, _W_GDK), Ptr{Cvoid},
              (Ptr{Cvoid},), sptr)
    catch
        Ptr{Cvoid}(C_NULL)
    end
end

# Attach the GaiaSeis HICONs to a window. Returns true on success so the
# caller's deferred retry loop knows to stop. Every Win32 call is wrapped
# defensively — failures degrade silently rather than propagating.
function _win_attach_window_icon(Gtk4, win)
    ico = _app_icon_ico_path()
    isfile(ico) || return true   # nothing to attach
    hwnd = _win_hwnd(Gtk4, win)
    hwnd == C_NULL && return false   # not realized yet → retry
    h_big   = _win_load_icon(ico, 32)
    h_small = _win_load_icon(ico, 16)
    if h_big != C_NULL
        try
            ccall((:SendMessageW, _W_USER32), Clong,
                  (Ptr{Cvoid}, Cuint, Csize_t, Ptr{Cvoid}),
                  hwnd, _WM_SETICON, _ICON_BIG, h_big)
        catch err
            @debug "SendMessage(WM_SETICON, ICON_BIG) failed" err
        end
    end
    if h_small != C_NULL
        try
            ccall((:SendMessageW, _W_USER32), Clong,
                  (Ptr{Cvoid}, Cuint, Csize_t, Ptr{Cvoid}),
                  hwnd, _WM_SETICON, _ICON_SMALL, h_small)
        catch err
            @debug "SendMessage(WM_SETICON, ICON_SMALL) failed" err
        end
    end
    return true
end

end # @static if iswindows
# `_SOFTWARE_VERSION` is defined in paths.jl (first include).

# Register the bundled GaiaSeis icon as the default GTK application
# icon. After this is called once, every subsequently-created
# `GtkWindow` shows the icon in its title bar, in Alt-Tab, and in the
# OS taskbar (on Windows the per-HWND icon is what the taskbar
# displays). Subsequent calls are no-ops.
#
# Mechanism:
#   1. Add `docs/assets/icons/` to the default GdkDisplay's icon-theme
#      search path — the directory contains a freedesktop-style
#      `scalable/apps/gaiaseis.svg` + `<NN>x<NN>/apps/gaiaseis.png`
#      tree + an `index.theme` descriptor.
#   2. Call `set_default_icon_name("gaiaseis")` so any GtkWindow built
#      from now on inherits it.
const _ICON_INSTALLED = Ref(false)

# Install the GaiaSeis icon. EVERY failure inside this function is
# swallowed — bad icons must never prevent the GUI from coming up. A
# remote user who launches the app and only sees the Julia icon (instead
# of GaiaSeis) is a cosmetic problem; a user whose window never shows
# because of an unrelated icon error is a fatal regression.
function _install_app_icon!(Gtk4)
    _ICON_INSTALLED[] && return
    # GTK icon-theme registration (cross-platform; gives every window its
    # title-bar icon via the theme system).
    # Note: Gtk4.jl ≥ 0.7 removed the no-arg `Gtk4.G_.get_default_display()`
    # binding (the closest method now wants a `GdkDisplayManager`). The
    # zero-arg `Gtk4.GdkDisplay()` constructor returns the same default
    # display and works on every version we ship against.
    try
        display = Gtk4.GdkDisplay()
        if display !== nothing
            theme = Gtk4.GtkIconTheme(display)
            Gtk4.G_.add_search_path(theme, _icon_theme_dir())
            Gtk4.G_.set_default_icon_name(_APP_ICON_NAME)
            _ICON_INSTALLED[] = true
        end
    catch err
        @warn "GaiaSeis: GTK icon-theme registration failed (cosmetic only)" exception=err
    end
    # Windows-only: claim a private AppUserModelID so the taskbar groups
    # GaiaSeis windows separately from julia.exe (otherwise everything
    # inherits the Julia three-dots icon regardless of what we set on
    # individual HWNDs).
    @static if Sys.iswindows()
        try
            _win_set_aumid("DeformingGaiaLab.GaiaSeis.1")
        catch err
            @warn "GaiaSeis: SetCurrentProcessExplicitAppUserModelID failed (cosmetic only)" exception=err
        end
    end
    return
end

# Belt-and-braces: tag a single window with the icon name explicitly,
# in case `set_default_icon_name` was called too late for that window
# to pick it up at construction time.
#
# On Windows additionally schedule a retry loop that attaches a real
# HICON (loaded from gaiaseis.ico) to the window's HWND once it exists —
# this is what the OS taskbar actually shows.
#
# Same hard rule as `_install_app_icon!`: every failure here is caught
# and logged.  Icon problems MUST NOT abort window creation.
function _apply_window_icon!(Gtk4, win)
    try
        Gtk4.G_.set_icon_name(win, _APP_ICON_NAME)
    catch err
        @warn "GaiaSeis: set_icon_name failed (cosmetic only)" exception=err
    end
    @static if Sys.iswindows()
        try
            # The HWND doesn't exist until the window is realized + shown,
            # which happens AFTER `_apply_window_icon!` is called. Poll on a
            # 100 ms timer; stop on first success, give up after ≈10 s so a
            # window the user closes immediately doesn't leak a timer source.
            attempts = Ref(0)
            Gtk4.GLib.g_timeout_add(100) do
                attempts[] += 1
                try
                    if _win_attach_window_icon(Gtk4, win)
                        return false   # success → stop
                    end
                catch err
                    @debug "Win32 icon attach raised" err
                end
                return attempts[] < 100   # ~10 s max, then drop the source
            end
        catch err
            @warn "GaiaSeis: could not schedule Win32 icon attach (cosmetic only)" exception=err
        end
    end
    return nothing
end

# Pick the closest pre-rendered logo variant for the requested height.
# Falls back to the single full-size file if no _<NN>.png variant exists.
function _logo_path(name::AbstractString, height::Integer)
    for h in (28, 40, 56, 84, 120)
        if height <= h
            p = joinpath(_assets_dir(), "$(name)_$(h).png")
            isfile(p) && return p
        end
    end
    p_full = joinpath(_assets_dir(), "$(name).png")
    return isfile(p_full) ? p_full : ""
end

# Build a logo widget at exactly the file's native pixel size.
# Uses GtkPicture (Gtk4's native widget for arbitrary bitmaps) with
# `can_shrink = false` so the picture renders at the PNG's true
# resolution — GtkImage shrinks file-loaded bitmaps to icon-theme
# size by default, which is the bug that made the logos look tiny.
function _make_logo(Gtk4, name::AbstractString; height::Integer = 28)
    path = _logo_path(name, height)
    isempty(path) && return nothing
    try
        if isdefined(Gtk4, :GtkPicture)
            pic = Gtk4.GtkPicture()
            Gtk4.G_.set_filename(pic, path)
            # Critical: without this, GtkPicture will scale the image
            # down to fit whatever space the parent gives — defeating
            # the pre-rendered 84-px asset.
            Gtk4.set_gtk_property!(pic, :can_shrink, false)
            # Belt-and-braces: lock the widget's allocation to the
            # requested height as well, so the strip's vertical layout
            # is deterministic.
            Gtk4.set_gtk_property!(pic, :height_request, height)
            return pic
        else
            img = Gtk4.GtkImage()
            Gtk4.G_.set_from_file(img, path)
            Gtk4.set_gtk_property!(img, :pixel_size, height)
            return img
        end
    catch err
        @debug "could not load logo" name height err
        return nothing
    end
end

# Build a two-line "wordmark" block to sit immediately right of the
# GaiaSeis icon: the project name on line 1, the full software title on
# line 2. No third credit line — the strip stays compact.
#
# `size` picks between two presets:
#   :main → larger (used in the main window banner)
#   :plot → slightly smaller (used in the Plot window banner)
function _make_wordmark(Gtk4; size::Symbol = :main)
    title_pt    = size === :main ? 26 : 22
    subtitle_pt = size === :main ? 12 : 11

    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 0)
    Gtk4.set_gtk_property!(box, :valign, 3)   # 3 = CENTER (vertical)
    Gtk4.set_gtk_property!(box, :margin_start, 10)

    title = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(title, :use_markup, true)
    Gtk4.set_gtk_property!(title, :xalign, 0.0)
    Gtk4.set_gtk_property!(title, :label,
        "<span size=\"$(title_pt)pt\" weight=\"bold\" " *
        "foreground=\"#1f3a55\" letter_spacing=\"600\">GaiaSeis</span>")
    push!(box, title)

    # Subtitle stacked on two lines so the wordmark stays narrow — this
    # frees horizontal room in the About-dialog banner row for the
    # "Deforming Gaia Lab" caption right of the DG oval logo.
    subtitle_a = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(subtitle_a, :use_markup, true)
    Gtk4.set_gtk_property!(subtitle_a, :xalign, 0.0)
    Gtk4.set_gtk_property!(subtitle_a, :label,
        "<span size=\"$(subtitle_pt)pt\" foreground=\"#3b556f\">" *
        "GNSS real-time seismogeodesy</span>")
    push!(box, subtitle_a)

    subtitle_b = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(subtitle_b, :use_markup, true)
    Gtk4.set_gtk_property!(subtitle_b, :xalign, 0.0)
    Gtk4.set_gtk_property!(subtitle_b, :label,
        "<span size=\"$(subtitle_pt)pt\" foreground=\"#3b556f\">" *
        "variometric PPP</span>")
    push!(box, subtitle_b)

    return box
end

# Compact wordmark for the main + Plot windows: project name on top,
# version line below. Two lines only, no subtitle. Designed to sit
# beside a small (~40 px) GaiaSeis icon and stay tight so the header
# strip doesn't grow.
function _make_compact_wordmark(Gtk4)
    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 0)
    Gtk4.set_gtk_property!(box, :valign, 3)   # CENTER
    Gtk4.set_gtk_property!(box, :margin_start, 8)

    title = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(title, :use_markup, true)
    Gtk4.set_gtk_property!(title, :xalign, 0.0)
    Gtk4.set_gtk_property!(title, :label,
        "<span size=\"15pt\" weight=\"bold\" " *
        "foreground=\"#1f3a55\" letter_spacing=\"400\">GaiaSeis</span>")
    push!(box, title)

    ver = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(ver, :use_markup, true)
    Gtk4.set_gtk_property!(ver, :xalign, 0.0)
    Gtk4.set_gtk_property!(ver, :label,
        "<span size=\"9pt\" foreground=\"#6a7a8a\">v" * _SOFTWARE_VERSION *
        "</span>")
    push!(box, ver)
    return box
end

# Small "Deforming Gaia Lab" caption sitting to the right of the
# Deforming-Gaia oval logo. Two stacked labels (lab name on top,
# parent-affiliation line below) styled the same way as the GaiaSeis
# wordmark for visual consistency.
function _make_dglab_caption(Gtk4; size::Symbol = :main)
    name_pt   = size === :main ? 14 : 12
    sub_pt    = size === :main ? 10 : 9

    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 0)
    Gtk4.set_gtk_property!(box, :valign, 3)   # CENTER
    Gtk4.set_gtk_property!(box, :margin_start, 8)

    nm = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(nm, :use_markup, true)
    Gtk4.set_gtk_property!(nm, :xalign, 0.0)
    Gtk4.set_gtk_property!(nm, :label,
        "<span size=\"$(name_pt)pt\" weight=\"bold\" " *
        "foreground=\"#1f3a55\">Deforming Gaia Lab</span>")
    push!(box, nm)

    sub = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(sub, :use_markup, true)
    Gtk4.set_gtk_property!(sub, :xalign, 0.0)
    Gtk4.set_gtk_property!(sub, :label,
        "<span size=\"$(sub_pt)pt\" foreground=\"#6a7a8a\">" *
        "University of Patras · Greece</span>")
    push!(box, sub)

    return box
end

function _launch_gui_impl(profiles_path::AbstractString)
    Gtk4 = Main.Gtk4

    # Register the GaiaSeis icon with the GTK default icon theme BEFORE
    # any window is created — so every top-level shows it in the title
    # bar / Alt-Tab / OS taskbar.
    _install_app_icon!(Gtk4)

    active, profiles = load_profiles(profiles_path)

    # ---------- Outer window ----------
    # 920×600 fits comfortably on a 768-pixel-tall display once Windows
    # subtracts the taskbar and title bar. The form is scrollable, so
    # nothing is lost if the user shrinks the window further.
    win = Gtk4.GtkWindow("GaiaSeis — GNSS real-time seismogeodesy", 920, 600)
    Gtk4.set_gtk_property!(win, :title, "GaiaSeis — GNSS real-time seismogeodesy")
    _apply_window_icon!(Gtk4, win)
    outer = Gtk4.GtkBox(:v)
    push!(win, outer)

    # ---------- Header bar (title + profile picker + new/delete) ----------
    hbar = Gtk4.GtkHeaderBar()
    Gtk4.set_gtk_property!(hbar, :show_title_buttons, true)
    Gtk4.G_.set_titlebar(win, hbar)
    # Note: logos are NOT packed into the header bar — Gtk4's header bar
    # auto-sizes to its tallest child, which would inflate the action
    # buttons. Instead the logos live in a dedicated strip below (see
    # `logo_strip` further down).

    profile_combo = Gtk4.GtkComboBoxText()
    for name in sort!(collect(keys(profiles)))
        push!(profile_combo, name)
    end
    Gtk4.set_gtk_property!(profile_combo, :active, _index_of(sort!(collect(keys(profiles))), active) - 1)
    Gtk4.set_gtk_property!(profile_combo, :tooltip_text, "Select active NTRIP profile")
    Gtk4.G_.set_title_widget(hbar, profile_combo)

    btn_new    = Gtk4.GtkButton("New")
    btn_dup    = Gtk4.GtkButton("Duplicate")
    btn_rename = Gtk4.GtkButton("Rename")
    btn_del    = Gtk4.GtkButton("Delete")
    btn_about  = Gtk4.GtkButton("About")
    btn_engine = Gtk4.GtkButton("About engine")
    Gtk4.G_.pack_end(hbar, btn_about)
    Gtk4.G_.pack_end(hbar, btn_engine)
    Gtk4.G_.pack_end(hbar, btn_del)
    Gtk4.G_.pack_end(hbar, btn_rename)
    Gtk4.G_.pack_end(hbar, btn_dup)
    Gtk4.G_.pack_end(hbar, btn_new)

    # ---------- Logo strip (above the body, below the header bar) ----------
    # Kept out of the header bar on purpose: a GtkHeaderBar grows to fit
    # its tallest child, which would inflate the action buttons. Putting
    # the logos in their own strip lets them be ~84 px tall without
    # affecting any other widget.
    # Compact header strip: small (40-px) GaiaSeis icon + project name
    # + version, left-aligned. The full 3-logo deployment (GaiaSeis +
    # CRL + Deforming-Gaia) lives only in the About dialog now.
    # `halign = START` collapses the strip to its natural width so the
    # remainder of the row is never empty — the body grows to fill the
    # window instead.
    logo_strip = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(logo_strip, :spacing, 6)
    Gtk4.set_gtk_property!(logo_strip, :margin_top, 6)
    Gtk4.set_gtk_property!(logo_strip, :margin_bottom, 2)
    Gtk4.set_gtk_property!(logo_strip, :margin_start, 12)
    Gtk4.set_gtk_property!(logo_strip, :margin_end, 12)
    Gtk4.set_gtk_property!(logo_strip, :halign, 1)   # START — no trailing void
    push!(outer, logo_strip)
    let lg = _make_logo(Gtk4, "GaiaSeis_icon"; height = 40)
        lg === nothing || push!(logo_strip, lg)
    end
    push!(logo_strip, _make_compact_wordmark(Gtk4))
    # Small red note when other processes are slowing GaiaSeis (health.jl).
    lbl_overload_main = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_overload_main, :use_markup, true)
    Gtk4.set_gtk_property!(lbl_overload_main, :margin_start, 14)
    Gtk4.set_gtk_property!(lbl_overload_main, :valign, 3)   # CENTER
    push!(logo_strip, lbl_overload_main)

    # ---------- Body: two columns ----------
    body = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(body, :margin_top, 12)
    Gtk4.set_gtk_property!(body, :margin_bottom, 12)
    Gtk4.set_gtk_property!(body, :margin_start, 12)
    Gtk4.set_gtk_property!(body, :margin_end,   12)
    Gtk4.set_gtk_property!(body, :spacing, 12)
    push!(outer, body)

    # Left column — edit form. Wrapped in a GtkScrolledWindow so the SSR
    # and broadcast-ephemeris sections at the bottom don't push the window
    # off the screen on small displays. The scrollbar appears only when
    # needed.
    form_frame = Gtk4.GtkFrame("Profile configuration")
    Gtk4.set_gtk_property!(form_frame, :hexpand, true)
    Gtk4.set_gtk_property!(form_frame, :vexpand, true)
    push!(body, form_frame)
    form_scroll = Gtk4.GtkScrolledWindow()
    Gtk4.set_gtk_property!(form_scroll, :hexpand, true)
    Gtk4.set_gtk_property!(form_scroll, :vexpand, true)
    Gtk4.set_gtk_property!(form_scroll, :hscrollbar_policy, 2)  # NEVER
    Gtk4.set_gtk_property!(form_scroll, :vscrollbar_policy, 1)  # AUTOMATIC
    form_nb = Gtk4.GtkNotebook()
    Gtk4.set_gtk_property!(form_nb, :hexpand, true)
    Gtk4.set_gtk_property!(form_nb, :vexpand, true)
    form_frame[] = form_nb
    push!(form_nb, form_scroll, Gtk4.GtkLabel("Stream & outputs"))
    # Engine tab: engine choice, plug-in directory, and the parameters the
    # selected engine declares (GaiaSeisEngineAPI.ParamSpec); built when the
    # profile is loaded or the engine changes; locked while streaming.
    engine_scroll = Gtk4.GtkScrolledWindow()
    Gtk4.set_gtk_property!(engine_scroll, :hexpand, true)
    Gtk4.set_gtk_property!(engine_scroll, :vexpand, true)
    Gtk4.set_gtk_property!(engine_scroll, :hscrollbar_policy, 2)
    push!(form_nb, engine_scroll, Gtk4.GtkLabel("Engine"))
    engine_box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(engine_box, :spacing, 6)
    Gtk4.set_gtk_property!(engine_box, :margin_top, 8)
    Gtk4.set_gtk_property!(engine_box, :margin_bottom, 8)
    Gtk4.set_gtk_property!(engine_box, :margin_start, 10)
    Gtk4.set_gtk_property!(engine_box, :margin_end, 10)
    engine_scroll[] = engine_box
    grid = Gtk4.GtkGrid()
    Gtk4.set_gtk_property!(grid, :row_spacing, 4)
    Gtk4.set_gtk_property!(grid, :column_spacing, 10)
    Gtk4.set_gtk_property!(grid, :margin_top, 8)
    Gtk4.set_gtk_property!(grid, :margin_bottom, 8)
    Gtk4.set_gtk_property!(grid, :margin_start, 10)
    Gtk4.set_gtk_property!(grid, :margin_end, 10)
    form_scroll[] = grid

    # Right column — status + log buttons
    status_frame = Gtk4.GtkFrame("Live status")
    Gtk4.set_gtk_property!(status_frame, :width_request, 360)
    Gtk4.set_gtk_property!(status_frame, :vexpand, true)
    push!(body, status_frame)
    status_box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(status_box, :margin_top, 8)
    Gtk4.set_gtk_property!(status_box, :margin_bottom, 8)
    Gtk4.set_gtk_property!(status_box, :margin_start, 10)
    Gtk4.set_gtk_property!(status_box, :margin_end, 10)
    Gtk4.set_gtk_property!(status_box, :spacing, 6)
    status_frame[] = status_box

    status_label_state   = Gtk4.GtkLabel("Idle")
    status_label_engine  = Gtk4.GtkLabel("Engine: —")
    Gtk4.set_gtk_property!(status_label_engine, :use_markup, true)
    status_label_bytes   = Gtk4.GtkLabel("0 bytes received")
    status_label_frames  = Gtk4.GtkLabel("0 frames decoded")
    status_label_msgs    = Gtk4.GtkLabel("Messages: —")
    status_label_epoch   = Gtk4.GtkLabel("Epoch SOD: —")
    status_label_sat     = Gtk4.GtkLabel("Satellites: —")
    status_label_missing = Gtk4.GtkLabel("Missing epochs: —")
    Gtk4.set_gtk_property!(status_label_missing, :tooltip_text,
        "Epochs that never arrived from the receiver/caster, detected from " *
        "jumps in the epoch time of the primary constellation before any " *
        "processing. Independent of backpressure and outlier rejection.")
    status_label_resid   = Gtk4.GtkLabel("Residual σ: —")
    status_label_dxyz    = Gtk4.GtkLabel("dXYZ (m): —")
    status_label_prereq  = Gtk4.GtkLabel("Filter prerequisites: —")
    Gtk4.set_gtk_property!(status_label_prereq, :wrap, true)
    status_label_error   = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(status_label_error, :wrap, true)
    # Per-stream "last frame at" timestamps — one line per NTRIP connection.
    status_label_t_obs   = Gtk4.GtkLabel("obs caster   : —")
    status_label_t_ssr   = Gtk4.GtkLabel("ssr caster   : —")
    status_label_t_eph   = Gtk4.GtkLabel("eph caster   : —")
    for w in (status_label_state, status_label_engine, status_label_bytes, status_label_frames,
              status_label_msgs, status_label_epoch, status_label_sat,
              status_label_missing, status_label_resid, status_label_dxyz,
              status_label_t_obs, status_label_t_ssr, status_label_t_eph,
              status_label_prereq, status_label_error)
        Gtk4.set_gtk_property!(w, :xalign, 0.0)
        push!(status_box, w)
    end

    # Live NEU displacement plot — Cairo-drawn time series via Gtk4's
    # GtkCanvas (which wraps a backing-store CairoSurface around a
    # GtkDrawingArea). Reads `session.stats.displacement_history` per draw.
    plot_label = Gtk4.GtkLabel("─── displacement N (red)  E (green)  U (blue), mm ───")
    Gtk4.set_gtk_property!(plot_label, :xalign, 0.0)
    Gtk4.set_gtk_property!(plot_label, :margin_top, 8)
    push!(status_box, plot_label)
    plot_area = Gtk4.GtkCanvas(340, 220)
    Gtk4.set_gtk_property!(plot_area, :hexpand, true)
    Gtk4.set_gtk_property!(plot_area, :vexpand, true)
    push!(status_box, plot_area)

    # Bottom action bar
    actionbar = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(actionbar, :spacing, 8)
    Gtk4.set_gtk_property!(actionbar, :margin_top, 6)
    Gtk4.set_gtk_property!(actionbar, :margin_bottom, 10)
    Gtk4.set_gtk_property!(actionbar, :margin_start, 12)
    Gtk4.set_gtk_property!(actionbar, :margin_end, 12)
    push!(outer, actionbar)
    btn_save  = Gtk4.GtkButton("Save profile")
    btn_start = Gtk4.GtkButton("Start stream")
    btn_stop  = Gtk4.GtkButton("Stop stream")
    btn_flush = Gtk4.GtkButton("Flush data")
    btn_debug = Gtk4.GtkButton("Debug…")
    btn_plot  = Gtk4.GtkButton("Plot")
    btn_metrics = Gtk4.GtkButton("Metrics")
    Gtk4.set_gtk_property!(btn_metrics, :tooltip_text,
        "Link metrics: arrival latency, solve time, miniSEED write latency, " *
        "SSR age, data loss, outages, throughput — live plots, a summary you " *
        "can write to a file, and a per-epoch CSV for comparing connections.")
    Gtk4.set_gtk_property!(btn_stop, :sensitive, false)
    Gtk4.set_gtk_property!(btn_flush, :tooltip_text,
        "Clear all rolling buffers (plots, stats), truncate the CSV sink, " *
        "and delete the current miniSEED files so a fresh segment starts " *
        "from the next accepted epoch. The stream keeps running.")
    status_inline = Gtk4.GtkLabel("Editing profile.")
    Gtk4.set_gtk_property!(status_inline, :hexpand, true)
    Gtk4.set_gtk_property!(status_inline, :xalign, 1.0)
    push!(actionbar, btn_save)
    push!(actionbar, btn_start)
    push!(actionbar, btn_stop)
    push!(actionbar, btn_flush)
    push!(actionbar, btn_debug)
    push!(actionbar, btn_plot)
    push!(actionbar, btn_metrics)
    push!(actionbar, status_inline)

    # ---------- Form widgets ----------
    function add_row!(row::Int, label::AbstractString, widget)
        l = Gtk4.GtkLabel(label)
        Gtk4.set_gtk_property!(l, :xalign, 1.0)
        Gtk4.set_gtk_property!(l, :margin_end, 6)
        grid[1, row+1] = l
        grid[2, row+1] = widget
        Gtk4.set_gtk_property!(widget, :hexpand, true)
        return widget
    end

    e_caster      = Gtk4.GtkEntry()
    e_port        = Gtk4.GtkSpinButton(1.0, 65535.0, 1.0)
    e_mount       = Gtk4.GtkEntry()
    e_user        = Gtk4.GtkEntry()
    e_pass        = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_pass, :visibility, false)
    c_tls         = Gtk4.GtkCheckButton("Use TLS / HTTPS")
    c_gga         = Gtk4.GtkCheckButton("Send GGA on connect (for VRS)")
    e_lat         = Gtk4.GtkEntry()
    e_lon         = Gtk4.GtkEntry()
    e_height      = Gtk4.GtkEntry()
    c_gps         = Gtk4.GtkCheckButton("GPS")
    c_glo         = Gtk4.GtkCheckButton("GLONASS")
    c_gal         = Gtk4.GtkCheckButton("Galileo")
    c_bds         = Gtk4.GtkCheckButton("BeiDou")
    c_incomplete  = Gtk4.GtkCheckButton("Solve epochs missing GPS")
    Gtk4.set_gtk_property!(c_incomplete, :tooltip_text,
        "An epoch missing a secondary constellation's frame is always solved. When the GPS " *
        "frame itself is missing: ticked = solve on whatever arrived (noisier, shows as " *
        "spikes); unticked = skip that epoch.")
    e_logdir      = Gtk4.GtkEntry()
    e_outfn       = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_outfn, :placeholder_text, "(auto-named on start)")
    cmb_mode      = Gtk4.GtkComboBoxText()
    push!(cmb_mode, "DFV"); push!(cmb_mode, "SFV")
    e_elv         = Gtk4.GtkSpinButton(0.0, 90.0, 1.0)
    # ---------- ANTEX (antenna calibration) ----------
    e_antex       = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_antex, :placeholder_text, "path to igs14_*.atx (optional)")
    Gtk4.set_gtk_property!(e_antex, :tooltip_text,
        "ANTEX file for the receiver antenna PCO/PCV. Browse… fills this " *
        "field; press Save profile to keep it, then Stop/Start the stream " *
        "so the bridge reloads the antenna model.")
    btn_antex_browse = Gtk4.GtkButton("Browse…")
    antex_row = Gtk4.GtkBox(:h); Gtk4.set_gtk_property!(antex_row, :spacing, 4)
    Gtk4.set_gtk_property!(e_antex, :hexpand, true)
    push!(antex_row, e_antex); push!(antex_row, btn_antex_browse)
    # ---------- SSR products caster (optional) ----------
    c_ssr         = Gtk4.GtkCheckButton("Use SSR corrections (RTCM 1057-1241)")
    e_ssr_caster  = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_ssr_caster, :placeholder_text, "e.g. products.igs-ip.net")
    e_ssr_port    = Gtk4.GtkSpinButton(1.0, 65535.0, 1.0)
    e_ssr_mount   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_ssr_mount, :placeholder_text, "e.g. SSRA00GFZ0")
    e_ssr_user    = Gtk4.GtkEntry()
    e_ssr_pass    = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_ssr_pass, :visibility, false)
    c_ssr_tls     = Gtk4.GtkCheckButton("Use TLS / HTTPS (SSR)")
    # ---------- Broadcast-ephemeris caster (optional) ----------
    c_eph         = Gtk4.GtkCheckButton("Use broadcast-ephemeris caster")
    e_eph_caster  = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_eph_caster, :placeholder_text, "e.g. products.igs-ip.net")
    e_eph_port    = Gtk4.GtkSpinButton(1.0, 65535.0, 1.0)
    e_eph_mount   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_eph_mount, :placeholder_text, "e.g. BCEP00BKG0")
    e_eph_user    = Gtk4.GtkEntry()
    e_eph_pass    = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_eph_pass, :visibility, false)
    c_eph_tls     = Gtk4.GtkCheckButton("Use TLS / HTTPS (eph)")

    # ---------- miniSEED feed (both sinks) ----------
    # CSV sink — path to a streaming CSV file the Python agent can tail.
    e_mseed_csv   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_csv, :placeholder_text,
        "(blank = disabled)   e.g. logs/PAT0_feed.csv")
    # Direct .mseed sink — output directory for SDS-style filenames.
    e_mseed_dir   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_dir, :placeholder_text,
        "(blank = disabled)   e.g. ./mseed")
    e_mseed_net   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_net, :placeholder_text, "Net code (e.g. CL)")
    e_mseed_sta   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_sta, :placeholder_text, "Station (blank = mountpoint)")
    e_mseed_loc   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_loc, :placeholder_text, "Location id (often blank)")
    e_mseed_chprefix = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_chprefix, :placeholder_text, "Channel prefix (LN, LX, …)")
    e_mseed_rate  = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_rate, :placeholder_text, "Sample rate (Hz)")
    e_mseed_scale = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_scale, :placeholder_text, "Counts/m (e.g. 1e7)")
    e_mseed_flush = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_mseed_flush, :placeholder_text,
        "Max sec before partial record flush (e.g. 10)")
    # SeedLink service: DataLink push of every flushed record to a ringserver.
    e_dl_host = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_dl_host, :placeholder_text,
        "(blank = off)   ringserver host, e.g. 127.0.0.1")
    Gtk4.set_gtk_property!(e_dl_host, :tooltip_text,
        "Push each miniSEED record to a ringserver over DataLink; ringserver serves SeedLink (port 18000) to SeisComP/ObsPy. Needs the mseed dir.")
    e_dl_port = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_dl_port, :placeholder_text, "DataLink port (ringserver default 16000)")
    e_link = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_link, :placeholder_text,
        "e.g. fibre direct to receiver caster / 4G via VPN / BKG relay TLS")
    Gtk4.set_gtk_property!(e_link, :tooltip_text,
        "Describes the network link behind this profile. Written into the " *
        "metrics CSV header, the Metrics window and /metrics.json so runs " *
        "over different links can be compared.")

    add_row!(0,  "Caster host:",       e_caster)
    add_row!(1,  "Port:",              e_port)
    add_row!(2,  "Mountpoint:",        e_mount)
    add_row!(3,  "User:",              e_user)
    add_row!(4,  "Password:",          e_pass)
    add_row!(5,  "TLS:",               c_tls)
    add_row!(6,  "VRS GGA upload:",    c_gga)
    add_row!(7,  "GGA latitude (°):",  e_lat)
    add_row!(8,  "GGA longitude (°):", e_lon)
    add_row!(9,  "GGA height (m):",    e_height)

    sys_box = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(sys_box, :spacing, 6)
    push!(sys_box, c_gps); push!(sys_box, c_glo); push!(sys_box, c_gal); push!(sys_box, c_bds)
    push!(sys_box, c_incomplete)
    add_row!(10, "Constellations:", sys_box)

    add_row!(14, "Log directory:",     e_logdir)
    add_row!(15, "Output filename:",   e_outfn)

    # Visual separator + SSR block
    sep_label = Gtk4.GtkLabel("──  SSR products caster (optional)  ──")
    Gtk4.set_gtk_property!(sep_label, :xalign, 0.0)
    Gtk4.set_gtk_property!(sep_label, :margin_top, 6)
    add_row!(16, "", sep_label)
    add_row!(17, "Enable SSR:",        c_ssr)
    add_row!(18, "SSR caster host:",   e_ssr_caster)
    add_row!(19, "SSR port:",          e_ssr_port)
    add_row!(20, "SSR mountpoint:",    e_ssr_mount)
    add_row!(21, "SSR user:",          e_ssr_user)
    add_row!(22, "SSR password:",      e_ssr_pass)
    add_row!(23, "SSR TLS:",           c_ssr_tls)

    # Visual separator + broadcast-eph block
    sep_label2 = Gtk4.GtkLabel("──  Broadcast-ephemeris caster (optional)  ──")
    Gtk4.set_gtk_property!(sep_label2, :xalign, 0.0)
    Gtk4.set_gtk_property!(sep_label2, :margin_top, 6)
    add_row!(24, "", sep_label2)
    add_row!(25, "Enable eph:",        c_eph)
    add_row!(26, "Eph caster host:",   e_eph_caster)
    add_row!(27, "Eph port:",          e_eph_port)
    add_row!(28, "Eph mountpoint:",    e_eph_mount)
    add_row!(29, "Eph user:",          e_eph_user)
    add_row!(30, "Eph password:",      e_eph_pass)
    add_row!(31, "Eph TLS:",           c_eph_tls)

    # Visual separator + miniSEED feed block
    sep_label3 = Gtk4.GtkLabel("──  miniSEED / SeedLink feed (optional)  ──")
    Gtk4.set_gtk_property!(sep_label3, :xalign, 0.0)
    Gtk4.set_gtk_property!(sep_label3, :margin_top, 6)
    add_row!(32, "", sep_label3)
    add_row!(33, "CSV sink path:",     e_mseed_csv)
    add_row!(34, "mseed dir:",         e_mseed_dir)
    add_row!(35, "Network:",           e_mseed_net)
    add_row!(36, "Station:",           e_mseed_sta)
    add_row!(37, "Location:",          e_mseed_loc)
    add_row!(38, "Channel prefix:",    e_mseed_chprefix)
    add_row!(39, "Sample rate (Hz):",  e_mseed_rate)
    add_row!(40, "Counts scale (/m):", e_mseed_scale)
    add_row!(41, "Flush interval (s):",e_mseed_flush)
    add_row!(42, "SeedLink (ringserver) host:", e_dl_host)
    add_row!(43, "DataLink port:",     e_dl_port)
    add_row!(44, "Link description:",  e_link)

    # ---------- Engine tab ----------
    engine_head = Gtk4.GtkGrid()
    Gtk4.set_gtk_property!(engine_head, :row_spacing, 4)
    Gtk4.set_gtk_property!(engine_head, :column_spacing, 10)
    push!(engine_box, engine_head)
    cmb_engine = Gtk4.GtkComboBoxText()
    engine_names_list = String[]
    e_engine_path = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_engine_path, :placeholder_text, "plug-in directory when the package is not installed, e.g. ../GaiaVario.jl")
    btn_engine_reload = Gtk4.GtkButton("Reload parameters")
    lbl_engine_desc = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_engine_desc, :wrap, true)
    Gtk4.set_gtk_property!(lbl_engine_desc, :xalign, 0.0)
    lbl_engine_banner = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_engine_banner, :use_markup, true)
    Gtk4.set_gtk_property!(lbl_engine_banner, :xalign, 0.0)
    Gtk4.set_gtk_property!(lbl_engine_banner, :margin_bottom, 4)
    push!(engine_box, lbl_engine_banner)
    function _erow!(row, label, w)
        l = Gtk4.GtkLabel(label); Gtk4.set_gtk_property!(l, :xalign, 1.0); Gtk4.set_gtk_property!(l, :margin_end, 6)
        engine_head[1, row] = l; engine_head[2, row] = w; Gtk4.set_gtk_property!(w, :hexpand, true); w
    end
    _erow!(1, "Engine:", cmb_engine)
    _erow!(2, "Plug-in directory:", e_engine_path)
    _erow!(3, "", btn_engine_reload)
    push!(engine_box, lbl_engine_desc)
    sep_engine = Gtk4.GtkLabel("──  Parameters of the selected engine  ──")
    Gtk4.set_gtk_property!(sep_engine, :xalign, 0.0); Gtk4.set_gtk_property!(sep_engine, :margin_top, 6)
    push!(engine_box, sep_engine)
    # PPPHVA keeps its dedicated widgets (they map to profile fields)
    ppphva_grid = Gtk4.GtkGrid()
    Gtk4.set_gtk_property!(ppphva_grid, :row_spacing, 4); Gtk4.set_gtk_property!(ppphva_grid, :column_spacing, 10)
    for (i, (lab, w)) in enumerate((("Process mode:", cmb_mode), ("Elevation cut (°):", e_elv), ("ANTEX file:", antex_row)))
        l = Gtk4.GtkLabel(lab); Gtk4.set_gtk_property!(l, :xalign, 1.0); Gtk4.set_gtk_property!(l, :margin_end, 6)
        ppphva_grid[1, i] = l; ppphva_grid[2, i] = w; Gtk4.set_gtk_property!(w, :hexpand, true)
    end
    push!(engine_box, ppphva_grid)
    # plug-in parameters: rebuilt from the engine's ParamSpec list
    plugin_grid = Gtk4.GtkGrid()
    Gtk4.set_gtk_property!(plugin_grid, :row_spacing, 4); Gtk4.set_gtk_property!(plugin_grid, :column_spacing, 10)
    push!(engine_box, plugin_grid)
    lbl_engine_err = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_engine_err, :wrap, true); Gtk4.set_gtk_property!(lbl_engine_err, :xalign, 0.0)
    push!(engine_box, lbl_engine_err)
    engine_widgets = Dict{String,Tuple{Symbol,Any,Vector{String}}}()   # key => (kind, widget, choices)

    function _clear_grid!(g)
        c = Gtk4.G_.get_first_child(g)
        while c !== nothing
            nxt = Gtk4.G_.get_next_sibling(c)
            Gtk4.G_.remove(g, c)
            c = nxt
        end
    end
    # nothing when the list is not filled or no row is active: callers then keep the profile's value
    function engine_selected()
        i = try; Gtk4.get_gtk_property(cmb_engine, :active, Int); catch; -1; end
        (1 <= i + 1 <= length(engine_names_list)) ? engine_names_list[i + 1] : nothing
    end
    engine_selected_or(default::AbstractString) = something(engine_selected(), String(default))
    # Current values of the plug-in widgets as strings (to keep them across a rebuild)
    function engine_values()
        d = Dict{String,String}()
        for (k, (kind, w, choices)) in engine_widgets
            if kind == :choice
                i = Gtk4.get_gtk_property(w, :active, Int); (1 <= i + 1 <= length(choices)) && (d[k] = choices[i + 1])
            elseif kind == :bool
                d[k] = string(Gtk4.get_gtk_property(w, :active, Bool))
            elseif kind == :float || kind == :int
                v = Gtk4.get_gtk_property(w, :value, Float64); d[k] = kind == :int ? string(round(Int, v)) : string(v)
            else
                d[k] = Gtk4.get_gtk_property(w, :text, String)
            end
        end
        return d
    end
    function update_engine_banner!(name::AbstractString, values::Dict{String,String})
        mode = get(values, lowercase(strip(name)) == "ppphva" ? "process_mode" : "mode", "")
        shown = uppercase(first(name, 1)) * name[2:end] * (isempty(mode) ? "" : " · " * mode)
        sess = get(state, :session, nothing)
        running = (sess !== nothing && sess.bridge_state !== nothing && !isempty(sess.bridge_state.engine_info)) ?
                  "  <span foreground=\"#0F6E56\">running now: " * _markup_esc(sess.bridge_state.engine_info) * "</span>" :
                  (sess !== nothing && isrunning(sess) ? "  <span foreground=\"#9A5B00\">streaming with " * _markup_esc(engine_label(sess.profile)) * "; changes apply at the next Start</span>" :
                   "  <small>(used at the next Start)</small>")
        Gtk4.set_gtk_property!(lbl_engine_banner, :label, "<big><b>Engine: " * _markup_esc(shown) * "</b></big>" * running)
    end
    function build_engine_params!(name::AbstractString, values::Dict{String,String})
        _clear_grid!(plugin_grid); empty!(engine_widgets)
        update_engine_banner!(name, values)
        Gtk4.set_gtk_property!(lbl_engine_err, :label, "")
        is_ppphva = lowercase(strip(name)) == "ppphva"
        Gtk4.set_gtk_property!(ppphva_grid, :visible, is_ppphva)
        Gtk4.set_gtk_property!(plugin_grid, :visible, !is_ppphva)
        is_ppphva && (Gtk4.set_gtk_property!(lbl_engine_desc, :label, "PPPHVA: Julia translation of PPPH-VA, the historical in-bridge path (ionosphere-free or single-frequency)."); return)
        specs = try
            engine_param_specs(name, Gtk4.get_gtk_property(e_engine_path, :text, String))
        catch err
            Gtk4.set_gtk_property!(lbl_engine_err, :label, "Engine \"$(name)\" not available: $(sprint(showerror, err))")
            return
        end
        Gtk4.set_gtk_property!(lbl_engine_desc, :label, EAPI.engine_description(Symbol(lowercase(strip(name)))))
        for (i, sp) in enumerate(specs)
            v = get(values, sp.key, sp.default === nothing ? "" : string(sp.default))
            w = if sp.kind == :choice
                c = Gtk4.GtkComboBoxText(); foreach(ch -> push!(c, ch), sp.choices)
                idx = something(findfirst(==(v), sp.choices), 1)
                Gtk4.set_gtk_property!(c, :active, idx - 1); c
            elseif sp.kind == :bool
                c = Gtk4.GtkCheckButton(""); Gtk4.set_gtk_property!(c, :active, v == "true"); c
            elseif sp.kind == :float || sp.kind == :int
                lo = isfinite(sp.min) ? sp.min : -1e9; hi = isfinite(sp.max) ? sp.max : 1e9
                s = Gtk4.GtkSpinButton(lo, hi, sp.step)
                sp.kind == :float && Gtk4.set_gtk_property!(s, :digits, sp.step < 1 ? 2 : 1)
                Gtk4.set_gtk_property!(s, :value, something(tryparse(Float64, v), isfinite(lo) ? lo : 0.0)); s
            else
                e = Gtk4.GtkEntry(); Gtk4.set_gtk_property!(e, :text, v); e
            end
            isempty(sp.help) || Gtk4.set_gtk_property!(w, :tooltip_text, sp.help)
            l = Gtk4.GtkLabel(sp.label * ":"); Gtk4.set_gtk_property!(l, :xalign, 1.0); Gtk4.set_gtk_property!(l, :margin_end, 6)
            plugin_grid[1, i] = l; plugin_grid[2, i] = w; Gtk4.set_gtk_property!(w, :hexpand, true)
            engine_widgets[sp.key] = (sp.kind, w, sp.choices)
        end
    end
    function set_engine_list!(current::AbstractString)
        names = available_engine_names(Gtk4.get_gtk_property(e_engine_path, :text, String))
        current in names || push!(names, String(current))
        if names != engine_names_list
            for _ in 1:length(engine_names_list)
                try; Gtk4.G_.remove(cmb_engine, 0); catch; break; end
            end
            empty!(engine_names_list); append!(engine_names_list, names)
            foreach(n -> push!(cmb_engine, n), names)
        end
        Gtk4.set_gtk_property!(cmb_engine, :active, something(findfirst(==(String(current)), engine_names_list), 1) - 1)
    end

    # ---------- State binding ----------
    state = Dict{Symbol,Any}(
        :profiles => profiles,
        :active   => active,
        :session  => nothing,
        :profiles_path => profiles_path,
    )

    function load_into_form!(p::NtripProfile)
        Gtk4.set_gtk_property!(e_caster, :text, p.caster)
        Gtk4.set_gtk_property!(e_port,   :value, p.port)
        Gtk4.set_gtk_property!(e_mount,  :text, p.mountpoint)
        Gtk4.set_gtk_property!(e_user,   :text, p.user)
        Gtk4.set_gtk_property!(e_pass,   :text, p.password)
        Gtk4.set_gtk_property!(c_tls,    :active, p.use_tls)
        Gtk4.set_gtk_property!(c_gga,    :active, p.send_gga)
        Gtk4.set_gtk_property!(e_lat,    :text, string(p.gga_lat_deg))
        Gtk4.set_gtk_property!(e_lon,    :text, string(p.gga_lon_deg))
        Gtk4.set_gtk_property!(e_height, :text, string(p.gga_height_m))
        Gtk4.set_gtk_property!(c_gps,    :active, p.enable_gps)
        Gtk4.set_gtk_property!(c_glo,    :active, p.enable_glo)
        Gtk4.set_gtk_property!(c_gal,    :active, p.enable_gal)
        Gtk4.set_gtk_property!(c_bds,    :active, p.enable_bds)
        Gtk4.set_gtk_property!(c_incomplete, :active, p.solve_incomplete_epochs)
        Gtk4.set_gtk_property!(e_logdir, :text, p.log_dir)
        Gtk4.set_gtk_property!(e_outfn,  :text, p.output_filename)
        Gtk4.set_gtk_property!(e_link,   :text, p.link_description)
        Gtk4.set_gtk_property!(cmb_mode, :active, p.process_mode == "SFV" ? 1 : 0)
        Gtk4.set_gtk_property!(e_elv,    :value, Int(p.elv_cutoff_deg))
        Gtk4.set_gtk_property!(e_antex,  :text,   p.antex_file)
        Gtk4.set_gtk_property!(c_ssr,        :active, p.use_ssr)
        Gtk4.set_gtk_property!(e_ssr_caster, :text,   p.ssr_caster)
        Gtk4.set_gtk_property!(e_ssr_port,   :value,  p.ssr_port)
        Gtk4.set_gtk_property!(e_ssr_mount,  :text,   p.ssr_mountpoint)
        Gtk4.set_gtk_property!(e_ssr_user,   :text,   p.ssr_user)
        Gtk4.set_gtk_property!(e_ssr_pass,   :text,   p.ssr_password)
        Gtk4.set_gtk_property!(c_ssr_tls,    :active, p.ssr_use_tls)
        Gtk4.set_gtk_property!(c_eph,        :active, p.use_eph)
        Gtk4.set_gtk_property!(e_eph_caster, :text,   p.eph_caster)
        Gtk4.set_gtk_property!(e_eph_port,   :value,  p.eph_port)
        Gtk4.set_gtk_property!(e_eph_mount,  :text,   p.eph_mountpoint)
        Gtk4.set_gtk_property!(e_eph_user,   :text,   p.eph_user)
        Gtk4.set_gtk_property!(e_eph_pass,   :text,   p.eph_password)
        Gtk4.set_gtk_property!(c_eph_tls,    :active, p.eph_use_tls)
        Gtk4.set_gtk_property!(e_mseed_csv,      :text, p.miniseed_csv_path)
        Gtk4.set_gtk_property!(e_mseed_dir,      :text, p.miniseed_mseed_dir)
        Gtk4.set_gtk_property!(e_mseed_net,      :text, p.miniseed_network)
        Gtk4.set_gtk_property!(e_mseed_sta,      :text, p.miniseed_station)
        Gtk4.set_gtk_property!(e_mseed_loc,      :text, p.miniseed_location)
        Gtk4.set_gtk_property!(e_mseed_chprefix, :text, p.miniseed_channel_prefix)
        Gtk4.set_gtk_property!(e_mseed_rate,     :text, string(p.miniseed_sample_rate_hz))
        Gtk4.set_gtk_property!(e_mseed_scale,    :text, string(p.miniseed_scale))
        Gtk4.set_gtk_property!(e_mseed_flush,    :text, string(p.miniseed_flush_interval_sec))
        Gtk4.set_gtk_property!(e_dl_host,        :text, p.datalink_host)
        Gtk4.set_gtk_property!(e_dl_port,        :text, string(p.datalink_port))
        # engine tab
        Gtk4.set_gtk_property!(e_engine_path, :text, p.engine_path)
        set_engine_list!(p.engine)
        vals = parse_engine_options(p.engine_options)
        haskey(vals, "mode") || (vals["mode"] = p.engine_mode)
        haskey(vals, "elev_mask_deg") || (vals["elev_mask_deg"] = string(p.elv_cutoff_deg))
        build_engine_params!(p.engine, vals)
    end
    function pull_from_form!(p::NtripProfile)
        p.caster        = Gtk4.get_gtk_property(e_caster, :text, String)
        p.port          = Int(Gtk4.get_gtk_property(e_port, :value, Float64))
        p.mountpoint    = Gtk4.get_gtk_property(e_mount, :text, String)
        p.user          = Gtk4.get_gtk_property(e_user, :text, String)
        p.password      = Gtk4.get_gtk_property(e_pass, :text, String)
        p.use_tls       = Gtk4.get_gtk_property(c_tls, :active, Bool)
        p.send_gga      = Gtk4.get_gtk_property(c_gga, :active, Bool)
        p.gga_lat_deg   = _safe_parse(Gtk4.get_gtk_property(e_lat,    :text, String), 0.0)
        p.gga_lon_deg   = _safe_parse(Gtk4.get_gtk_property(e_lon,    :text, String), 0.0)
        p.gga_height_m  = _safe_parse(Gtk4.get_gtk_property(e_height, :text, String), 0.0)
        p.enable_gps    = Gtk4.get_gtk_property(c_gps, :active, Bool)
        p.enable_glo    = Gtk4.get_gtk_property(c_glo, :active, Bool)
        p.enable_gal    = Gtk4.get_gtk_property(c_gal, :active, Bool)
        p.enable_bds    = Gtk4.get_gtk_property(c_bds, :active, Bool)
        p.solve_incomplete_epochs = Gtk4.get_gtk_property(c_incomplete, :active, Bool)
        p.log_dir       = Gtk4.get_gtk_property(e_logdir, :text, String)
        p.output_filename = Gtk4.get_gtk_property(e_outfn, :text, String)
        p.link_description = strip(Gtk4.get_gtk_property(e_link, :text, String))
        p.process_mode  = Gtk4.get_gtk_property(cmb_mode, :active, Int) == 1 ? "SFV" : "DFV"
        p.elv_cutoff_deg = Float64(Gtk4.get_gtk_property(e_elv, :value, Float64))
        p.antex_file    = Gtk4.get_gtk_property(e_antex, :text, String)
        # engine tab
        sel = engine_selected()
        sel === nothing || (p.engine = sel)          # an unfilled list never overwrites the profile
        p.engine_path = strip(Gtk4.get_gtk_property(e_engine_path, :text, String))
        if lowercase(p.engine) != "ppphva" && !isempty(engine_widgets)
            vals = engine_values()
            p.engine_options = join(("$(k)=$(v)" for (k, v) in sort!(collect(vals); by = first)), ",")
            haskey(vals, "mode") && (p.engine_mode = vals["mode"])
            haskey(vals, "elev_mask_deg") && (p.elv_cutoff_deg = _safe_parse(vals["elev_mask_deg"], p.elv_cutoff_deg))
        end
        p.use_ssr       = Gtk4.get_gtk_property(c_ssr,     :active, Bool)
        p.ssr_caster    = Gtk4.get_gtk_property(e_ssr_caster, :text, String)
        p.ssr_port      = Int(Gtk4.get_gtk_property(e_ssr_port, :value, Float64))
        p.ssr_mountpoint = Gtk4.get_gtk_property(e_ssr_mount, :text, String)
        p.ssr_user      = Gtk4.get_gtk_property(e_ssr_user, :text, String)
        p.ssr_password  = Gtk4.get_gtk_property(e_ssr_pass, :text, String)
        p.ssr_use_tls   = Gtk4.get_gtk_property(c_ssr_tls,  :active, Bool)
        p.use_eph       = Gtk4.get_gtk_property(c_eph,     :active, Bool)
        p.eph_caster    = Gtk4.get_gtk_property(e_eph_caster, :text, String)
        p.eph_port      = Int(Gtk4.get_gtk_property(e_eph_port, :value, Float64))
        p.eph_mountpoint = Gtk4.get_gtk_property(e_eph_mount, :text, String)
        p.eph_user      = Gtk4.get_gtk_property(e_eph_user, :text, String)
        p.eph_password  = Gtk4.get_gtk_property(e_eph_pass, :text, String)
        p.eph_use_tls   = Gtk4.get_gtk_property(c_eph_tls,  :active, Bool)
        p.miniseed_csv_path        = Gtk4.get_gtk_property(e_mseed_csv,      :text, String)
        p.miniseed_mseed_dir       = Gtk4.get_gtk_property(e_mseed_dir,      :text, String)
        p.miniseed_network         = Gtk4.get_gtk_property(e_mseed_net,      :text, String)
        p.miniseed_station         = Gtk4.get_gtk_property(e_mseed_sta,      :text, String)
        p.miniseed_location        = Gtk4.get_gtk_property(e_mseed_loc,      :text, String)
        p.miniseed_channel_prefix  = Gtk4.get_gtk_property(e_mseed_chprefix, :text, String)
        p.miniseed_sample_rate_hz  = _safe_parse(
            Gtk4.get_gtk_property(e_mseed_rate,  :text, String), p.miniseed_sample_rate_hz)
        p.miniseed_scale           = _safe_parse(
            Gtk4.get_gtk_property(e_mseed_scale, :text, String), p.miniseed_scale)
        p.miniseed_flush_interval_sec = _safe_parse(
            Gtk4.get_gtk_property(e_mseed_flush, :text, String), p.miniseed_flush_interval_sec)
        p.datalink_host = strip(Gtk4.get_gtk_property(e_dl_host, :text, String))
        p.datalink_port = round(Int, _safe_parse(
            Gtk4.get_gtk_property(e_dl_port, :text, String), Float64(p.datalink_port)))
    end

    function selected_profile()
        idx = Gtk4.get_gtk_property(profile_combo, :active, Int)
        names = sort!(collect(keys(state[:profiles])))
        idx < 0 && return nothing
        name = names[idx+1]
        return name, state[:profiles][name]
    end

    function refresh_combo!(new_active::AbstractString="")
        Gtk4.empty!(profile_combo)
        names = sort!(collect(keys(state[:profiles])))
        for n in names; push!(profile_combo, n); end
        i = _index_of(names, isempty(new_active) ? state[:active] : new_active)
        Gtk4.set_gtk_property!(profile_combo, :active, max(i - 1, 0))
    end

    sel = selected_profile()
    sel !== nothing && load_into_form!(sel[2])

    # ---------- Wiring ----------
    @gs_guarded Gtk4.signal_connect(profile_combo, "changed") do _
        sel = selected_profile()
        sel !== nothing && load_into_form!(sel[2])
        Gtk4.set_gtk_property!(status_inline, :label, "Loaded profile: $(sel[1]).")
    end

    @gs_guarded Gtk4.signal_connect(btn_save, "clicked") do _
        sel = selected_profile()
        sel === nothing && return
        name, p = sel
        pull_from_form!(p)
        state[:active] = name
        save_profiles(state[:active], state[:profiles], profiles_path)
        Gtk4.set_gtk_property!(status_inline, :label, "Saved $(name) to TOML.")
    end

    @gs_guarded Gtk4.signal_connect(btn_new, "clicked") do _
        base = "profile"
        i = 1
        while haskey(state[:profiles], "$(base)_$i"); i += 1; end
        nm = "$(base)_$i"
        state[:profiles][nm] = NtripProfile(name = nm)
        state[:active] = nm
        save_profiles(state[:active], state[:profiles], profiles_path)
        refresh_combo!(nm)
        Gtk4.set_gtk_property!(status_inline, :label, "Created new profile $nm.")
    end
    @gs_guarded Gtk4.signal_connect(btn_dup, "clicked") do _
        sel = selected_profile(); sel === nothing && return
        name, p = sel
        i = 1
        while haskey(state[:profiles], "$(name)_copy$i"); i += 1; end
        nm = "$(name)_copy$i"
        p2 = NtripProfile(); for f in fieldnames(NtripProfile); setfield!(p2, f, getfield(p, f)); end
        p2.name = nm
        state[:profiles][nm] = p2
        state[:active] = nm
        save_profiles(state[:active], state[:profiles], profiles_path)
        refresh_combo!(nm)
        Gtk4.set_gtk_property!(status_inline, :label, "Duplicated $(name) → $nm.")
    end
    @gs_guarded Gtk4.signal_connect(btn_del, "clicked") do _
        sel = selected_profile(); sel === nothing && return
        name, _ = sel
        length(state[:profiles]) <= 1 && (Gtk4.set_gtk_property!(status_inline, :label, "Cannot delete the only profile."); return)
        delete!(state[:profiles], name)
        state[:active] = first(sort!(collect(keys(state[:profiles]))))
        save_profiles(state[:active], state[:profiles], profiles_path)
        refresh_combo!(state[:active])
        Gtk4.set_gtk_property!(status_inline, :label, "Deleted $name.")
    end

    @gs_guarded Gtk4.signal_connect(btn_rename, "clicked") do _
        sel = selected_profile(); sel === nothing && return
        old_name, p = sel
        # Refuse to rename while a stream is running on this profile —
        # the bridge / mseed writers / log file all reference the live
        # profile object and renaming mid-stream would orphan their state.
        if state[:session] !== nothing && isrunning(state[:session])
            Gtk4.set_gtk_property!(status_inline, :label,
                "Stop the stream before renaming $(old_name).")
            return
        end
        _open_rename_dialog(Gtk4, win, old_name, state, profiles_path,
                            status_inline, refresh_combo!, load_into_form!)
    end

    @gs_guarded Gtk4.signal_connect(btn_about, "clicked") do _
        _open_about_dialog(Gtk4, win)
    end
    @gs_guarded Gtk4.signal_connect(cmb_engine, "changed") do _
        sel = engine_selected(); sel === nothing && return
        build_engine_params!(sel, engine_values())
    end
    Gtk4.GLib.g_timeout_add(2000) do
        try; update_engine_banner!(engine_selected_or("gaiavario"), engine_values()); catch; end
        true
    end
    @gs_guarded Gtk4.signal_connect(btn_engine_reload, "clicked") do _
        cur = engine_selected_or("gaiavario")
        set_engine_list!(cur)
        build_engine_params!(engine_selected_or(cur), engine_values())
    end
    @gs_guarded Gtk4.signal_connect(btn_engine, "clicked") do _
        _open_about_dialog(Gtk4, win; title = "About engine", text = engine_about_text(get(state, :session, nothing)),
                           logos = engine_selected_or("gaiavario") == "gaiavario" ? :deforming_gaia : false)
    end

    @gs_guarded Gtk4.signal_connect(btn_start, "clicked") do _
        sel = selected_profile(); sel === nothing && return
        name, p = sel
        pull_from_form!(p)
        save_profiles(name, state[:profiles], profiles_path)
        sess = NtripSession(p)
        state[:session] = sess
        try
            start!(sess)
            Gtk4.set_gtk_property!(btn_start, :sensitive, false)
            Gtk4.set_gtk_property!(btn_stop,  :sensitive, true)
            Gtk4.set_gtk_property!(btn_save,  :sensitive, false)
            Gtk4.set_gtk_property!(profile_combo, :sensitive, false)
            Gtk4.set_gtk_property!(engine_box, :sensitive, false)      # the engine cannot change while streaming
            Gtk4.set_gtk_property!(status_inline, :label, "Streaming…")
        catch err
            Gtk4.set_gtk_property!(status_label_error, :label, "Start failed: $(sprint(showerror, err))")
        end
    end

    @gs_guarded Gtk4.signal_connect(btn_stop, "clicked") do _
        sess = state[:session]; sess === nothing && return
        @async begin
            stop!(sess)
            Gtk4.set_gtk_property!(btn_start, :sensitive, true)
            Gtk4.set_gtk_property!(btn_stop,  :sensitive, false)
            Gtk4.set_gtk_property!(btn_save,  :sensitive, true)
            Gtk4.set_gtk_property!(profile_combo, :sensitive, true)
            Gtk4.set_gtk_property!(engine_box, :sensitive, true)
            Gtk4.set_gtk_property!(status_inline, :label, "Stopped.")
        end
    end

    # ---------- Live-status polling (500 ms) ----------
    # Wrapped in try/catch — an unhandled exception in a GLib timeout source
    # would cause GLib to drop the source and the panel would silently freeze.
    function refresh_status()
        try
            sess = state[:session]
            if sess === nothing
                Gtk4.set_gtk_property!(status_label_state, :label, "Idle")
                return true
            end
            st = sess.stats
            Gtk4.set_gtk_property!(status_label_state, :label,
                st.connected ? "Connected" : (isrunning(sess) ? "Connecting…" : "Disconnected"))
            let bs = sess.bridge_state, lab = engine_label(sess.profile)
                info = bs === nothing ? "" : bs.engine_info
                Gtk4.set_gtk_property!(status_label_engine, :label,
                    "<b>Engine: " * _markup_esc(lab) * "</b>" *
                    (isempty(info) ? "" : "  <small>" * _markup_esc(info) * "</small>"))
            end
            Gtk4.set_gtk_property!(status_label_bytes,  :label, "$(st.bytes_received) bytes received")
            Gtk4.set_gtk_property!(status_label_frames, :label, "$(st.frames_total) frames decoded ($(st.frames_crc_failed) bad CRC)")
            if !isempty(st.msg_counts)
                top = sort(collect(st.msg_counts), by = x -> -x[2])[1:min(end, 6)]
                Gtk4.set_gtk_property!(status_label_msgs, :label,
                    "Top msgs: " * join(["$(t[1])×$(t[2])" for t in top], "  "))
            end
            if !isnan(st.last_epoch_sod)
                Gtk4.set_gtk_property!(status_label_epoch, :label,
                    @sprintf("Epoch SOD: %.2f", st.last_epoch_sod))
                Gtk4.set_gtk_property!(status_label_sat, :label,
                    "Satellites this epoch: $(st.last_epoch_nsat)")
            end
            Gtk4.set_gtk_property!(status_label_missing, :label, _missing_summary(st))
            _set_overload_label!(Gtk4, lbl_overload_main, sess)
            if !isnan(st.last_residual_m)
                Gtk4.set_gtk_property!(status_label_resid, :label,
                    @sprintf("Residual σ: %.4f m", st.last_residual_m))
            end
            dx, dy, dz = st.last_position_dxyz
            if !any(isnan, (dx, dy, dz))
                Gtk4.set_gtk_property!(status_label_dxyz, :label,
                    @sprintf("dXYZ: %.4f / %.4f / %.4f m", dx, dy, dz))
            end
            # Per-stream "last frame at" timestamps with age in seconds and
            # the RTCM-decoded stream time when available.
            now_utc = Dates.now(Dates.UTC)
            gw      = st.gps_week
            tow     = st.last_obs_stream_tow
            Gtk4.set_gtk_property!(status_label_t_obs, :label,
                _format_stream_timestamp("obs caster", sess.profile.caster,
                                         sess.profile.mountpoint, st.last_obs_byte_at,
                                         now_utc, st.last_obs_stream_sod;
                                         gps_week = gw, obs_tow_s = tow,
                                         reconnects = st.reconnects_obs))
            if sess.profile.use_ssr && !isempty(sess.profile.ssr_caster)
                Gtk4.set_gtk_property!(status_label_t_ssr, :label,
                    _format_stream_timestamp("ssr caster", sess.profile.ssr_caster,
                                             sess.profile.ssr_mountpoint, st.last_ssr_byte_at,
                                             now_utc, st.last_ssr_stream_sod;
                                             gps_week = gw, obs_tow_s = tow,
                                             reconnects = st.reconnects_ssr))
            else
                Gtk4.set_gtk_property!(status_label_t_ssr, :label, "ssr caster   : (disabled)")
            end
            if sess.profile.use_eph && !isempty(sess.profile.eph_caster)
                Gtk4.set_gtk_property!(status_label_t_eph, :label,
                    _format_stream_timestamp("eph caster", sess.profile.eph_caster,
                                             sess.profile.eph_mountpoint, st.last_eph_byte_at,
                                             now_utc, st.last_eph_stream_sod;
                                             gps_week = gw, obs_tow_s = tow,
                                             reconnects = st.reconnects_eph))
            else
                Gtk4.set_gtk_property!(status_label_t_eph, :label, "eph caster   : (disabled)")
            end
            # Filter prerequisites — why we are / are not solving yet
            pos_mark = st.have_rec_pos    ? "✓" : "✗"
            eph_mark = st.have_ephemeris  ? "✓" : "✗"
            ssr_mark = st.have_ssr        ? "✓ (RTC=1)" : "—"
            prereq = "Prereqs: rec.pos $(pos_mark)  ·  eph $(eph_mark) ($(st.n_eph) sats)  ·  SSR $(ssr_mark) (orb $(st.n_ssr_orb)/clk $(st.n_ssr_clk))"
            Gtk4.set_gtk_property!(status_label_prereq, :label, prereq)
            Gtk4.set_gtk_property!(status_label_error, :label, st.error_message)
        catch err
            @warn "refresh_status caught error" err
        end
        return true   # keep timer alive
    end
    Gtk4.GLib.g_timeout_add(refresh_status, 500)

    # Register the plot draw function.  GtkCanvas calls it with the canvas
    # widget; we pull the Cairo context via getgc() and read the displacement
    # history from the current session.
    Gtk4.draw(plot_area) do widget
        try
            cr = Gtk4.getgc(widget)
            w  = Float64(Gtk4.width(widget))
            h  = Float64(Gtk4.height(widget))
            _draw_neu_plot(cr, w, h, state[:session])
        catch err
            @warn "plot draw failed" err
        end
    end
    # Twice-per-second redraw — same cadence as the status panel.
    # 1 Hz. Was 2 Hz: each redraw walks the whole 30-min buffer through Cairo on
    # the reader's thread; halving the rate halves that contention for free.
    @gs_guarded true Gtk4.GLib.g_timeout_add(1000) do
        Gtk4.draw(plot_area)
        true
    end

    # ANTEX file browse — open a native file-chooser dialog filtered to .atx.
    # The dialog is fire-and-forget: clicking Browse returns immediately and
    # the async callback writes the chosen path back into the entry. A
    # blocking `wait()` here would deadlock the Gtk event loop.
    @gs_guarded Gtk4.signal_connect(btn_antex_browse, "clicked") do _
        _open_atx_picker_async(Gtk4, win, e_antex)
    end

    @gs_guarded Gtk4.signal_connect(btn_debug, "clicked") do _
        _open_debug_window(state, Gtk4)
    end

    @gs_guarded Gtk4.signal_connect(btn_metrics, "clicked") do _
        _open_metrics_window(state, Gtk4)
    end
    @gs_guarded Gtk4.signal_connect(btn_plot, "clicked") do _
        _open_plot_window(state, Gtk4)
    end

    @gs_guarded Gtk4.signal_connect(btn_flush, "clicked") do _
        sess = state[:session]
        if sess === nothing
            Gtk4.set_gtk_property!(status_inline, :label,
                "Flush: no session — start a stream first.")
        else
            try
                flush_session_data!(sess)
                Gtk4.set_gtk_property!(status_inline, :label,
                    "Flushed — buffers cleared, miniSEED files deleted, CSV truncated. " *
                    "New samples start from the next accepted epoch.")
            catch err
                @warn "flush failed" err
                Gtk4.set_gtk_property!(status_inline, :label,
                    "Flush failed: $(sprint(showerror, err))")
            end
        end
    end

    @gs_guarded Gtk4.signal_connect(win, "close-request") do _
        sess = state[:session]
        sess !== nothing && stop!(sess)
        false
    end

    # ---- Main-window show + present -----------------------------------
    # `show` makes the window visible; `present` raises it above other
    # windows and forces a focus.  Without `present` the window
    # occasionally opens behind the launching terminal on multi-monitor
    # / RDP / locked-screen sessions — symptom: taskbar shows the entry
    # but the user sees nothing.  Both calls are wrapped so that a GTK
    # backend hiccup still prints something useful to the console
    # rather than dying silently.
    try
        Gtk4.show(win)
        try
            Gtk4.present(win)
        catch err
            @debug "GtkWindow.present failed (non-fatal)" err
        end
        @info "GaiaSeis: main window shown" size=(920, 600)
    catch err
        @error "GaiaSeis: failed to show main window" exception=(err, catch_backtrace())
        rethrow()
    end
    # Developer handle: the widgets a soak/automation script needs to drive
    # the main window exactly like a user would (select a profile, press
    # Start/Stop/Plot/Metrics). Not an auto-start hook — nothing happens
    # unless a script uses it. See tools/gui_soak.jl.
    _GUI_HANDLES[] = Dict{Symbol,Any}(:state => state, :win => win, :combo => profile_combo,
                                       :btn_start => btn_start, :btn_stop => btn_stop,
                                       :btn_plot => btn_plot, :btn_metrics => btn_metrics)
    return win
end
const _GUI_HANDLES = Ref{Any}(nothing)

# Helpers
function _index_of(v::AbstractVector, x)
    i = findfirst(==(x), v)
    return i === nothing ? 1 : i
end
function _safe_parse(s::AbstractString, default::Float64)
    v = tryparse(Float64, strip(s))
    return v === nothing ? default : v
end

const _GPS_EPOCH = DateTime(1980, 1, 6)

# Convert a (gps_week, time_of_week_seconds) pair into a UTC DateTime.
# Ignores the GPS-UTC leap-second offset (≈18 s in 2026) — fine for date
# display, off by <1 minute for the seconds field which we round anyway.
_gps_datetime(week::Integer, tow_s::Real) =
    _GPS_EPOCH + Dates.Millisecond(7 * 86_400_000 * Int(week) + round(Int64, tow_s * 1000))

# Reconstruct a `DateTime` for a stream sample. The PREFERRED source is the
# GPS week from 1019 ephemeris (`gps_week`) plus the obs TOW
# (`obs_tow_s`) — those come from the RTCM payload itself and give the
# *true* capture date, even for replays. When that pair is available we
# anchor every stream's SOD to the same day-of-week as the obs stream.
# Falls back to the wall-clock byte-arrival timestamp (±12 h day shift)
# when the GPS week hasn't been seen yet.
function _stream_datetime(sod::Float64, anchor::DateTime;
                          gps_week::Int = 0, obs_tow_s::Float64 = NaN)
    isnan(sod) && return nothing
    sod_mod = mod(sod, 86400.0)
    if gps_week > 0 && !isnan(obs_tow_s)
        # Obs day-of-week from the TOW (integer count of full days since
        # the start of the GPS week). Pin every stream's SOD to that day.
        dow = floor(Int, mod(obs_tow_s, 7*86400.0) / 86400)
        return _gps_datetime(gps_week, dow * 86400.0 + sod_mod)
    end
    # Wall-clock fallback (live mode, before any 1019 has arrived).
    anchor == DateTime(0) && return nothing
    anchor_sod = Dates.value(Dates.Time(anchor) - Dates.Time(0)) / 1_000_000_000
    diff = sod_mod - anchor_sod
    day_offset = diff > 43200.0 ? -1 :
                  diff < -43200.0 ?  1 : 0
    return DateTime(Dates.Date(anchor) + Dates.Day(day_offset)) +
           Dates.Millisecond(round(Int64, sod_mod * 1000))
end

# Build the "<label>: caster/mount  rx HH:MM:SSZ (Δ ago)  stream …" line
# for the per-stream timestamp row in the status panel.  `t_rx` is the
# wall-clock UTC of the last byte; `stream_sod` is the time decoded from
# the RTCM payload itself (NaN when no message of that kind has arrived).
# The stream portion now also includes the full UTC date (`YYYY-MM-DD`) so
# replays of historical data are visually distinguishable from live feeds.
# Stale streams (>30 s) get a visual ⚠ marker.
function _format_stream_timestamp(label::AbstractString, caster::AbstractString,
                                   mount::AbstractString, t_rx::DateTime,
                                   now_utc::DateTime, stream_sod::Float64 = NaN;
                                   gps_week::Int = 0,
                                   obs_tow_s::Float64 = NaN,
                                   reconnects::Int = 0)
    base = "$(rpad(label, 12))" * ": " * (isempty(caster) ? "(no caster)" :
            caster * (isempty(mount) ? "" : "/" * mount))
    t_rx == DateTime(0) && return base * "   no data yet"
    rx_hms = Dates.format(t_rx, "HH:MM:SS") * "Z"
    age_s  = Dates.value(now_utc - t_rx) / 1000
    mark   = age_s > 30 ? "  ⚠ stalled" : ""
    # The reader reconnects on its own now; showing the tally makes a
    # flapping caster obvious instead of it looking like a clean stream.
    reconnects > 0 && (mark *= "  ↻$(reconnects)")
    if isnan(stream_sod)
        return base * @sprintf("   rx %s (%.1f s ago)%s", rx_hms, age_s, mark)
    end
    s    = mod(stream_sod, 86400.0)
    hh   = floor(Int, s / 3600); s -= 3600*hh
    mm   = floor(Int, s / 60);   s -= 60*mm
    sec  = s
    stream_hms = @sprintf("%02d:%02d:%05.2f", hh, mm, sec)
    stream_dt  = _stream_datetime(stream_sod, t_rx;
                                   gps_week = gps_week,
                                   obs_tow_s = obs_tow_s)
    date_str   = stream_dt === nothing ? "" :
                  Dates.format(stream_dt, "yyyy-mm-dd ")
    return base * @sprintf("   rx %s (%.1f s ago)  stream %s%s%s",
                            rx_hms, age_s, date_str, stream_hms, mark)
end

# ---------- Live NEU displacement plot ----------
# Cairo-drawn time series of the last `displacement_history` points. Three
# colour-coded lines (N red, E green, U blue) on a shared auto-scaled y-axis
# in millimetres; the x-axis spans whatever epochs are in the buffer.
function _draw_neu_plot(cr, w::Float64, h::Float64, sess)
    # White background
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)
    # Plot margins
    ml, mr, mt, mb = 36.0, 8.0, 8.0, 18.0
    pw = w - ml - mr; ph = h - mt - mb
    pw <= 10 || ph <= 10 || (pw > 0 && ph > 0) || return

    # Plot frame
    Main.Gtk4.set_source_rgb(cr, 0.75, 0.75, 0.75)
    Main.Gtk4.set_line_width(cr, 1.0)
    Main.Gtk4.rectangle(cr, ml, mt, pw, ph); Main.Gtk4.stroke(cr)

    # Read the data (may be empty)
    hist = sess === nothing ? NTuple{4,Float64}[] : sess.stats.displacement_history
    n = length(hist)
    if n < 2
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 11.0)
        Main.Gtk4.move_to(cr, ml + 4, mt + 16)
        Main.Cairo.show_text(cr, n == 0 ? "(no displacement samples yet — start the stream)"
                                    : "(waiting for second epoch…)")
        return
    end

    # Compute y-range from the data (in millimetres)
    ymin = Inf; ymax = -Inf
    for (_, N, E, U) in hist
        for v in (N, E, U)
            isnan(v) && continue
            v_mm = v * 1000
            ymin = min(ymin, v_mm); ymax = max(ymax, v_mm)
        end
    end
    if !isfinite(ymin) || !isfinite(ymax)
        return
    end
    if ymax - ymin < 1.0
        c = 0.5 * (ymin + ymax)
        ymin, ymax = c - 1.0, c + 1.0
    end
    # 8% padding above/below
    pad = 0.08 * (ymax - ymin)
    ymin -= pad; ymax += pad

    # Map (i, value) → canvas (x, y).  i runs 1..n along x.
    px(i) = ml + (pw * (i - 1)) / max(n - 1, 1)
    py(v) = mt + ph - (ph * (v - ymin) / (ymax - ymin))

    # Y axis ticks + grid + labels (4 ticks)
    Main.Gtk4.set_source_rgb(cr, 0.85, 0.85, 0.85)
    Main.Gtk4.set_line_width(cr, 0.5)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 10.0)
    for t in 0:4
        v   = ymin + (ymax - ymin) * t / 4
        yy  = py(v)
        Main.Gtk4.move_to(cr, ml,      yy); Main.Gtk4.line_to(cr, ml + pw, yy); Main.Gtk4.stroke(cr)
        Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
        Main.Gtk4.move_to(cr, 2.0, yy + 4)
        Main.Cairo.show_text(cr, @sprintf("%6.1f", v))
        Main.Gtk4.set_source_rgb(cr, 0.85, 0.85, 0.85)
    end

    # Zero line
    if ymin < 0 < ymax
        Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
        Main.Gtk4.set_line_width(cr, 0.8)
        Main.Gtk4.move_to(cr, ml,      py(0.0))
        Main.Gtk4.line_to(cr, ml + pw, py(0.0))
        Main.Gtk4.stroke(cr)
    end

    # Level-of-detail, same as the Plot window (`_lod_indices`): draw only the
    # per-pixel-column min/max, so a 30-min buffer costs ~2 points per column
    # instead of one line_to per sample, and a single-sample spike survives.
    # Without this the inline canvas walked all ~18 000 samples every redraw
    # on the reader's thread.
    times = Float64[tup[1] for tup in hist]
    tspan_lod = max(times[end] - times[1], 1.0)

    # Three series (skip NaNs by restarting the path), thin line + sample dots.
    function draw_series(idx::Int, r::Float64, g::Float64, b::Float64)
        Main.Gtk4.set_source_rgb(cr, r, g, b)
        Main.Gtk4.set_line_width(cr, 0.8)
        vals = Float64[tup[1 + idx] * 1000 for tup in hist]   # 2=N, 3=E, 4=U → idx 1..3
        lod  = _lod_indices(times, vals, times[1], tspan_lod, pw)
        moving = false
        for i in lod
            v = vals[i]
            if isnan(v); moving = false; continue; end
            x = px(i); y = py(v)
            if !moving
                Main.Gtk4.move_to(cr, x, y); moving = true
            else
                Main.Gtk4.line_to(cr, x, y)
            end
        end
        Main.Gtk4.stroke(cr)
        # Sample markers (skip when too dense for the small inline canvas).
        if length(lod) <= 400
            for i in lod
                v = vals[i]
                isnan(v) && continue
                Main.Cairo.arc(cr, px(i), py(v), 1.3, 0.0, 2π); Main.Gtk4.fill(cr)
            end
        end
    end
    draw_series(1, 0.80, 0.10, 0.10)   # N red
    draw_series(2, 0.10, 0.55, 0.10)   # E green
    draw_series(3, 0.10, 0.20, 0.80)   # U blue

    # Footer
    Main.Gtk4.set_source_rgb(cr, 0.4, 0.4, 0.4)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 10.0)
    Main.Gtk4.move_to(cr, ml + 2, h - 4)
    span_s = hist[end][1] - hist[1][1]
    Main.Cairo.show_text(cr, @sprintf("last %d samples · span ≈ %.0f s",
                                  n, span_s))
end

# Open a native file picker for `.atx` and, when the user picks one, write
# the path into `entry`. The dialog runs asynchronously — the function
# Static text shown by the About dialog. Drafted on the basis that:
#   * PPPH-VA (the upstream MATLAB toolkit) ships without a LICENSE file
#     in the bundle, so we credit the upstream authors verbatim per the
#     PPPHVA.jl README and link the user back to the original publication.
#   * The Julia translation (PPPHVA.jl) and GaiaSeis itself are
#     authored by Panagiotis Elias and released under the MIT licence; the
#     user can change this label freely.
#   * The EU Horizon-Europe acknowledgement uses the mandatory wording
#     from the Grant Agreement Annex 5 (compulsory for all HE-funded
#     dissemination). Grant number is left as ____ — drop the actual
#     number from the project's signed grant agreement before publishing.
const _ABOUT_TEXT = """
GaiaSeis — GNSS-based real-time seismogeodesy (variometric approach)
            (formerly NtripClient.jl)

Version            : $(_SOFTWARE_VERSION)
Author             : Panagiotis Elias  <pelias@upatras.gr>
Copyright          : © 2026 Panagiotis Elias
Affiliation        : Deforming Gaia Lab,
                     Department of Geology, University of Patras, Greece
Repository         : (to be published)
Licence            : GNU Affero General Public License v3.0 (AGPL-3.0-only)
                     for the software; the documents (manual, reports)
                     under CC BY-NC 4.0. See LICENSE at the repository root.
Citation           : Elias P. (2026). GaiaSeis: GNSS-based real-time
                     seismogeodesy via the variometric approach. Deforming
                     Gaia Lab, University of Patras, Greece.

────────────────────────────────────────────────────────────────────────
Platform and engines

GaiaSeis is the platform: NTRIP client, RTCM 3 decoder (written from
RTCM 10403.3), epoch grouping, outputs (miniSEED, SeedLink via
ringserver, web page, GUI) and the quality gate. The displacement is
computed by an engine plug-in selected in the profile ("About engine"
describes the one in use):

  GaiaVario   in-house variometric engine, written for this platform
              from the public sources (ICDs, IERS 2010, Niell 1996,
              Wu et al. 1993); AGPL-3.0.
  ppphva      in-bridge path for the author's Julia translation of
              PPPH-VA (Bahadur, Bezcioglu, Yigit, GPS Solutions 28:31,
              2024); not distributed.

────────────────────────────────────────────────────────────────────────
Acknowledgements

GaiaSeis grew out of the TRANSFORM² project and owes much to its GNSS
partners: Jan Kapłon, Iwona Kudłacik, Adrian Kaczmarek, Eduard Ilie
Nastase, Alexandru Tiganescu, David Zuliani, Paolo Fabris, Antonio
Avallone, Pierre Briole, Simon Bufferal, Vassilis Sakkas, Semih
Ergintav, Efthimios Sokos and Andreas Karakonstantis.

────────────────────────────────────────────────────────────────────────
Funding

This work is part of the TRANSFORM² project, which aims to improve
physical and digital infrastructure across Near-Fault Observatories
(NFOs) in Europe. TRANSFORM² is funded by the European Union under
project number 101188365 within the HORIZON-INFRA-2024-DEV-01-01 call.

Project website:  https://www.transform2-project.eu/

Views and opinions expressed are however those of the author(s) only
and do not necessarily reflect those of the European Union or the
European Research Executive Agency (REA). Neither the European Union
nor the granting authority can be held responsible for them.

────────────────────────────────────────────────────────────────────────
Disclaimer

This is research software, provided "as is", without warranty of any
kind. It is intended for scientific exploration of GNSS-based seismo-
geodesy; it is not certified for safety-critical or navigation use.
Field deployments and operational decisions remain the responsibility
of the user.
"""

# Pango-markup escape for labels built from free text (engine names, info strings).
_markup_esc(x) = replace(String(x), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# About dialog — scrollable read-only text, single "Close" button.
# `logos`: true = the full GaiaSeis banner, false = none, :deforming_gaia = the lab logo and caption only
function _open_about_dialog(Gtk4, parent; title::AbstractString = "About GaiaSeis", text::AbstractString = _ABOUT_TEXT, logos = true)
    dlg = Gtk4.GtkWindow(title, 680, 640)
    Gtk4.set_gtk_property!(dlg, :transient_for, parent)
    Gtk4.set_gtk_property!(dlg, :modal, true)
    _apply_window_icon!(Gtk4, dlg)
    outer = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(outer, :spacing, 8)
    Gtk4.set_gtk_property!(outer, :margin_top, 12)
    Gtk4.set_gtk_property!(outer, :margin_bottom, 12)
    Gtk4.set_gtk_property!(outer, :margin_start, 14)
    Gtk4.set_gtk_property!(outer, :margin_end, 14)
    push!(dlg, outer)

    # Single-row banner — only used here in the About dialog.
    # [GaiaSeis icon] [GaiaSeis wordmark (2-line subtitle)]
    # [CRL logo] [Deforming Gaia logo] [Deforming Gaia Lab caption]
    # Logos at 56 px so the whole row fits on one line inside the 680-px
    # dialog width without horizontal scrolling. The 2-line wordmark
    # leaves enough horizontal slack for the lab caption right of the
    # DG oval.
    logo_strip = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(logo_strip, :spacing, 10)
    Gtk4.set_gtk_property!(logo_strip, :halign, 3)   # CENTER
    Gtk4.set_gtk_property!(logo_strip, :margin_bottom, 10)
    logos === true && push!(outer, logo_strip)
    if logos === :deforming_gaia
        dg_strip = Gtk4.GtkBox(:h)
        Gtk4.set_gtk_property!(dg_strip, :spacing, 10)
        Gtk4.set_gtk_property!(dg_strip, :halign, 3)
        Gtk4.set_gtk_property!(dg_strip, :margin_bottom, 10)
        let lg = _make_logo(Gtk4, "GaiaSeis_icon"; height = 64)   # the platform, then the engine's lab
            lg === nothing || push!(dg_strip, lg)
        end
        let lg = _make_logo(Gtk4, "DeformingGaia_logo"; height = 64)
            lg === nothing || push!(dg_strip, lg)
        end
        push!(dg_strip, _make_dglab_caption(Gtk4; size = :plot))
        push!(outer, dg_strip)
    end

    let lg = _make_logo(Gtk4, "GaiaSeis_icon"; height = 56)
        lg === nothing || push!(logo_strip, lg)
    end
    push!(logo_strip, _make_wordmark(Gtk4; size = :plot))
    let lg = _make_logo(Gtk4, "CRL_logo"; height = 56)
        lg === nothing || push!(logo_strip, lg)
    end
    let lg = _make_logo(Gtk4, "DeformingGaia_logo"; height = 56)
        lg === nothing || push!(logo_strip, lg)
    end
    push!(logo_strip, _make_dglab_caption(Gtk4; size = :plot))

    scrolled = Gtk4.GtkScrolledWindow()
    Gtk4.set_gtk_property!(scrolled, :hexpand, true)
    Gtk4.set_gtk_property!(scrolled, :vexpand, true)
    push!(outer, scrolled)

    buffer = Gtk4.GtkTextBuffer()
    tv     = Gtk4.GtkTextView(buffer)          # not `text`: that is the dialog's content
    Gtk4.set_gtk_property!(tv, :monospace, true)
    Gtk4.set_gtk_property!(tv, :editable, false)
    Gtk4.set_gtk_property!(tv, :wrap_mode, 0)   # NONE — preserve fixed layout
    scrolled[] = tv
    try
        Gtk4.set_gtk_property!(buffer, :text, String(text))
    catch
        try; Gtk4.G_.set_text(buffer, String(text), Cint(-1)); catch; end
    end

    btns = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(btns, :spacing, 6)
    push!(outer, btns)
    b_copy  = Gtk4.GtkButton("Copy to clipboard")
    b_close = Gtk4.GtkButton("Close")
    spacer  = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(spacer, :hexpand, true)
    push!(btns, b_copy); push!(btns, spacer); push!(btns, b_close)

    @gs_guarded Gtk4.signal_connect(b_copy, "clicked") do _
        try; Base.clipboard(String(text)); catch err; @debug "clipboard copy failed" err; end
    end
    @gs_guarded Gtk4.signal_connect(b_close, "clicked") do _
        Gtk4.close(dlg)
    end
    Gtk4.show(dlg)
    return dlg
end

# Small modal-ish dialog to rename a profile. Pops up next to the main
# window, validates the new name against the existing keys (non-empty,
# unique), and on Apply:
#   1. rewires `state[:profiles][new_name] = state[:profiles][old_name]`
#   2. updates the profile's own `.name` field
#   3. flips `state[:active]` so the combo lands on the renamed entry
#   4. persists to TOML and refreshes the combo
# Cancel / close-window leaves everything untouched.
function _open_rename_dialog(Gtk4, parent, old_name::AbstractString,
                              state, profiles_path::AbstractString,
                              status_inline, refresh_combo!, load_into_form!)
    dlg = Gtk4.GtkWindow("Rename profile", 380, 140)
    Gtk4.set_gtk_property!(dlg, :transient_for, parent)
    Gtk4.set_gtk_property!(dlg, :modal, true)
    _apply_window_icon!(Gtk4, dlg)
    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 8)
    Gtk4.set_gtk_property!(box, :margin_top, 12)
    Gtk4.set_gtk_property!(box, :margin_bottom, 12)
    Gtk4.set_gtk_property!(box, :margin_start, 14)
    Gtk4.set_gtk_property!(box, :margin_end, 14)
    push!(dlg, box)

    push!(box, Gtk4.GtkLabel("Old: $(old_name)"))
    entry = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(entry, :text, old_name)
    Gtk4.set_gtk_property!(entry, :placeholder_text, "new profile name")
    push!(box, entry)

    err_label = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(err_label, :xalign, 0.0)
    push!(box, err_label)

    btns = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(btns, :spacing, 6)
    push!(box, btns)
    b_ok     = Gtk4.GtkButton("Apply")
    b_cancel = Gtk4.GtkButton("Cancel")
    push!(btns, b_ok); push!(btns, b_cancel)

    @gs_guarded Gtk4.signal_connect(b_ok, "clicked") do _
        new_name = strip(Gtk4.get_gtk_property(entry, :text, String))
        if isempty(new_name)
            Gtk4.set_gtk_property!(err_label, :label, "Name cannot be empty.")
            return
        end
        if new_name == old_name
            Gtk4.close(dlg); return
        end
        if haskey(state[:profiles], new_name)
            Gtk4.set_gtk_property!(err_label, :label,
                "A profile named \"$new_name\" already exists.")
            return
        end
        # Rewire the dict + update the profile's own .name field so its
        # TOML key and self-name stay in sync.
        p = state[:profiles][old_name]
        p.name = String(new_name)
        state[:profiles][new_name] = p
        delete!(state[:profiles], old_name)
        state[:active] = String(new_name)
        try
            save_profiles(state[:active], state[:profiles], profiles_path)
        catch err
            Gtk4.set_gtk_property!(err_label, :label,
                "Save failed: $(sprint(showerror, err))")
            return
        end
        refresh_combo!(state[:active])
        load_into_form!(p)
        Gtk4.set_gtk_property!(status_inline, :label,
            "Renamed: $(old_name) → $(new_name).")
        Gtk4.close(dlg)
    end
    @gs_guarded Gtk4.signal_connect(b_cancel, "clicked") do _
        Gtk4.close(dlg)
    end
    Gtk4.show(dlg)
    return dlg
end

# returns immediately so the Gtk main loop keeps processing events while the
# user navigates the picker. A blocking `wait()` here would deadlock the
# loop (the dialog's "response" callback would never fire because we'd be
# holding the only Julia task that can drive it).
function _open_atx_picker_async(Gtk4, parent, entry)
    # Uses Gtk4.jl's own `open_dialog` (GtkFileChooserNative + "response"
    # signal) instead of a hand-rolled GtkFileDialog + G_.open async callback:
    # the raw GIO callback path never delivered the chosen file on this
    # Gtk4.jl/GTK combination (2026-09-10), so the entry never changed.
    current = Gtk4.get_gtk_property(entry, :text, String)
    candidates = String[]
    isempty(current) || push!(candidates, isfile(current) ? dirname(current) : current)
    push!(candidates, app_root())
    push!(candidates, joinpath(app_root(), "..", "PPPH_VA", "PPPH_VA_final", "6.Example", "1"))
    push!(candidates, homedir())
    initial_dir = ""
    for c in candidates
        ap = abspath(c)
        if isdir(ap); initial_dir = ap; break; end
    end
    try
        Gtk4.open_dialog("Choose ANTEX (.atx) file", parent, ("*.atx", "*.ATX", "*");
                         start_folder = initial_dir) do path
            try
                if path isa AbstractString && !isempty(path)
                    Gtk4.set_gtk_property!(entry, :text, String(path))
                    @info "ANTEX file selected — press Save profile to keep it" path=path
                end
            catch err
                @warn "ANTEX selection could not be applied" err
            end
            nothing
        end
    catch err
        @warn "ANTEX file dialog failed to open — paste the path into the entry manually" err
    end
    return
end

# ---------- Debug window ----------
# A separate Gtk window showing the diagnostic dump for the current session.
# `Refresh` re-runs the dump; `Copy` puts it on the system clipboard; the
# dump is also auto-saved to logs/debug_<timestamp>.txt every time it's
# refreshed so you can paste the file content if the clipboard misbehaves.
function _open_debug_window(state, Gtk4)
    win = Gtk4.GtkWindow("GaiaSeis — Debug", 900, 640)
    _apply_window_icon!(Gtk4, win)
    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 6)
    Gtk4.set_gtk_property!(box, :margin_top, 10)
    Gtk4.set_gtk_property!(box, :margin_bottom, 10)
    Gtk4.set_gtk_property!(box, :margin_start, 10)
    Gtk4.set_gtk_property!(box, :margin_end, 10)
    push!(win, box)

    header_label = Gtk4.GtkLabel("Diagnostic dump (refresh to re-sample, copy to grab the text):")
    Gtk4.set_gtk_property!(header_label, :xalign, 0.0)
    push!(box, header_label)

    scrolled = Gtk4.GtkScrolledWindow()
    Gtk4.set_gtk_property!(scrolled, :vexpand, true)
    Gtk4.set_gtk_property!(scrolled, :hexpand, true)
    Gtk4.set_gtk_property!(scrolled, :min_content_height, 480)
    push!(box, scrolled)

    buffer = Gtk4.GtkTextBuffer()
    text = Gtk4.GtkTextView(buffer)
    Gtk4.set_gtk_property!(text, :monospace, true)
    Gtk4.set_gtk_property!(text, :editable, false)
    Gtk4.set_gtk_property!(text, :wrap_mode, 0)   # NONE — preserve formatting
    scrolled[] = text

    btns = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(btns, :spacing, 6)
    push!(box, btns)
    btn_refresh = Gtk4.GtkButton("Refresh")
    btn_copy    = Gtk4.GtkButton("Copy to clipboard")
    btn_save    = Gtk4.GtkButton("Save to file")
    last_saved  = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(last_saved, :hexpand, true)
    Gtk4.set_gtk_property!(last_saved, :xalign, 1.0)
    push!(btns, btn_refresh); push!(btns, btn_copy)
    push!(btns, btn_save);    push!(btns, last_saved)

    function _sample_and_show()
        sess = state[:session]
        txt = sess === nothing ?
              "(no session has been started yet — click Start stream first, then Refresh)" :
              diagnostic_dump(sess)
        # GtkTextBuffer accepts `:text` as a settable property in most Gtk4.jl
        # versions; fall back to the raw G_.set_text wrapper if not.
        try
            Gtk4.set_gtk_property!(buffer, :text, txt)
        catch
            try
                Gtk4.G_.set_text(buffer, txt, Cint(-1))
            catch err
                @warn "could not push text into debug buffer" err
            end
        end
        return txt
    end
    function _save_to_file(txt)
        log_dir = logs_dir()
        mkpath(log_dir)
        path = joinpath(log_dir, "debug_" * Dates.format(Dates.now(), "yyyymmdd_HHMMSS") * ".txt")
        open(path, "w") do io; write(io, txt); end
        Gtk4.set_gtk_property!(last_saved, :label, "Saved → " * path)
        return path
    end

    @gs_guarded Gtk4.signal_connect(btn_refresh, "clicked") do _
        _sample_and_show()
    end
    @gs_guarded Gtk4.signal_connect(btn_copy, "clicked") do _
        txt = _sample_and_show()
        # System clipboard via Julia's stdlib (works on Win/Mac/Linux when
        # InteractiveUtils is loaded — it is when launched with `julia -i`).
        ok = false
        try
            Base.clipboard(txt); ok = true
        catch
        end
        if !ok
            try
                @eval Main begin
                    using InteractiveUtils
                    InteractiveUtils.clipboard($txt)
                end
                ok = true
            catch err
                @warn "clipboard copy failed" err
            end
        end
        # Always also save to disk as a fallback
        path = _save_to_file(txt)
        Gtk4.set_gtk_property!(last_saved, :label,
            ok ? "Copied to clipboard  +  saved → " * path :
                 "Clipboard failed — saved → " * path)
    end
    @gs_guarded Gtk4.signal_connect(btn_save, "clicked") do _
        txt = _sample_and_show()
        _save_to_file(txt)
    end

    _sample_and_show()
    Gtk4.show(win)
    return win
end

# ---------- Plot-window settings ----------
# Shared across all tabs of an RTKPLOT-style window. Each open Plot window
# owns its own instance, mutated live by the toolbar widgets and read at
# draw time by every panel.
Base.@kwdef mutable struct PlotSettings
    # Show only the last `timespan_sec` of data on every time-series plot.
    # 0.0 = no filter (show the whole rolling buffer).
    # The "All" option was removed from both toolbars — an unbounded span
    # made the time-series unreadable after a long session. 5 min default.
    timespan_sec::Float64 = 300.0
    # Quantity displayed on the N/E/U time-series tab. :pos uses the raw
    # displacement history, :vel takes its first finite difference, :acc the
    # second. Units in `y_unit` are interpreted as length (mm/cm/m) so the
    # actual axis is mm·s⁻¹ etc. for velocity / acceleration.
    quantity::Symbol      = :pos
    # Statistic shown on the Residual tab (and web panel): :engine = the engine's own
    # figure (PPPHVA σ̂ or GaiaVario weighted RMS), :rms_w / :rms_u = weighted /
    # unweighted post-fit RMS of the satellites kept, :sigma_va = the windowed
    # smoothed sigma of the weighted RMS (see _sigma_va_update! in bridge.jl).
    resid_method::Symbol  = :engine
    # Display length unit (mm, cm, or m). Combines with `quantity` to label
    # axes; e.g. quantity=:vel + y_unit=:mm → mm/s.
    y_unit::Symbol        = :mm
    # Manual Y-axis bounds. When `auto_y` is true the bounds are computed
    # per panel from the data (default); when false, the panel uses
    # (y_min, y_max) as supplied below.
    # Manual by default: a fixed ±10 mm frame keeps the trace steady
    # instead of the axis rescaling on every outlier.
    auto_y::Bool          = false
    y_min::Float64        = -10.0
    y_max::Float64        =  10.0
    # Grid + statistics overlay toggles.
    show_grid::Bool       = true
    show_stats::Bool      = true
    # Pause/freeze: when true, the redraw timer skips all canvases so the
    # user can inspect the last frame undisturbed.
    paused::Bool          = false
    # Reference-position offset in metres. Subtracted from every displacement
    # sample so the user can recentre the scatter / time series on an
    # arbitrary baseline (RTKPLOT's "ref pos" feature).
    ref_dN_m::Float64     = 0.0
    ref_dE_m::Float64     = 0.0
    ref_dU_m::Float64     = 0.0
    # ----- High-rate drift-mitigation options -------------------------
    # High-pass filter: subtract a centred rolling mean over `hp_window_s`
    # seconds from every NEU sample before display, removing the slow
    # variometric integration drift. 0 = off.
    # On by default (60 s) — variometric displacement drifts as sqrt(N)
    # and the high-pass is what makes a live trace usable.
    hp_window_s::Float64  = 60.0
    # Kalman filter: 2-state per-axis (signal + slow_bias). The output is
    # the signal estimate, with the slowly-drifting bias subtracted. The
    # `kf_tau_s` parameter is the bias time-constant in seconds — large
    # value (e.g. 60) tracks bias slowly and lets transient signals
    # through; small value (e.g. 5) aggressively suppresses any drift but
    # may also flatten genuine displacement steps. 0 = off.
    # On by default (30 s bias time-constant), pairing with the HP filter.
    kf_tau_s::Float64     = 30.0
    # Display-side decimation: show every Nth sample only (≥ 1). 1 = all.
    # Useful for very long buffers at 10 Hz where the plot becomes a smear.
    decimate::Int         = 1
    # When true, apply a Lanczos-windowed-sinc low-pass filter with cutoff
    # at the new Nyquist (orig_rate/(2N)) BEFORE the stride sample, so
    # high-frequency content can't alias into the displayed band. When
    # false (default), uses the cheap stride sample.
    decimate_antialias::Bool = false
    # Auto-flush: when > 0, the plot window calls `flush_session_data!`
    # every N minutes, resetting all rolling buffers + mseed files. Keeps
    # drift bounded for long high-rate sessions during quiet periods.
    auto_flush_min::Float64 = 0.0
    # Web view: seconds between re-renders of the panels served to browsers
    # (the page polls at the same cadence). Rendering runs on its own thread.
    web_refresh_s::Float64 = 1.0
    # Which cause the Causes panel shows (see causes.jl); persisted.
    cause_view::Symbol = :missing
    # Tick beside the Cause dropdown: also publish the dropdown and the
    # Causes panel on the web page. On by default; persisted.
    show_causes::Bool = true
end

# Display unit label for the current (quantity, y_unit) pair.
function _quantity_unit_label(settings::PlotSettings)
    base = _y_label(settings.y_unit)
    settings.quantity === :vel ? "$(base)/s"  :
    settings.quantity === :acc ? "$(base)/s²" :
                                 base
end

# Sample times in the plot histories are GPS seconds of day (the epoch
# stamp), which run GPS_UTC_LEAP_S ahead of UTC. Axis labels are printed in
# UTC so they can be compared with the wall clock; the footer says so.
_gps_sod_to_utc_hms(sod::Float64) = _sod_to_hms(sod - GPS_UTC_LEAP_S)

# Convert a seconds-of-day value to a "HH:MM:SS" label. Wraps modulo 86400
# so a buffer that straddles midnight still prints sensibly.
function _sod_to_hms(sod::Float64)
    s = mod(sod, 86400.0)
    h = floor(Int, s / 3600); s -= 3600*h
    m = floor(Int, s / 60);   s -= 60*m
    sec = floor(Int, s)
    return @sprintf("%02d:%02d:%02d", h, m, sec)
end

# Pick a "nice" tick interval in seconds for a time axis of `span` seconds
# so we get ~5-8 labelled ticks. Returns the chosen interval in seconds.
function _nice_time_step(span::Float64)
    candidates = (1.0, 2.0, 5.0, 10.0, 15.0, 20.0, 30.0,
                  60.0, 120.0, 300.0, 600.0, 900.0, 1800.0,
                  3600.0, 7200.0, 10800.0, 21600.0, 43200.0)
    target = span / 6
    best = candidates[end]
    for c in candidates
        if c >= target
            best = c; break
        end
    end
    return best
end

# Compute a finite-difference series for velocity (order=1) or acceleration
# (order=2). `vals` are positions in metres aligned with `times` (seconds).
# Returns NaN where the previous sample is missing (gap or outlier).
function _finite_diff(times::AbstractVector{Float64}, vals::AbstractVector{Float64};
                      order::Int = 1)
    n = length(vals)
    out = fill(NaN, n)
    n < order + 1 && return out
    if order == 1
        @inbounds for i in 2:n
            v0 = vals[i-1]; v1 = vals[i]
            (isnan(v0) || isnan(v1)) && continue
            dt = times[i] - times[i-1]
            dt > 0 || continue
            out[i] = (v1 - v0) / dt
        end
    else   # order == 2 (acceleration via centred 2nd difference)
        @inbounds for i in 3:n
            v0 = vals[i-2]; v1 = vals[i-1]; v2 = vals[i]
            (isnan(v0) || isnan(v1) || isnan(v2)) && continue
            dt = (times[i] - times[i-2]) / 2
            dt > 0 || continue
            out[i] = (v2 - 2*v1 + v0) / (dt * dt)
        end
    end
    return out
end

# Y-unit scale factor (multiply NEU metres by this to get the display value).
function _y_scale(s::Symbol)
    s === :mm ? 1000.0 :
    s === :cm ? 100.0  :
                1.0
end
_y_label(s::Symbol) = s === :mm ? "mm" : s === :cm ? "cm" : "m"

# Subtract a centred rolling mean from `vals` over a window of `win`
# samples. Returns a fresh vector. NaN samples are treated as "no data"
# and skipped in the mean. Used as a high-pass filter to remove slow
# variometric drift at high sample rates.
# Median without pulling in Statistics (GaiaSeis does not depend on it).
function _median_of(v::Vector{Float64})
    isempty(v) && return 0.0
    w = sort(v)
    m = length(w)
    isodd(m) ? w[(m+1) ÷ 2] : 0.5 * (w[m ÷ 2] + w[m ÷ 2 + 1])
end

function _high_pass_inplace(times::AbstractVector{Float64}, vals::AbstractVector{Float64},
                             window_s::Float64)
    out = copy(vals)
    n = length(vals)
    (window_s <= 0 || n < 4) && return out
    # Sample rate from the buffer's mean dt — robust to gaps.
    dt = (times[end] - times[1]) / max(n - 1, 1)
    dt > 0 || return out
    win = max(3, round(Int, window_s / dt))
    half = win ÷ 2
    # Prefix sums over the non-NaN samples, so each window mean is O(1)
    # instead of re-summing `win` samples per point. At 10 Hz over 10 min
    # that is 6000 operations rather than 6000x601. Result is identical.
    # A rolling MEAN is not robust: one bad epoch contaminates every sample
    # in its window. A single 40 m spike (which the variometric solver does
    # emit, e.g. before the bridge's MAD guard has any history) smears
    # 40/61 = 0.65 m across a whole minute of samples, throwing the trace 65x
    # off a +/-10 mm axis. So exclude gross outliers from the AVERAGE while
    # still plotting them: the spike stays a spike, its neighbours stay clean.
    finite = Float64[v for v in vals if !isnan(v)]
    med = isempty(finite) ? 0.0 : _median_of(finite)
    mad = isempty(finite) ? 0.0 : _median_of(Float64[abs(v - med) for v in finite])
    # 1.4826 * MAD ~ sigma for a normal distribution; 8 sigma is loose enough
    # to keep real signal (an earthquake) in the mean, tight enough to drop
    # a metre-scale solver failure.
    cut = mad > 0 ? 8 * 1.4826 * mad : Inf
    csum = Vector{Float64}(undef, n + 1)
    ccnt = Vector{Int}(undef, n + 1)
    csum[1] = 0.0; ccnt[1] = 0
    @inbounds for i in 1:n
        v = vals[i]
        ok = !isnan(v) && abs(v - med) <= cut
        csum[i+1] = csum[i] + (ok ? v : 0.0)
        ccnt[i+1] = ccnt[i] + (ok ? 1 : 0)
    end
    @inbounds for i in 1:n
        isnan(vals[i]) && continue
        lo = max(1, i - half); hi = min(n, i + half)
        c = ccnt[hi+1] - ccnt[lo]
        c > 0 || continue
        out[i] = vals[i] - (csum[hi+1] - csum[lo]) / c
    end
    return out
end

# ---- Level of detail ----
# A 10-minute span at 10 Hz is 6000 samples drawn into an ~800 px panel:
# roughly seven points per pixel, six of which cannot be seen. Reduce to the
# per-pixel-column min and max, which leaves the drawn envelope pixel-identical
# to the full series while cutting Cairo operations by an order of magnitude.
#
# Returns indices into `vals`, in time order. Purely a drawing optimisation —
# it runs after the HP/Kalman filters, so no filter sees reduced data.
function _lod_indices(times::AbstractVector{Float64}, vals::AbstractVector{Float64},
                      t0::Float64, tspan::Float64, panel_w::Float64)
    n = length(vals)
    ncols = max(1, floor(Int, panel_w))
    (n <= 2 * ncols || tspan <= 0) && return 1:n
    idx = Int[]
    sizehint!(idx, 2 * ncols + 2)
    @inline colof(t) = min(ncols, max(1, floor(Int, (t - t0) / tspan * ncols) + 1))
    i = 1
    @inbounds while i <= n
        c = colof(times[i])
        first_i = i
        imin = 0; imax = 0
        vmin = Inf; vmax = -Inf
        while i <= n && colof(times[i]) == c
            v = vals[i]
            if !isnan(v)
                if v < vmin; vmin = v; imin = i; end
                if v > vmax; vmax = v; imax = i; end
            end
            i += 1
        end
        if imin == 0
            push!(idx, first_i)          # all-NaN column — keep one so the
                                         # line still breaks at the gap
        else
            a = min(imin, imax); b = max(imin, imax)
            push!(idx, a)
            b != a && push!(idx, b)
        end
    end
    return idx
end

# Decimate a history vector — keep every Nth tuple.
function _decimate(hist, n::Int)
    n <= 1 && return hist
    return [hist[i] for i in 1:n:length(hist)]
end

# Anti-alias then decimate: convolve each axis with a Lanczos-windowed
# sinc low-pass at cutoff f_c = 1/(2N) cycles/sample (the new Nyquist
# after striding), then stride-sample at N. Linear-phase FIR — no phase
# distortion. `zero_crossings` controls the filter length (per side); 3
# is a good sweet spot (kernel half-length L = N × 3).
#
# NaN samples are handled cleanly: contributions are dropped from the
# weighted sum and the local kernel-mass is re-normalised, so a few bad
# epochs don't bias the smoothed value.
function _aa_decimate(hist, N::Int; zero_crossings::Int = 3)
    N <= 1 && return hist
    n = length(hist)
    n < 2*N && return _decimate(hist, N)   # too short — fall back to stride

    L  = N * zero_crossings
    fc = 0.5 / N                            # normalised cutoff (cycles/sample)
    # h(k) = 2 f_c · sinc(2 f_c k) · sinc(k/L)   (Julia's sinc is normalised)
    kernel = Float64[2*fc * sinc(2*fc*k) * sinc(k/L) for k in -L:L]
    s = sum(kernel); s > 0 && (kernel ./= s)

    kL = length(kernel)
    function apply_aa(vals::Vector{Float64})
        out = Float64[]
        sizehint!(out, cld(n, N))
        for center in 1:N:n
            num = 0.0; den = 0.0
            for ki in 1:kL
                j = center + (ki - L - 1)
                (j < 1 || j > n) && continue
                v = vals[j]
                isnan(v) && continue
                num += kernel[ki] * v
                den += kernel[ki]
            end
            push!(out, den > 0 ? num/den : NaN)
        end
        return out
    end

    times = Float64[t[1] for t in hist]
    vN = Float64[t[2] for t in hist]
    vE = Float64[t[3] for t in hist]
    vU = Float64[t[4] for t in hist]
    out_t = Float64[times[i] for i in 1:N:n]
    out_N = apply_aa(vN); out_E = apply_aa(vE); out_U = apply_aa(vU)
    m = min(length(out_t), length(out_N), length(out_E), length(out_U))
    return [(out_t[i], out_N[i], out_E[i], out_U[i]) for i in 1:m]
end

# Single-state Kalman that tracks a slow bias and subtracts it from the
# measurement. State = bias only; measurement model `z = bias + signal +
# noise` lumps signal+noise into the "innovation" so the bias only absorbs
# components slower than τ seconds. The reported value is `z - bias` — a
# causal high-pass with cutoff ≈ 1 / (2π τ). Mathematically equivalent
# to a 1st-order IIR EWMA HP, but written in the canonical Kalman form so
# the implementation extends cleanly if you later want a 2-state version
# with a real signal model.
function _kalman_remove_bias(times::AbstractVector{Float64},
                              vals::AbstractVector{Float64}, tau_s::Float64)
    out = copy(vals)
    n = length(vals)
    (tau_s <= 0 || n < 4) && return out

    bias = NaN          # state: estimate of the slow bias
    P    = 1.0          # state covariance (large initially so first sample dominates)
    R    = 0.003^2      # measurement-noise variance (~3 mm carrier)
    Q    = R / (tau_s * tau_s)   # bias random-walk variance per second
    # Innovation gate. Without one, a single metre-scale bad epoch is absorbed
    # into the bias, which then takes ~tau to decay — so one outlier corrupts
    # every sample after it, far worse than the raw spike. Gate on a robust
    # scale of the series: track through normal data, ignore the impossible.
    finite = Float64[v for v in vals if !isnan(v)]
    gmed = isempty(finite) ? 0.0 : _median_of(finite)
    gmad = isempty(finite) ? 0.0 : _median_of(Float64[abs(v - gmed) for v in finite])
    gate = gmad > 0 ? 8 * 1.4826 * gmad : Inf
    @inbounds for i in 1:n
        z = vals[i]
        isnan(z) && continue
        if isnan(bias)
            bias = z
            out[i] = 0.0
            continue
        end
        dt = i == 1 ? 0.0 : times[i] - times[i-1]
        P += Q * max(dt, 0.0)        # predict
        if abs(z - gmed) <= gate
            K = P / (P + R)          # gain
            bias += K * (z - bias)   # update
            P    *= (1 - K)
        end                          # else: reject the update, keep the state
        out[i] = z - bias            # subtract tracked bias → drift-free output
    end
    return out
end

# Slice the rolling history to whatever the current timespan filter permits.
function _filter_timespan(hist, settings::PlotSettings)
    settings.timespan_sec <= 0 && return hist
    isempty(hist) && return hist
    t_last = hist[end][1]
    t_cut  = t_last - settings.timespan_sec
    i0 = 1
    @inbounds for i in 1:length(hist)
        if hist[i][1] >= t_cut
            i0 = i; break
        end
    end
    return @view hist[i0:end]
end

# Compute mean / std / RMS / peak-to-peak / max|x| for the statistics
# overlay. Returns NaNs when the input is empty or all-NaN.
function _series_stats(values)
    n_valid = 0; s = 0.0; ss = 0.0; vmin = Inf; vmax = -Inf
    for v in values
        isnan(v) && continue
        n_valid += 1
        s  += v; ss += v*v
        vmin = min(vmin, v); vmax = max(vmax, v)
    end
    n_valid == 0 && return (NaN, NaN, NaN, NaN)
    μ  = s / n_valid
    σ2 = max(ss/n_valid - μ*μ, 0.0)
    σ  = sqrt(σ2)
    rms = sqrt(ss / n_valid)
    return (μ, σ, rms, vmax - vmin)
end

# ---------- Large RTKPLOT-style window ----------
# Modeless dialog with five tabs: stacked N/E/U time series, E vs N
# ground-track scatter, polar skyplot, post-fit σ̂ history, and #sats / DOP
# history. A toolbar at the top houses every shared display option. All
# canvases redraw at 2 Hz, sharing the same buffers populated by the bridge.
# Render a setting value for an entry box: 60.0 -> "60", 0.5 -> "0.5".
_num_text(x::Real) = isinteger(x) ? string(Int(round(x))) : string(x)

# Red small-print overload note next to the wordmark; empty when all is well.
function _set_overload_label!(Gtk4, lbl, sess)
    _DEGRADE_SESS[] = sess          # lets the health sampler raise alarm cases for this session
    msg = _banner_text(sess)
    esc = replace(replace(replace(msg, "&" => "&amp;"), "<" => "&lt;"), ">" => "&gt;")
    Gtk4.set_gtk_property!(lbl, :label,
        isempty(msg) ? "" : "<span foreground='#c40000' size='small' weight='bold'>" * esc * "</span>")
    return
end

function _open_plot_window(state, Gtk4)
    win = Gtk4.GtkWindow("GaiaSeis — Plot (RTKPLOT-style)", 960, 720)
    Gtk4.set_gtk_property!(win, :modal, false)
    _apply_window_icon!(Gtk4, win)

    settings = _load_plot_settings!(PlotSettings())
    active_profile = get(state[:profiles], get(state, :active, ""), nothing)
    last_settings_sig = Ref(_settings_to_json(settings) * "|" * string(settings.auto_flush_min))
    last_profile_sig  = Ref(active_profile === nothing ? "" :
        string(active_profile.outlier_mad_threshold, "|", active_profile.outlier_window))

    outer = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(outer, :spacing, 4)
    push!(win, outer)

    # ---------- Logo strip above the toolbar ----------
    # Compact header strip (same minimalist layout as the main window):
    # small GaiaSeis icon + project name + version, no trailing void.
    plot_logo_strip = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(plot_logo_strip, :spacing, 6)
    Gtk4.set_gtk_property!(plot_logo_strip, :margin_top, 4)
    Gtk4.set_gtk_property!(plot_logo_strip, :margin_bottom, 0)
    Gtk4.set_gtk_property!(plot_logo_strip, :margin_start, 10)
    Gtk4.set_gtk_property!(plot_logo_strip, :margin_end, 10)
    Gtk4.set_gtk_property!(plot_logo_strip, :halign, 1)   # START
    push!(outer, plot_logo_strip)
    let lg = _make_logo(Gtk4, "GaiaSeis_icon"; height = 40)
        lg === nothing || push!(plot_logo_strip, lg)
    end
    push!(plot_logo_strip, _make_compact_wordmark(Gtk4))
    lbl_overload_plot = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_overload_plot, :use_markup, true)
    Gtk4.set_gtk_property!(lbl_overload_plot, :margin_start, 14)
    Gtk4.set_gtk_property!(lbl_overload_plot, :valign, 3)
    push!(plot_logo_strip, lbl_overload_plot)

    # ---------- Toolbar (two rows, stacked vertically) ----------
    # Row 1 = display options (span / qty / units / y-axis / grid / stats /
    #         pause). Row 2 = filters and right-aligned action buttons
    #         (HP / Kalman / decimate / auto-flush / outlier / ref-pos /
    #         snapshot / web). Splitting the controls in two lines lets
    #         the window be narrower while staying fully usable.
    tb_outer = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(tb_outer, :spacing, 4)
    Gtk4.set_gtk_property!(tb_outer, :margin_top, 6)
    Gtk4.set_gtk_property!(tb_outer, :margin_bottom, 4)
    Gtk4.set_gtk_property!(tb_outer, :margin_start, 8)
    Gtk4.set_gtk_property!(tb_outer, :margin_end, 8)
    push!(outer, tb_outer)

    tb = Gtk4.GtkBox(:h)         # row 1 — display options
    Gtk4.set_gtk_property!(tb, :spacing, 6)
    push!(tb_outer, tb)

    tb2 = Gtk4.GtkBox(:h)        # row 2 — drift-mitigation + outlier guard
    Gtk4.set_gtk_property!(tb2, :spacing, 6)
    push!(tb_outer, tb2)

    tb3 = Gtk4.GtkBox(:h)        # row 3 — action buttons + web-serve
    Gtk4.set_gtk_property!(tb3, :spacing, 6)
    push!(tb_outer, tb3)

    # (Logos moved to a dedicated strip above the toolbar — see
    # `plot_logo_strip` above; keeping them inside the toolbar would
    # inflate the row height the same way the header bar did.)

    push!(tb, Gtk4.GtkLabel("Span:"))
    cmb_span = Gtk4.GtkComboBoxText()
    push!(cmb_span, "Last 1 min")
    push!(cmb_span, "Last 5 min")
    push!(cmb_span, "Last 10 min")
    push!(cmb_span, "Last 30 min")
    let sp = settings.timespan_sec
        Gtk4.set_gtk_property!(cmb_span, :active,
            sp <= 60.0 ? 0 : sp <= 300.0 ? 1 : sp <= 600.0 ? 2 : 3)
    end
    push!(tb, cmb_span)

    push!(tb, Gtk4.GtkLabel("  Qty:"))
    cmb_qty = Gtk4.GtkComboBoxText()
    push!(cmb_qty, "Displacement/epoch")
    push!(cmb_qty, "Velocity")
    push!(cmb_qty, "Acceleration")
    # start from the saved setting (plot_settings.toml), not always "Displacement":
    # the drop-down, the tab name and the drawn quantity must agree
    Gtk4.set_gtk_property!(cmb_qty, :active, settings.quantity === :vel ? 1 : settings.quantity === :acc ? 2 : 0)
    push!(tb, cmb_qty)

    push!(tb, Gtk4.GtkLabel("  Units:"))
    cmb_unit = Gtk4.GtkComboBoxText()
    push!(cmb_unit, "mm")
    push!(cmb_unit, "cm")
    push!(cmb_unit, "m")
    Gtk4.set_gtk_property!(cmb_unit, :active, settings.y_unit === :cm ? 1 : settings.y_unit === :m ? 2 : 0)   # from the saved setting
    push!(tb, cmb_unit)
    push!(tb, Gtk4.GtkLabel(" Cause:"))
    cmb_cause = Gtk4.GtkComboBoxText()
    for k in _CAUSE_KINDS; push!(cmb_cause, _CAUSE_INFO[k].label); end
    Gtk4.set_gtk_property!(cmb_cause, :active, max(findfirst(==(settings.cause_view), _CAUSE_KINDS) - 1, 0))
    Gtk4.set_gtk_property!(cmb_cause, :tooltip_text, "Cause shown on the Causes tab: description, the cases of this session and a 24 h UTC timeline.")
    push!(tb, cmb_cause)
    chk_causes_web = Gtk4.GtkCheckButton("Web")
    Gtk4.set_gtk_property!(chk_causes_web, :active, settings.show_causes)
    Gtk4.set_gtk_property!(chk_causes_web, :tooltip_text,
        "Ticked: the Cause dropdown and the Causes panel are shown on the web page too, with the same " *
        "description, cases and 24 h timeline. Unticked: the page hides them. On by default; saved with the settings.")
    push!(tb, chk_causes_web)

    # Every control below is seeded FROM `settings`, never from a literal —
    # otherwise a change to a PlotSettings default silently leaves the widget
    # disagreeing with the value actually in force.
    chk_auto = Gtk4.GtkCheckButton("Auto Y")
    Gtk4.set_gtk_property!(chk_auto, :active, settings.auto_y)
    push!(tb, chk_auto)
    e_ymin = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_ymin, :placeholder_text, "y-min")
    Gtk4.set_gtk_property!(e_ymin, :text, _num_text(settings.y_min))
    Gtk4.set_gtk_property!(e_ymin, :width_chars, 6)
    Gtk4.set_gtk_property!(e_ymin, :sensitive, !settings.auto_y)
    push!(tb, e_ymin)
    e_ymax = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_ymax, :placeholder_text, "y-max")
    Gtk4.set_gtk_property!(e_ymax, :text, _num_text(settings.y_max))
    Gtk4.set_gtk_property!(e_ymax, :width_chars, 6)
    Gtk4.set_gtk_property!(e_ymax, :sensitive, !settings.auto_y)
    push!(tb, e_ymax)

    chk_grid  = Gtk4.GtkCheckButton("Grid")
    Gtk4.set_gtk_property!(chk_grid, :active, settings.show_grid)
    push!(tb, chk_grid)
    chk_stats = Gtk4.GtkCheckButton("Stats overlay")
    Gtk4.set_gtk_property!(chk_stats, :active, settings.show_stats)
    push!(tb, chk_stats)
    chk_pause = Gtk4.GtkCheckButton("Pause")
    push!(tb, chk_pause)

    # ---- Drift-mitigation (high-rate) — packed into row 2 ----
    # Each option pairs a checkbox (online enable / disable) with a value
    # entry. Changes take effect immediately on the next redraw — no
    # session restart required. Outlier-window edits go straight into the
    # live `session.profile.outlier_window`, so the bridge picks them up
    # on the next epoch.
    chk_hp = Gtk4.GtkCheckButton("HP (s):")
    Gtk4.set_gtk_property!(chk_hp, :active, settings.hp_window_s > 0)
    push!(tb2, chk_hp)
    e_hp_s = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_hp_s, :text,
        _num_text(settings.hp_window_s > 0 ? settings.hp_window_s : 60.0))
    Gtk4.set_gtk_property!(e_hp_s, :width_chars, 4)
    Gtk4.set_gtk_property!(e_hp_s, :sensitive, settings.hp_window_s > 0)
    push!(tb2, e_hp_s)

    chk_kf = Gtk4.GtkCheckButton("Kalman (τ):")
    Gtk4.set_gtk_property!(chk_kf, :tooltip_text,
        "2-state per-axis Kalman that estimates a slow bias and " *
        "subtracts it. τ ≈ bias time-constant — smaller = more aggressive " *
        "drift removal but may flatten genuine displacement steps.")
    Gtk4.set_gtk_property!(chk_kf, :active, settings.kf_tau_s > 0)
    push!(tb2, chk_kf)
    e_kf_tau = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_kf_tau, :text,
        _num_text(settings.kf_tau_s > 0 ? settings.kf_tau_s : 30.0))
    Gtk4.set_gtk_property!(e_kf_tau, :width_chars, 4)
    Gtk4.set_gtk_property!(e_kf_tau, :sensitive, settings.kf_tau_s > 0)
    push!(tb2, e_kf_tau)

    chk_dec = Gtk4.GtkCheckButton("Dec 1/N:")
    Gtk4.set_gtk_property!(chk_dec, :active, settings.decimate > 1)
    push!(tb2, chk_dec)
    e_dec_n = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_dec_n, :text, string(settings.decimate > 1 ? settings.decimate : 10))
    Gtk4.set_gtk_property!(e_dec_n, :width_chars, 3)
    Gtk4.set_gtk_property!(e_dec_n, :sensitive, settings.decimate > 1)
    push!(tb2, e_dec_n)
    chk_dec_aa = Gtk4.GtkCheckButton("AA")
    Gtk4.set_gtk_property!(chk_dec_aa, :active, settings.decimate_antialias)
    Gtk4.set_gtk_property!(chk_dec_aa, :sensitive, settings.decimate > 1)
    Gtk4.set_gtk_property!(chk_dec_aa, :tooltip_text,
        "Anti-alias before stride sample. Convolves each axis with a " *
        "Lanczos-windowed sinc low-pass at cutoff = orig_rate/(2N) so " *
        "high-frequency content can't alias into the displayed band.")
    push!(tb2, chk_dec_aa)

    chk_autofl = Gtk4.GtkCheckButton("Flush (min):")
    Gtk4.set_gtk_property!(chk_autofl, :active, settings.auto_flush_min > 0)
    push!(tb2, chk_autofl)
    e_autofl   = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_autofl, :text,
        _num_text(settings.auto_flush_min > 0 ? settings.auto_flush_min : 30.0))
    Gtk4.set_gtk_property!(e_autofl, :width_chars, 3)
    Gtk4.set_gtk_property!(e_autofl, :sensitive, settings.auto_flush_min > 0)
    push!(tb2, e_autofl)

    # ---- Outlier guard (on / off, tunable threshold + window) ----
    # Active by default (matches profile default). Toggling the
    # checkbox off sets `profile.outlier_mad_threshold = 0`, which the
    # bridge interprets as "skip the guard". Toggling back on restores
    # the value typed in the MAD-threshold entry next to it.
    chk_outlier = Gtk4.GtkCheckButton("Outlier")
    Gtk4.set_gtk_property!(chk_outlier, :active,
        active_profile === nothing || active_profile.outlier_mad_threshold > 0)
    Gtk4.set_gtk_property!(chk_outlier, :tooltip_text,
        "Enable / disable the bridge's rolling-MAD amplitude FLAG. " *
        "When on, epochs whose dXYZ deviates by more than `MAD` × " *
        "median-absolute-deviation of the last `OutWin` samples are " *
        "counted and reported in the Causes tab, but KEPT (a genuine " *
        "strong-motion pulse looks the same). Epochs are blanked only " *
        "by the quality gate (profile fields max_velocity_mps, " *
        "min_sats_used, min_constellations, max_pdop, max_fit_rms_m).")
    push!(tb2, chk_outlier)

    push!(tb2, Gtk4.GtkLabel("MAD:"))
    e_outmad = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_outmad, :text,
        _num_text(active_profile === nothing || active_profile.outlier_mad_threshold <= 0 ?
                  6.0 : active_profile.outlier_mad_threshold))
    Gtk4.set_gtk_property!(e_outmad, :width_chars, 4)
    Gtk4.set_gtk_property!(e_outmad, :tooltip_text,
        "MAD multiplier (typical 4–10). Smaller = stricter (more " *
        "epochs rejected); larger = looser. Default 6.0.")
    push!(tb2, e_outmad)

    push!(tb2, Gtk4.GtkLabel("  OutWin:"))
    e_outwin = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_outwin, :text,
        string(active_profile === nothing ? 20 : active_profile.outlier_window))
    Gtk4.set_gtk_property!(e_outwin, :width_chars, 4)
    Gtk4.set_gtk_property!(e_outwin, :tooltip_text,
        "Rolling-MAD window length in samples. Set to roughly the " *
        "sample rate × 20 s (≈ 20 for 1 Hz, ≈ 200 for 10 Hz) so the " *
        "guard's baseline covers a stable ~20 s of recent history.")
    push!(tb2, e_outwin)

    # ---- Live outlier counter + RMS magnitude ------------------------
    # Reads `session.bridge_state.outlier_total` and `outlier_dev_sq_sum`
    # on every redraw tick. The displayed σ is the RMS of the rejected
    # dXYZ vectors' Euclidean distance from the rolling median, in mm —
    # i.e. "how big are the outliers, on average". Both reset to 0 on
    # the next Flush.
    lbl_outlier_stats = Gtk4.GtkLabel("  Outliers: 0 (σ = —)")
    Gtk4.set_gtk_property!(lbl_outlier_stats, :tooltip_text,
        "Cumulative outlier count since the last flush, plus the " *
        "root-mean-square magnitude (mm) of their deviation from the " *
        "rolling median. These epochs are flagged, not blanked. A high count " *
        "with a small σ means the threshold is near the noise; a small " *
        "count with a large σ means genuine spikes or real motion.")
    push!(tb2, lbl_outlier_stats)
    # ---- Missing input epochs (receiver/caster side) -----------------
    lbl_missing_stats = Gtk4.GtkLabel("  Missing: —")
    Gtk4.set_gtk_property!(lbl_missing_stats, :tooltip_text,
        "Epochs that never arrived from the receiver/caster (holes in the " *
        "epoch time sequence of the primary constellation, counted before " *
        "processing). Session total and the last 60 s. Every hole is also " *
        "marked as a red tick under the position panels.")
    push!(tb2, lbl_missing_stats)

    # Trailing hexpand-spacer so the row's controls stay left-aligned
    # rather than spreading across the full toolbar width.
    let sp = Gtk4.GtkLabel(""); Gtk4.set_gtk_property!(sp, :hexpand, true); push!(tb2, sp); end

    # ---- Row 3: action buttons (left) + web-serve toggle (right) ----
    btn_refpos  = Gtk4.GtkButton("Ref pos…")
    btn_refzero = Gtk4.GtkButton("Use as ref")
    btn_snap    = Gtk4.GtkButton("Snapshot PNG…")
    push!(tb3, btn_refpos)
    push!(tb3, btn_refzero)
    push!(tb3, btn_snap)

    # Spacer so the web-serve group hugs the right edge.
    let sp = Gtk4.GtkLabel(""); Gtk4.set_gtk_property!(sp, :hexpand, true); push!(tb3, sp); end

    # Tiny HTTP server that re-renders the five panels into PNGs on every
    # request and an index page that auto-refreshes them every second, so
    # any browser on the LAN can monitor the same plots remotely.
    push!(tb3, Gtk4.GtkLabel("Web:"))
    e_web_port = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_web_port, :text, "8765")
    Gtk4.set_gtk_property!(e_web_port, :width_chars, 5)
    push!(tb3, e_web_port)
    btn_web = Gtk4.GtkButton("Start")
    push!(tb3, btn_web)
    push!(tb3, Gtk4.GtkLabel(" Refresh (s):"))
    e_web_refresh = Gtk4.GtkEntry()
    Gtk4.set_gtk_property!(e_web_refresh, :text, _num_text(settings.web_refresh_s))
    Gtk4.set_gtk_property!(e_web_refresh, :width_chars, 4)
    Gtk4.set_gtk_property!(e_web_refresh, :tooltip_text,
        "Seconds between re-renders of the web page's panels (0.2–60). Rendering " *
        "runs on its own thread from a snapshot of the data; every viewer is served " *
        "the same image, and the page polls at this cadence. Saved with the other settings.")
    push!(tb3, e_web_refresh)
    lbl_web_status = Gtk4.GtkLabel("")
    push!(tb3, lbl_web_status)

    # Toolbar wiring — every change just mutates `settings`; the next
    # redraw tick picks it up. Pause is honoured by the timer callback.
    @gs_guarded Gtk4.signal_connect(cmb_span, "changed") do _
        idx = Gtk4.get_gtk_property(cmb_span, :active, Int)
        settings.timespan_sec = idx == 0 ?   60.0 :
                                idx == 1 ?  300.0 :
                                idx == 2 ?  600.0 : 1800.0
    end
    @gs_guarded Gtk4.signal_connect(cmb_unit, "changed") do _
        idx = Gtk4.get_gtk_property(cmb_unit, :active, Int)
        settings.y_unit = idx == 0 ? :mm : idx == 1 ? :cm : :m
    end
    @gs_guarded Gtk4.signal_connect(chk_causes_web, "toggled") do _
        settings.show_causes = Gtk4.get_gtk_property(chk_causes_web, :active, Bool)
    end
    @gs_guarded Gtk4.signal_connect(cmb_cause, "changed") do _
        i = Gtk4.get_gtk_property(cmb_cause, :active, Int)
        0 <= i < length(_CAUSE_KINDS) && (settings.cause_view = _CAUSE_KINDS[i + 1])
    end
    @gs_guarded Gtk4.signal_connect(cmb_qty, "changed") do _
        idx = Gtk4.get_gtk_property(cmb_qty, :active, Int)
        settings.quantity = idx == 0 ? :pos : idx == 1 ? :vel : :acc
    end
    @gs_guarded Gtk4.signal_connect(chk_auto, "toggled") do _
        on = Gtk4.get_gtk_property(chk_auto, :active, Bool)
        settings.auto_y = on
        # Grey out / re-enable the min/max entries to match the mode.
        Gtk4.set_gtk_property!(e_ymin, :sensitive, !on)
        Gtk4.set_gtk_property!(e_ymax, :sensitive, !on)
    end
    @gs_guarded Gtk4.signal_connect(e_ymin, "changed") do _
        settings.y_min = _safe_parse(Gtk4.get_gtk_property(e_ymin, :text, String),
                                       settings.y_min)
    end
    @gs_guarded Gtk4.signal_connect(e_ymax, "changed") do _
        settings.y_max = _safe_parse(Gtk4.get_gtk_property(e_ymax, :text, String),
                                       settings.y_max)
    end
    @gs_guarded Gtk4.signal_connect(chk_grid, "toggled") do _
        settings.show_grid  = Gtk4.get_gtk_property(chk_grid, :active, Bool)
    end
    @gs_guarded Gtk4.signal_connect(chk_stats, "toggled") do _
        settings.show_stats = Gtk4.get_gtk_property(chk_stats, :active, Bool)
    end
    @gs_guarded Gtk4.signal_connect(chk_pause, "toggled") do _
        settings.paused     = Gtk4.get_gtk_property(chk_pause, :active, Bool)
    end

    # ---- Drift-mitigation wiring ----
    # HP filter
    function _sync_hp!()
        on = Gtk4.get_gtk_property(chk_hp, :active, Bool)
        Gtk4.set_gtk_property!(e_hp_s, :sensitive, on)
        val = _safe_parse(Gtk4.get_gtk_property(e_hp_s, :text, String), 60.0)
        settings.hp_window_s = on ? max(val, 0.0) : 0.0
    end
    @gs_guarded Gtk4.signal_connect(chk_hp, "toggled") do _; _sync_hp!(); end
    @gs_guarded Gtk4.signal_connect(e_hp_s,  "changed") do _; _sync_hp!(); end
    @gs_guarded Gtk4.signal_connect(e_web_refresh, "changed") do _
        v = _safe_parse(Gtk4.get_gtk_property(e_web_refresh, :text, String), 1.0)
        settings.web_refresh_s = clamp(v, 0.2, 60.0)
    end

    # Kalman
    function _sync_kf!()
        on = Gtk4.get_gtk_property(chk_kf, :active, Bool)
        Gtk4.set_gtk_property!(e_kf_tau, :sensitive, on)
        val = _safe_parse(Gtk4.get_gtk_property(e_kf_tau, :text, String), 30.0)
        settings.kf_tau_s = on ? max(val, 0.1) : 0.0
    end
    @gs_guarded Gtk4.signal_connect(chk_kf, "toggled") do _; _sync_kf!(); end
    @gs_guarded Gtk4.signal_connect(e_kf_tau, "changed") do _; _sync_kf!(); end

    # Decimation
    function _sync_dec!()
        on = Gtk4.get_gtk_property(chk_dec, :active, Bool)
        Gtk4.set_gtk_property!(e_dec_n, :sensitive, on)
        Gtk4.set_gtk_property!(chk_dec_aa, :sensitive, on)
        nstr = Gtk4.get_gtk_property(e_dec_n, :text, String)
        n = tryparse(Int, strip(nstr))
        settings.decimate = (on && n !== nothing && n >= 1) ? n : 1
        # AA only meaningful when decimation is on
        settings.decimate_antialias = on &&
            Gtk4.get_gtk_property(chk_dec_aa, :active, Bool)
    end
    @gs_guarded Gtk4.signal_connect(chk_dec, "toggled") do _; _sync_dec!(); end
    @gs_guarded Gtk4.signal_connect(e_dec_n, "changed") do _; _sync_dec!(); end
    @gs_guarded Gtk4.signal_connect(chk_dec_aa, "toggled") do _; _sync_dec!(); end

    # Auto-flush — driven by a Gtk timer whose interval changes when the
    # entry / checkbox changes. We track the source id so we can cancel
    # and recreate on every change.
    autofl_state = Dict{Symbol,Any}(:src => 0)
    function _autoflush_tick()
        sess = state[:session]
        sess !== nothing && try
            flush_session_data!(sess)
        catch err
            @warn "auto-flush failed" err
        end
        return true   # keep the timer alive
    end
    function _sync_autofl!()
        on = Gtk4.get_gtk_property(chk_autofl, :active, Bool)
        Gtk4.set_gtk_property!(e_autofl, :sensitive, on)
        val = _safe_parse(Gtk4.get_gtk_property(e_autofl, :text, String), 30.0)
        settings.auto_flush_min = on ? max(val, 0.1) : 0.0
        # Kill any existing timer
        if autofl_state[:src] != 0
            try; Gtk4.GLib.source_remove(autofl_state[:src]); catch; end
            autofl_state[:src] = 0
        end
        # Start a new timer if enabled
        if settings.auto_flush_min > 0
            ms = round(Int, settings.auto_flush_min * 60_000)
            autofl_state[:src] = Gtk4.GLib.g_timeout_add(_autoflush_tick, ms)
        end
    end
    @gs_guarded Gtk4.signal_connect(chk_autofl, "toggled") do _; _sync_autofl!(); end
    @gs_guarded Gtk4.signal_connect(e_autofl,   "changed") do _; _sync_autofl!(); end

    # Outlier window — write straight into the live profile so the bridge
    # picks the new value up on the next epoch.
    @gs_guarded Gtk4.signal_connect(e_outwin, "changed") do _
        sess = state[:session]
        sess === nothing && return
        n = tryparse(Int, strip(Gtk4.get_gtk_property(e_outwin, :text, String)))
        (n === nothing || n < 1) && return
        sess.profile.outlier_window = n
        active_profile === nothing || (active_profile.outlier_window = n)
    end

    # Outlier guard on/off + MAD threshold. Both writes land directly
    # on `session.profile`, which the bridge re-reads at the next
    # epoch (see `_outlier_guard!` in src/bridge.jl).
    function _sync_outlier!()
        sess = state[:session]
        on = Gtk4.get_gtk_property(chk_outlier, :active, Bool)
        Gtk4.set_gtk_property!(e_outmad, :sensitive, on)
        sess === nothing && return
        if on
            val = _safe_parse(Gtk4.get_gtk_property(e_outmad, :text, String), 6.0)
            sess.profile.outlier_mad_threshold = max(val, 0.01)
        else
            sess.profile.outlier_mad_threshold = 0.0
        end
        active_profile === nothing ||
            (active_profile.outlier_mad_threshold = sess.profile.outlier_mad_threshold)
    end
    @gs_guarded Gtk4.signal_connect(chk_outlier, "toggled") do _; _sync_outlier!(); end
    @gs_guarded Gtk4.signal_connect(e_outmad,    "changed") do _; _sync_outlier!(); end

    # ---------- Status line (engine, constellations, satellites, rate, running time) ----------
    lbl_plot_status = Gtk4.GtkLabel("")
    Gtk4.set_gtk_property!(lbl_plot_status, :use_markup, true)
    Gtk4.set_gtk_property!(lbl_plot_status, :xalign, 0.0)
    Gtk4.set_gtk_property!(lbl_plot_status, :margin_start, 8)
    Gtk4.set_gtk_property!(lbl_plot_status, :margin_bottom, 2)
    push!(outer, lbl_plot_status)
    function _update_plot_status!()
        sess = state[:session]
        if sess === nothing || !isrunning(sess)
            Gtk4.set_gtk_property!(lbl_plot_status, :label, "<b>not streaming</b>")
            return
        end
        st = sess.stats; bs = sess.bridge_state
        up = st.started_at == DateTime(0) ? 0.0 : Dates.value(Dates.now() - st.started_at) / 1000
        rate = (isnan(st.input_interval_s) || st.input_interval_s <= 0) ? "" : @sprintf(" · %.0f Hz", 1 / st.input_interval_s)
        cons = bs === nothing ? "" : bs.cons_used
        used = bs === nothing ? 0 : bs.sats_used
        miss = (st.input_epochs + st.input_missing) > 0 ?
               @sprintf(" · missing %d (%.2f %%)", st.input_missing, 100 * st.input_missing / (st.input_epochs + st.input_missing)) : ""
        Gtk4.set_gtk_property!(lbl_plot_status, :label,
            "<b>" * _markup_esc(engine_label(sess.profile)) * "</b> · profile " * _markup_esc(sess.profile.name) *
            " · constellations " * _markup_esc(isempty(cons) ? "—" : cons) * " · " * string(used) * " sats used" * rate *
            " · running " * _fmt_duration(up) * miss)
    end
    # ---------- Notebook with five tabs ----------
    notebook = Gtk4.GtkNotebook()
    Gtk4.set_gtk_property!(notebook, :hexpand, true)
    Gtk4.set_gtk_property!(notebook, :vexpand, true)
    push!(outer, notebook)

    function _add_canvas(label::String, drawfn)
        # Small minimum (320×220) — lets the user shrink the Plot window
        # below the previous 880×600 floor. The hexpand/vexpand flags
        # let the canvas grow into the available container space.
        cv = Gtk4.GtkCanvas(320, 220)
        Gtk4.set_gtk_property!(cv, :hexpand, true)
        Gtk4.set_gtk_property!(cv, :vexpand, true)
        push!(notebook, cv, Gtk4.GtkLabel(label))
        Gtk4.draw(cv) do widget
            try
                cr = Gtk4.getgc(widget)
                w  = Float64(Gtk4.width(widget))
                h  = Float64(Gtk4.height(widget))
                drawfn(cr, w, h, state[:session], settings)
            catch err
                @warn "plot draw failed" tab=label err
            end
        end
        return cv
    end

    cv_neu     = _add_canvas("Displacement / epoch (N/E/U)", _draw_neu_stacked)
    cv_scatter = _add_canvas("Ground track (E–N)", _draw_en_scatter)
    cv_sky     = _add_canvas("Skyplot",          _draw_skyplot)
    cv_resid   = _add_canvas("Residual σ̂",       _draw_residual)
    # ---------- Settings page: how the residual statistic is computed ----------
    set_box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(set_box, :spacing, 8)
    for prop in (:margin_top, :margin_bottom, :margin_start, :margin_end); Gtk4.set_gtk_property!(set_box, prop, 12); end
    lbl_set_head = Gtk4.GtkLabel("<b>Residual statistic</b> shown on the Residual tab and the web panel"); Gtk4.set_gtk_property!(lbl_set_head, :use_markup, true); Gtk4.set_gtk_property!(lbl_set_head, :xalign, 0.0)
    push!(set_box, lbl_set_head)
    cmb_resid = Gtk4.GtkComboBoxText()
    for (_, lab) in _RESID_CHOICES; push!(cmb_resid, lab); end
    Gtk4.set_gtk_property!(cmb_resid, :active, something(findfirst(c -> c[1] == settings.resid_method, _RESID_CHOICES), 1) - 1)
    push!(set_box, cmb_resid)
    lbl_set_expl = Gtk4.GtkLabel(_resid_explain(settings.resid_method)); Gtk4.set_gtk_property!(lbl_set_expl, :wrap, true); Gtk4.set_gtk_property!(lbl_set_expl, :xalign, 0.0)
    push!(set_box, lbl_set_expl)
    lbl_set_note = Gtk4.GtkLabel(_RESID_NOTE); Gtk4.set_gtk_property!(lbl_set_note, :wrap, true); Gtk4.set_gtk_property!(lbl_set_note, :xalign, 0.0)
    push!(set_box, lbl_set_note)
    push!(notebook, set_box, Gtk4.GtkLabel("Settings"))
    @gs_guarded Gtk4.signal_connect(cmb_resid, "changed") do _
        i = Gtk4.get_gtk_property(cmb_resid, :active, Int)
        1 <= i + 1 <= length(_RESID_CHOICES) || return
        settings.resid_method = _RESID_CHOICES[i + 1][1]
        Gtk4.set_gtk_property!(lbl_set_expl, :label, _resid_explain(settings.resid_method))
        try; _save_plot_settings(settings); catch; end
    end
    # The N/E/U page is named after the quantity shown (the plot title inside
    # the canvas already follows the Quantity drop-down; the tab did not).
    _neu_tab_title() = settings.quantity === :vel ? "Velocity (N/E/U)" :
                       settings.quantity === :acc ? "Acceleration (N/E/U)" : "Displacement / epoch (N/E/U)"
    try; Gtk4.G_.set_tab_label_text(notebook, cv_neu, _neu_tab_title()); catch; end
    @gs_guarded Gtk4.signal_connect(cmb_qty, "changed") do _
        try; Gtk4.G_.set_tab_label_text(notebook, cv_neu, _neu_tab_title()); catch err; @debug "tab label" err; end
    end
    cv_dop     = _add_canvas("#sats / DOP",      _draw_nsat_dop)
    cv_lat     = _add_canvas("Latency / delays", _draw_metrics)
    cv_health  = _add_canvas("Health",           _draw_health)
    cv_causes  = _add_canvas("Causes",           _draw_causes)
    canvases = (cv_neu, cv_scatter, cv_sky, cv_resid, cv_dop, cv_lat, cv_health, cv_causes)
    _start_sys_sampler!()

    # ---------- Ref-pos editor (modal-ish input) ----------
    @gs_guarded Gtk4.signal_connect(btn_refpos, "clicked") do _
        _open_refpos_dialog(Gtk4, win, settings)
    end
    @gs_guarded Gtk4.signal_connect(btn_refzero, "clicked") do _
        sess = state[:session]
        if sess !== nothing && !isempty(sess.stats.displacement_history)
            last = sess.stats.displacement_history[end]
            settings.ref_dN_m = last[2]
            settings.ref_dE_m = last[3]
            settings.ref_dU_m = last[4]
        end
    end
    @gs_guarded Gtk4.signal_connect(btn_snap, "clicked") do _
        _snapshot_canvas_async(Gtk4, win, canvases, notebook)
    end

    # ---- Web-server toggle ----
    # `web_state[:server]` holds the running HTTP.Server handle, or
    # `nothing` when stopped. The toggle button flips its own label.
    web_state = Dict{Symbol,Any}(:server => nothing)
    @gs_guarded Gtk4.signal_connect(btn_web, "clicked") do _
        if web_state[:server] === nothing
            port_str = Gtk4.get_gtk_property(e_web_port, :text, String)
            port = tryparse(Int, strip(port_str))
            if port === nothing || port < 1 || port > 65535
                Gtk4.set_gtk_property!(lbl_web_status, :label, "  bad port")
                return
            end
            try
                srv = _start_plot_web_server(port, state, settings)
                web_state[:server] = srv
                Gtk4.set_gtk_property!(btn_web, :label, "Stop")
                lan_ip = _primary_lan_ip()
                Gtk4.set_gtk_property!(lbl_web_status, :label,
                    lan_ip == "127.0.0.1" ?
                        "  serving → http://localhost:$port/" :
                        "  serving → http://$lan_ip:$port/   (localhost:$port also works)")
                @info "Plot web server started" port=port lan_ip=lan_ip
            catch err
                @warn "could not start plot web server" err
                Gtk4.set_gtk_property!(lbl_web_status, :label,
                    "  error: $(sprint(showerror, err))")
            end
        else
            try; close(web_state[:server]); catch err; @debug "web close failed" err; end
            web_state[:server] = nothing
            Gtk4.set_gtk_property!(btn_web, :label, "Start")
            Gtk4.set_gtk_property!(lbl_web_status, :label, "  stopped")
            @info "Plot web server stopped"
        end
    end
    # ---- Window lifecycle: track close so timers can self-cancel ----
    window_closed = Ref(false)

    @gs_guarded Gtk4.signal_connect(win, "close-request") do _
        window_closed[] = true
        # Stop the HTTP server (if running) so its task quits cleanly.
        if web_state[:server] !== nothing
            try; close(web_state[:server]); catch; end
            web_state[:server] = nothing
        end
        # Cancel the auto-flush timer source if one is active. Without
        # this, the timer keeps firing on a Plot-window-less session and
        # eventually flushes data the user didn't expect to be flushed.
        if autofl_state[:src] != 0
            try; Gtk4.GLib.source_remove(autofl_state[:src]); catch; end
            autofl_state[:src] = 0
        end
        false
    end

    # 2 Hz redraw — skips when paused so the canvas stays frozen, and
    # SELF-CANCELS when the Plot window has been closed. Without the
    # self-cancel, every Plot-window open leaks a permanent GLib timer
    # that keeps calling `Gtk4.draw` on destroyed canvases — which is
    # the slow-but-fatal source-queue buildup that froze the app
    # after ~30 min of use.
    Gtk4.GLib.g_timeout_add(function()
        if window_closed[]
            return false   # source removed; no further callbacks
        end
        if !settings.paused
            try
                for cv in canvases; Gtk4.draw(cv); end
            catch
            end
        end
        try; _update_plot_status!(); catch; end
        # Refresh the outlier counter / σ on every tick (even when paused
        # — the stat reflects the live bridge state, not the plot buffer).
        # Wrapped in a try so a missing bridge_state (session not yet
        # started) just leaves the label at its placeholder text.
        try
            sess = state[:session]
            if sess !== nothing && sess.bridge_state !== nothing
                bs = sess.bridge_state
                n  = bs.outlier_total
                txt = if n == 0
                    "  Outliers: 0 (σ = —)"
                else
                    σ_mm = sqrt(bs.outlier_dev_sq_sum / n) * 1000.0
                    @sprintf("  Outliers: %d (σ = %.2f mm)", n, σ_mm)
                end
                Gtk4.set_gtk_property!(lbl_outlier_stats, :label, txt)
            else
                Gtk4.set_gtk_property!(lbl_outlier_stats, :label,
                                       "  Outliers: 0 (σ = —)")
            end
            Gtk4.set_gtk_property!(lbl_missing_stats, :label,
                sess === nothing ? "  Missing: —" : "  " * _missing_summary(sess.stats))
            _set_overload_label!(Gtk4, lbl_overload_plot, sess)
        catch
            # silent — the label is just a status indicator
        end
        # Persist changed settings (toolbar or web page) and outlier-guard
        # edits so the next session starts where this one left off.
        try
            sig = _settings_to_json(settings) * "|" * string(settings.auto_flush_min)
            if sig != last_settings_sig[]
                last_settings_sig[] = sig
                _save_plot_settings(settings)
            end
            if active_profile !== nothing
                psig = string(active_profile.outlier_mad_threshold, "|", active_profile.outlier_window)
                if psig != last_profile_sig[]
                    last_profile_sig[] = psig
                    save_profiles(state[:active], state[:profiles],
                                  get(state, :profiles_path, default_profiles_path()))
                end
            end
        catch err
            @debug "settings persistence failed" err
        end
        return true
    end, 1000)

    Gtk4.show(win)
    return win
end

# ---------- Reference-position dialog ----------
# Three GtkEntry boxes for N/E/U offsets in metres + an OK/Reset/Cancel
# button row. Mutates `settings` in place.
function _open_refpos_dialog(Gtk4, parent, settings::PlotSettings)
    dlg = Gtk4.GtkWindow("Reference position offset (N/E/U, metres)", 360, 200)
    Gtk4.set_gtk_property!(dlg, :transient_for, parent)
    Gtk4.set_gtk_property!(dlg, :modal, true)
    _apply_window_icon!(Gtk4, dlg)
    box = Gtk4.GtkBox(:v)
    Gtk4.set_gtk_property!(box, :spacing, 8)
    Gtk4.set_gtk_property!(box, :margin_top, 12)
    Gtk4.set_gtk_property!(box, :margin_bottom, 12)
    Gtk4.set_gtk_property!(box, :margin_start, 14)
    Gtk4.set_gtk_property!(box, :margin_end, 14)
    push!(dlg, box)

    grid = Gtk4.GtkGrid()
    Gtk4.set_gtk_property!(grid, :row_spacing, 6)
    Gtk4.set_gtk_property!(grid, :column_spacing, 8)
    push!(box, grid)

    e_n = Gtk4.GtkEntry(); Gtk4.set_gtk_property!(e_n, :text, string(settings.ref_dN_m))
    e_e = Gtk4.GtkEntry(); Gtk4.set_gtk_property!(e_e, :text, string(settings.ref_dE_m))
    e_u = Gtk4.GtkEntry(); Gtk4.set_gtk_property!(e_u, :text, string(settings.ref_dU_m))
    grid[1, 1] = Gtk4.GtkLabel("N (m):"); grid[2, 1] = e_n
    grid[1, 2] = Gtk4.GtkLabel("E (m):"); grid[2, 2] = e_e
    grid[1, 3] = Gtk4.GtkLabel("U (m):"); grid[2, 3] = e_u

    btns = Gtk4.GtkBox(:h)
    Gtk4.set_gtk_property!(btns, :spacing, 6)
    push!(box, btns)
    b_ok    = Gtk4.GtkButton("Apply")
    b_reset = Gtk4.GtkButton("Reset to 0")
    b_cancel = Gtk4.GtkButton("Cancel")
    push!(btns, b_ok); push!(btns, b_reset); push!(btns, b_cancel)

    @gs_guarded Gtk4.signal_connect(b_ok, "clicked") do _
        settings.ref_dN_m = _safe_parse(Gtk4.get_gtk_property(e_n, :text, String), settings.ref_dN_m)
        settings.ref_dE_m = _safe_parse(Gtk4.get_gtk_property(e_e, :text, String), settings.ref_dE_m)
        settings.ref_dU_m = _safe_parse(Gtk4.get_gtk_property(e_u, :text, String), settings.ref_dU_m)
        Gtk4.close(dlg)
    end
    @gs_guarded Gtk4.signal_connect(b_reset, "clicked") do _
        settings.ref_dN_m = 0.0; settings.ref_dE_m = 0.0; settings.ref_dU_m = 0.0
        Gtk4.close(dlg)
    end
    @gs_guarded Gtk4.signal_connect(b_cancel, "clicked") do _
        Gtk4.close(dlg)
    end
    Gtk4.show(dlg)
    return dlg
end

# ---------- Snapshot the currently-visible tab to PNG ----------
# Uses Cairo's ImageSurface to re-render the same drawfn into a PNG file at
# the user's chosen path. Async file picker — never blocks the Gtk loop.
function _snapshot_canvas_async(Gtk4, parent, canvases, notebook)
    page = try
        Gtk4.get_gtk_property(notebook, :page, Int)
    catch
        0
    end
    page = clamp(page, 0, length(canvases) - 1)
    cv   = canvases[page + 1]
    default_name = "plot_" * Dates.format(Dates.now(), "yyyymmdd_HHMMSS") * ".png"

    if !isdefined(Gtk4, :GtkFileDialog)
        # Headless / older Gtk4 fallback: drop straight into the logs dir.
        path = joinpath(logs_dir(), default_name)
        mkpath(dirname(path))
        try
            _render_canvas_to_png(cv, path)
            @info "snapshot saved (no picker available)" path
        catch err
            @warn "snapshot render failed" err path
        end
        return
    end
    try
        dlg = Gtk4.GtkFileDialog()
        Gtk4.set_gtk_property!(dlg, :title, "Save plot snapshot (PNG)")
        try
            Gtk4.set_gtk_property!(dlg, :initial_name, default_name)
        catch
        end
        try
            filt = Gtk4.GtkFileFilter()
            Gtk4.set_gtk_property!(filt, :name, "PNG image (*.png)")
            Gtk4.G_.add_pattern(filt, "*.png")
            store = Gtk4.GLib.GListStore(Gtk4.GtkFileFilter)
            push!(store, filt)
            Gtk4.set_gtk_property!(dlg, :filters, store)
            Gtk4.set_gtk_property!(dlg, :default_filter, filt)
        catch err
            @debug "could not attach PNG filter" err
        end

        Gtk4.G_.save(dlg, parent, nothing, (src, res) -> begin
            try
                f = Gtk4.G_.save_finish(dlg, res)
                if f !== nothing
                    path = String(Gtk4.G_.get_path(f))
                    # Auto-suffix .png if the user typed a bare name.
                    endswith(lowercase(path), ".png") || (path *= ".png")
                    _render_canvas_to_png(cv, path)
                    @info "snapshot saved" path
                end
            catch err
                isa(err, InterruptException) && rethrow(err)
                @info "snapshot dialog dismissed" err=sprint(showerror, err)
            end
            nothing
        end)
    catch err
        @warn "snapshot picker failed to open" err
    end
end

# Persist the current backing CairoSurface of `cv` to a PNG file.
# Gtk4.jl's `cairo_surface(canvas)` gives us the ARGB32 surface that already
# holds the most recent draw, so this is a single Cairo call. We trigger a
# fresh draw first so the captured image matches what's on-screen.
function _render_canvas_to_png(cv, path::AbstractString)
    try
        Main.Gtk4.draw(cv)
    catch
    end
    surf = Main.Gtk4.cairo_surface(cv)
    Main.Cairo.write_to_png(surf, path)
    return path
end

# ---------- Stacked N/E/U time series ----------
# Three sub-panels stacked vertically, drawn full-window-width. Honours
# every PlotSettings field — including Quantity (Position/Velocity/Accel),
# manual Y bounds, time-axis HH:MM:SS labels with auto-chosen ticks.
function _draw_neu_stacked(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)

    raw_hist = sess === nothing ? NTuple{4,Float64}[] : sess.stats.displacement_history
    hist = _filter_timespan(raw_hist, settings)
    hist = settings.decimate_antialias ?
            _aa_decimate(hist, settings.decimate) :
            _decimate(hist, settings.decimate)
    n = length(hist)
    scale = _y_scale(settings.y_unit)
    unit_label = _quantity_unit_label(settings)
    refs = (settings.ref_dN_m, settings.ref_dE_m, settings.ref_dU_m)
    qty_title = settings.quantity === :pos ? "Displacement per epoch" :
                settings.quantity === :vel ? "Velocity" : "Acceleration"
    colors = ((0.80,0.10,0.10), (0.10,0.55,0.10), (0.10,0.20,0.80))

    margin_top    = 8.0
    margin_bot    = 38.0   # extra space for HH:MM:SS x labels
    margin_left   = 64.0
    margin_right  = 12.0
    panel_gap     = 12.0
    panel_h = (h - margin_top - margin_bot - 2*panel_gap) / 3
    panel_w = w - margin_left - margin_right
    (panel_h < 20 || panel_w < 20) && return

    needed = settings.quantity === :pos ? 2 :
             settings.quantity === :vel ? 2 : 3
    if n < needed
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 13.0)
        Main.Gtk4.move_to(cr, margin_left + 8, margin_top + 20)
        Main.Cairo.show_text(cr,
            n == 0 ? "(no displacement samples in the selected time-span)" :
                     "(waiting for more epochs to differentiate…)")
        return
    end

    times = Float64[tup[1] for tup in hist]
    t0 = times[1]; tn = times[end]
    tspan = max(tn - t0, 1.0)
    tick_step = _nice_time_step(tspan)

    # Derive per-axis values up-front so all three panels share scaling logic.
    raw_NEU = (Float64[tup[2] - refs[1] for tup in hist],
               Float64[tup[3] - refs[2] for tup in hist],
               Float64[tup[4] - refs[3] for tup in hist])
    derived_NEU = if settings.quantity === :vel
        (_finite_diff(times, raw_NEU[1]; order = 1),
         _finite_diff(times, raw_NEU[2]; order = 1),
         _finite_diff(times, raw_NEU[3]; order = 1))
    elseif settings.quantity === :acc
        (_finite_diff(times, raw_NEU[1]; order = 2),
         _finite_diff(times, raw_NEU[2]; order = 2),
         _finite_diff(times, raw_NEU[3]; order = 2))
    else
        raw_NEU
    end
    # High-pass filter — subtract a rolling mean to remove variometric drift.
    if settings.hp_window_s > 0
        derived_NEU = (_high_pass_inplace(times, derived_NEU[1], settings.hp_window_s),
                       _high_pass_inplace(times, derived_NEU[2], settings.hp_window_s),
                       _high_pass_inplace(times, derived_NEU[3], settings.hp_window_s))
    end
    # Kalman bias-removal — 2-state filter per axis. Applied AFTER the HP
    # filter (when both are on, the HP softens the input; the Kalman then
    # tracks any residual slow drift recursively).
    if settings.kf_tau_s > 0
        derived_NEU = (_kalman_remove_bias(times, derived_NEU[1], settings.kf_tau_s),
                       _kalman_remove_bias(times, derived_NEU[2], settings.kf_tau_s),
                       _kalman_remove_bias(times, derived_NEU[3], settings.kf_tau_s))
    end

    labels = ("N ($(unit_label))", "E ($(unit_label))", "U ($(unit_label))")

    footer_txt = @sprintf("%s · time axis UTC (GPS - 18 s) · tick = %s · samples=%d (full buffer=%d)",
                          qty_title,
                          tick_step >= 60 ? "$(round(Int, tick_step/60)) min" :
                                            "$(round(Int, tick_step)) s",
                          n, length(raw_hist))
    # Holes in the input stream: one red tick per gap just under the bottom
    # panel, width ∝ epochs missing (min 1 px), plus a count on the footer
    # line, right-aligned under the ticks — not in a sub-panel, where it
    # overprinted the statistics overlay.
    if sess !== nothing && !isempty(sess.stats.input_gaps)
        iv = isnan(sess.stats.input_interval_s) ? 0.1 : sess.stats.input_interval_s
        y_bot3 = margin_top + 2 * (panel_h + panel_gap) + panel_h
        ngap = 0; nmiss_span = 0
        Main.Gtk4.set_source_rgb(cr, 0.85, 0.15, 0.15)
        for (gs, nm) in sess.stats.input_gaps
            g0 = gs - nm * iv            # first missing epoch
            (gs < t0 || g0 > tn) && continue
            x1 = margin_left + panel_w * (max(g0, t0) - t0) / tspan
            x2 = margin_left + panel_w * (min(gs, tn) - t0) / tspan
            Main.Gtk4.rectangle(cr, x1, y_bot3 + 2.0, max(x2 - x1, 1.0), 6.0); Main.Gtk4.fill(cr)
            ngap += 1; nmiss_span += nm
        end
        if ngap > 0
            Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
            Main.Cairo.set_font_size(cr, 11.0)
            footer_w = Main.Cairo.text_extents(cr, footer_txt)[3]
            Main.Cairo.set_font_size(cr, 10.0)
            txt = @sprintf("missing from stream: %d epochs in %d holes (span)  ·  session %s",
                           nmiss_span, ngap, _missing_summary(sess.stats; short = true))
            ext = Main.Cairo.text_extents(cr, txt)
            if footer_w + ext[3] + 24 > panel_w          # not enough room beside the footer text
                txt = @sprintf("missing: %d in %d holes · %s",
                               nmiss_span, ngap, _missing_summary(sess.stats; short = true))
                ext = Main.Cairo.text_extents(cr, txt)
            end
            # Footer line when it fits, else its own line just above it.
            y_note = footer_w + ext[3] + 24 > panel_w ? h - 18 : h - 6
            Main.Gtk4.move_to(cr, margin_left + panel_w - ext[3] - 2, y_note)
            Main.Cairo.show_text(cr, txt)
        end
    end

    for idx in 1:3
        py_top = margin_top + (idx - 1) * (panel_h + panel_gap)
        py_bot = py_top + panel_h

        # Apply unit scaling AFTER differentiation (so /s gets the same /1000 etc.).
        values = Float64[isnan(v) ? NaN : v * scale for v in derived_NEU[idx]]

        if settings.auto_y
            ymin = Inf; ymax = -Inf
            for v in values
                isnan(v) && continue
                ymin = min(ymin, v); ymax = max(ymax, v)
            end
            if !isfinite(ymin) || !isfinite(ymax)
                ymin, ymax = -1.0, 1.0
            elseif ymax - ymin < 1e-9
                c = 0.5 * (ymin + ymax); ymin, ymax = c - 1.0, c + 1.0
            end
            pad = 0.08 * (ymax - ymin); ymin -= pad; ymax += pad
        else
            ymin = settings.y_min; ymax = settings.y_max
            if ymax <= ymin
                ymin, ymax = -1.0, 1.0
            end
        end

        # Frame
        Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
        Main.Gtk4.set_line_width(cr, 1.0)
        Main.Gtk4.rectangle(cr, margin_left, py_top, panel_w, panel_h)
        Main.Gtk4.stroke(cr)

        # Y-axis: 5 evenly-spaced ticks
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 10.0)
        for ti in 0:4
            v  = ymin + (ymax - ymin) * ti / 4
            yy = py_bot - (panel_h * (v - ymin) / (ymax - ymin))
            if settings.show_grid
                Main.Gtk4.set_source_rgb(cr, 0.90, 0.90, 0.90)
                Main.Gtk4.move_to(cr, margin_left, yy)
                Main.Gtk4.line_to(cr, margin_left + panel_w, yy)
                Main.Gtk4.stroke(cr)
            end
            Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
            Main.Gtk4.move_to(cr, 6.0, yy + 4)
            Main.Cairo.show_text(cr, @sprintf("%8.2f", v))
        end

        # Time-axis vertical grid lines at "nice" tick boundaries.
        # Ticks on round UTC times (the sample times are GPS, 18 s ahead).
        t_first = ceil((t0 - GPS_UTC_LEAP_S) / tick_step) * tick_step + GPS_UTC_LEAP_S
        t_tick = t_first
        while t_tick <= tn
            xx = margin_left + panel_w * (t_tick - t0) / tspan
            if settings.show_grid
                Main.Gtk4.set_source_rgb(cr, 0.92, 0.92, 0.92)
                Main.Gtk4.move_to(cr, xx, py_top)
                Main.Gtk4.line_to(cr, xx, py_bot)
                Main.Gtk4.stroke(cr)
            end
            # X labels are drawn only under the bottom panel — see below.
            if idx == 3
                Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
                Main.Gtk4.move_to(cr, xx - 22, py_bot + 14)
                Main.Cairo.show_text(cr, _gps_sod_to_utc_hms(t_tick))
            end
            t_tick += tick_step
        end
        if idx == 3
            Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
            Main.Gtk4.move_to(cr, margin_left + panel_w - 26, py_bot + 26)
            Main.Cairo.show_text(cr, "UTC")
        end

        # Zero line
        if ymin < 0 < ymax
            Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
            Main.Gtk4.set_line_width(cr, 0.8)
            yy0 = py_bot - (panel_h * (0 - ymin) / (ymax - ymin))
            Main.Gtk4.move_to(cr, margin_left, yy0)
            Main.Gtk4.line_to(cr, margin_left + panel_w, yy0)
            Main.Gtk4.stroke(cr)
        end

        # Series — thin connecting line + small filled marker on each sample.
        r, g, b = colors[idx]
        Main.Gtk4.set_source_rgb(cr, r, g, b)
        Main.Gtk4.set_line_width(cr, 0.8)
        moving = false
        lod = _lod_indices(times, values, t0, tspan, panel_w)
        for i in lod
            v = values[i]
            if isnan(v); moving = false; continue; end
            xx = margin_left + panel_w * (times[i] - t0) / tspan
            yy = py_bot - (panel_h * (v - ymin) / (ymax - ymin))
            if !moving
                Main.Gtk4.move_to(cr, xx, yy); moving = true
            else
                Main.Gtk4.line_to(cr, xx, yy)
            end
        end
        Main.Gtk4.stroke(cr)
        # Per-sample markers. Skipped when there are too many points so the
        # circles don't merge into a solid block (purely visual heuristic).
        if length(lod) <= 600
            for i in lod
                v = values[i]
                isnan(v) && continue
                xx = margin_left + panel_w * (times[i] - t0) / tspan
                yy = py_bot - (panel_h * (v - ymin) / (ymax - ymin))
                Main.Cairo.arc(cr, xx, yy, 1.6, 0.0, 2π); Main.Gtk4.fill(cr)
            end
        end

        # Title in top-left
        Main.Gtk4.set_source_rgb(cr, 0.0, 0.0, 0.0)
        Main.Cairo.set_font_size(cr, 12.0)
        Main.Gtk4.move_to(cr, margin_left + 6, py_top + 14)
        Main.Cairo.show_text(cr, labels[idx])

        # Statistics overlay in top-right
        if settings.show_stats
            μ, σ, rms, ptp = _series_stats(values)
            if isfinite(μ)
                txt = @sprintf("μ=%.2f  σ=%.2f  rms=%.2f  p-p=%.2f", μ, σ, rms, ptp)
                Main.Gtk4.set_source_rgb(cr, 0.20, 0.20, 0.20)
                Main.Cairo.set_font_size(cr, 11.0)
                approx_w = 7.0 * length(txt)
                Main.Gtk4.move_to(cr, margin_left + panel_w - approx_w - 6, py_top + 14)
                Main.Cairo.show_text(cr, txt)
            end
        end
    end

    # Footer
    Main.Gtk4.set_source_rgb(cr, 0.25, 0.25, 0.25)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 11.0)
    Main.Gtk4.move_to(cr, margin_left, h - 6)
    Main.Cairo.show_text(cr, footer_txt)
end

# ---------- E vs N ground-track scatter ----------
# Points coloured by recency (oldest blue → newest red). Equal aspect, so a
# circular jitter remains circular. Honours timespan filter, units, grid,
# stats overlay, and ref-pos offset.
function _draw_en_scatter(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)

    raw_hist = sess === nothing ? NTuple{4,Float64}[] : sess.stats.displacement_history
    hist = _filter_timespan(raw_hist, settings)
    hist = settings.decimate_antialias ?
            _aa_decimate(hist, settings.decimate) :
            _decimate(hist, settings.decimate)
    n = length(hist)
    scale = _y_scale(settings.y_unit)
    unit_label = _y_label(settings.y_unit)
    refN = settings.ref_dN_m; refE = settings.ref_dE_m

    margin = 56.0
    pw = w - 2*margin; ph = h - 2*margin
    (pw < 20 || ph < 20) && return

    if n == 0
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 13.0)
        Main.Gtk4.move_to(cr, margin + 8, margin + 20)
        Main.Cairo.show_text(cr, "(no displacement samples in the selected time-span)")
        return
    end

    Nvals = Float64[]; Evals = Float64[]
    for tup in hist
        push!(Nvals, (tup[2] - refN) * scale)
        push!(Evals, (tup[3] - refE) * scale)
    end
    nmin = Inf; nmax = -Inf; emin = Inf; emax = -Inf
    for i in 1:n
        Nv = Nvals[i]; Ev = Evals[i]
        (isnan(Nv) || isnan(Ev)) && continue
        nmin = min(nmin, Nv); nmax = max(nmax, Nv)
        emin = min(emin, Ev); emax = max(emax, Ev)
    end
    if !isfinite(nmin) || !isfinite(emin)
        return
    end
    nspan = max(nmax - nmin, 1.0); espan = max(emax - emin, 1.0)
    span  = max(nspan, espan) * 1.10
    n_c = 0.5 * (nmin + nmax); e_c = 0.5 * (emin + emax)
    nmin, nmax = n_c - span/2, n_c + span/2
    emin, emax = e_c - span/2, e_c + span/2

    side = min(pw, ph)
    px0 = margin + (pw - side)/2
    py0 = margin + (ph - side)/2

    # Frame + grid
    Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
    Main.Gtk4.set_line_width(cr, 1.0)
    Main.Gtk4.rectangle(cr, px0, py0, side, side); Main.Gtk4.stroke(cr)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 10.0)
    for ti in 0:4
        ev = emin + (emax - emin) * ti / 4
        xx = px0 + side * (ev - emin) / (emax - emin)
        if settings.show_grid
            Main.Gtk4.set_source_rgb(cr, 0.90, 0.90, 0.90)
            Main.Gtk4.move_to(cr, xx, py0); Main.Gtk4.line_to(cr, xx, py0 + side); Main.Gtk4.stroke(cr)
        end
        Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
        Main.Gtk4.move_to(cr, xx - 14, py0 + side + 14)
        Main.Cairo.show_text(cr, @sprintf("%6.2f", ev))

        nv = nmin + (nmax - nmin) * ti / 4
        yy = py0 + side - side * (nv - nmin) / (nmax - nmin)
        if settings.show_grid
            Main.Gtk4.set_source_rgb(cr, 0.90, 0.90, 0.90)
            Main.Gtk4.move_to(cr, px0, yy); Main.Gtk4.line_to(cr, px0 + side, yy); Main.Gtk4.stroke(cr)
        end
        Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
        Main.Gtk4.move_to(cr, px0 - 48, yy + 4)
        Main.Cairo.show_text(cr, @sprintf("%6.2f", nv))
    end

    # Origin cross (the ref-pos point of the new frame)
    if emin < 0 < emax && nmin < 0 < nmax
        Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
        Main.Gtk4.set_line_width(cr, 0.8)
        xx0 = px0 + side * (0 - emin) / (emax - emin)
        yy0 = py0 + side - side * (0 - nmin) / (nmax - nmin)
        Main.Gtk4.move_to(cr, xx0 - 8, yy0); Main.Gtk4.line_to(cr, xx0 + 8, yy0); Main.Gtk4.stroke(cr)
        Main.Gtk4.move_to(cr, xx0, yy0 - 8); Main.Gtk4.line_to(cr, xx0, yy0 + 8); Main.Gtk4.stroke(cr)
    end

    # Points — colour gradient from blue (oldest) → red (newest).
    #
    # This drew one arc+fill per sample: 6000 of them at 10 Hz over 10 min,
    # 36000 over an hour, and it was the single most expensive thing the web
    # server did. Consecutive 10 Hz samples almost always land on the same
    # pixel, so skip any point whose pixel is already painted. The result is
    # visually identical and bounded by the panel's pixel count, not by the
    # sample count.
    side_px = max(1, ceil(Int, side)) + 2
    seen = falses(side_px * side_px)
    @inbounds for i in 1:n
        Nv = Nvals[i]; Ev = Evals[i]
        (isnan(Nv) || isnan(Ev)) && continue
        xx = px0 + side * (Ev - emin) / (emax - emin)
        yy = py0 + side - side * (Nv - nmin) / (nmax - nmin)
        # Flat bitmap rather than a hashed Set: one indexed test per sample.
        cxp = clamp(round(Int, xx - px0), 0, side_px - 1)
        cyp = clamp(round(Int, yy - py0), 0, side_px - 1)
        key = cxp * side_px + cyp + 1
        seen[key] && continue
        seen[key] = true
        frac = n == 1 ? 1.0 : (i - 1) / (n - 1)
        r = 0.15 + 0.75 * frac
        g = 0.15
        b = 0.85 - 0.75 * frac
        Main.Gtk4.set_source_rgb(cr, r, g, b)
        Main.Cairo.new_sub_path(cr)
        Main.Cairo.arc(cr, xx, yy, 2.5, 0.0, 2π); Main.Gtk4.fill(cr)
    end

    # Marker for the latest sample (white-edged red circle, RTKPLOT-style)
    last_idx = something(findlast(i -> !isnan(Nvals[i]) && !isnan(Evals[i]), 1:n), 0)
    if last_idx > 0
        xx = px0 + side * (Evals[last_idx] - emin) / (emax - emin)
        yy = py0 + side - side * (Nvals[last_idx] - nmin) / (nmax - nmin)
        Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
        Main.Cairo.arc(cr, xx, yy, 5.5, 0.0, 2π); Main.Gtk4.fill(cr)
        Main.Gtk4.set_source_rgb(cr, 0.85, 0.05, 0.05)
        Main.Cairo.arc(cr, xx, yy, 4.0, 0.0, 2π); Main.Gtk4.fill(cr)
    end

    # Axis labels
    Main.Gtk4.set_source_rgb(cr, 0.0, 0.0, 0.0)
    Main.Cairo.set_font_size(cr, 12.0)
    Main.Gtk4.move_to(cr, px0 + side/2 - 36, py0 + side + 32)
    Main.Cairo.show_text(cr, "East ($(unit_label)) →")
    Main.Gtk4.move_to(cr, px0 + 2, py0 - 8)               # above the frame: clear of the y tick labels
    Main.Cairo.show_text(cr, "↑ North ($(unit_label))")

    # Statistics overlay
    if settings.show_stats
        μN, σN, rmsN, ptpN = _series_stats(Nvals)
        μE, σE, rmsE, ptpE = _series_stats(Evals)
        if isfinite(μN) && isfinite(μE)
            Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15)
            Main.Cairo.set_font_size(cr, 11.0)
            txt1 = @sprintf("N:  μ=%.2f  σ=%.2f  rms=%.2f", μN, σN, rmsN)
            txt2 = @sprintf("E:  μ=%.2f  σ=%.2f  rms=%.2f", μE, σE, rmsE)
            txt3 = @sprintf("samples=%d   ref=(%.3f, %.3f, %.3f) m",
                            n, settings.ref_dN_m, settings.ref_dE_m, settings.ref_dU_m)
            # inside the top-left corner of the frame, on a white box: never on
            # the axis tick numbers or the axis labels (they overlapped on wide panels)
            Main.Gtk4.set_source_rgba(cr, 1.0, 1.0, 1.0, 0.85)
            Main.Gtk4.rectangle(cr, px0 + 4, py0 + 4, 300.0, 48.0); Main.Gtk4.fill(cr)
            Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15)
            Main.Gtk4.move_to(cr, px0 + 8, py0 + 17); Main.Cairo.show_text(cr, txt1)
            Main.Gtk4.move_to(cr, px0 + 8, py0 + 31); Main.Cairo.show_text(cr, txt2)
            Main.Gtk4.move_to(cr, px0 + 8, py0 + 45); Main.Cairo.show_text(cr, txt3)
        end
    end
end

# ---------- Polar skyplot (azimuth + elevation of currently-tracked sats) ----------
# Reads `bridge_state.data.loc.<sys>` which calcsatnav populates per epoch:
# col 1 = azimuth (rad), col 2 = elevation (rad). Plotted standard nav-style:
# north up, east right, zenith at the centre, horizon at the outer ring.
function _draw_skyplot(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)

    bs = sess === nothing ? nothing : sess.bridge_state
    cx = w/2; cy = h/2; R = min(w, h)/2 - 40
    R <= 30 && return

    # Concentric rings at elevation = 0, 15, 30, 45, 60, 75 degrees
    Main.Gtk4.set_source_rgb(cr, 0.78, 0.78, 0.78)
    Main.Gtk4.set_line_width(cr, 0.7)
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 10.0)
    for elv_deg in (0, 15, 30, 45, 60, 75)
        rr = R * (90 - elv_deg) / 90
        # `arc` APPENDS to the current path — after the previous iteration's
        # `show_text` the cursor sits by the label, so without a fresh
        # sub-path Cairo joins that point to the arc's start (due east) and
        # draws a stray chord across the plot for every ring.
        Main.Cairo.new_sub_path(cr)
        Main.Cairo.arc(cr, cx, cy, rr, 0.0, 2π)
        Main.Gtk4.stroke(cr)
        Main.Gtk4.set_source_rgb(cr, 0.4, 0.4, 0.4)
        Main.Gtk4.move_to(cr, cx + 2, cy - rr - 2)
        Main.Cairo.show_text(cr, @sprintf("%d°", elv_deg))
        Main.Gtk4.set_source_rgb(cr, 0.78, 0.78, 0.78)
    end
    # Cross spokes at N/E/S/W with cardinal labels
    Main.Gtk4.set_source_rgb(cr, 0.75, 0.75, 0.75)
    Main.Gtk4.move_to(cr, cx - R, cy); Main.Gtk4.line_to(cr, cx + R, cy); Main.Gtk4.stroke(cr)
    Main.Gtk4.move_to(cr, cx, cy - R); Main.Gtk4.line_to(cr, cx, cy + R); Main.Gtk4.stroke(cr)
    Main.Gtk4.set_source_rgb(cr, 0.0, 0.0, 0.0)
    Main.Cairo.set_font_size(cr, 13.0)
    Main.Gtk4.move_to(cr, cx - 4, cy - R - 6); Main.Cairo.show_text(cr, "N")
    Main.Gtk4.move_to(cr, cx + R + 4, cy + 4); Main.Cairo.show_text(cr, "E")
    Main.Gtk4.move_to(cr, cx - 4, cy + R + 14); Main.Cairo.show_text(cr, "S")
    Main.Gtk4.move_to(cr, cx - R - 14, cy + 4); Main.Cairo.show_text(cr, "W")

    # Per-constellation colours, RTKPLOT-style
    syscolors = Dict(:gps => (0.10, 0.20, 0.85),
                     :glo => (0.85, 0.10, 0.10),
                     :gal => (0.10, 0.60, 0.10),
                     :bds => (0.85, 0.55, 0.10))
    syslabel = Dict(:gps => "G", :glo => "R", :gal => "E", :bds => "C")

    # ---- Satellite trails ----
    # Thin dashed polyline per PRN showing where it came from, drawn under
    # the current-position markers so the markers stay legible.
    tracks = sess === nothing ? nothing : sess.stats.skyplot_tracks
    if tracks !== nothing && !isempty(tracks)
        # Same nav projection as the markers below.
        proj(az_deg, elv_deg) = begin
            rr  = R * (90 - elv_deg) / 90
            ang = (az_deg - 90) * pi/180
            (cx + rr * cos(ang), cy + rr * sin(ang))
        end
        Main.Gtk4.set_line_width(cr, 1.0)
        Main.Cairo.set_dash(cr, [3.0, 3.0])
        for ((sysf, _prn), tr) in tracks
            length(tr) >= 2 || continue
            haskey(syscolors, sysf) || continue
            r, g, b = syscolors[sysf]
            # Dimmed against the solid marker colour.
            Main.Cairo.set_source_rgba(cr, r, g, b, 0.55)
            started = false
            px = NaN; py = NaN
            for (az_deg, elv_deg) in tr
                (isnan(az_deg) || isnan(elv_deg) || elv_deg <= 0) && continue
                xx, yy = proj(az_deg, elv_deg)
                # Break the polyline on any implausible jump between
                # consecutive samples. This covers both the 360->0 azimuth
                # wrap and the first epochs of a session, where PPPHVA has
                # not converged yet and az/el are far from their true values
                # — without the break those show up as long straight chords
                # drawn clean across the plot.
                if started && !isnan(px)
                    step = hypot(xx - px, yy - py)
                    if step > 0.08 * R
                        Main.Gtk4.stroke(cr)
                        started = false
                    end
                end
                if started
                    Main.Gtk4.line_to(cr, xx, yy)
                else
                    Main.Gtk4.move_to(cr, xx, yy)
                    started = true
                end
                px = xx; py = yy
            end
            started && Main.Gtk4.stroke(cr)
        end
        Main.Cairo.set_dash(cr, Float64[])     # back to solid for everything else
    end

    if bs === nothing || !hasfield_p_safe(bs.data, :loc)
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.set_font_size(cr, 13.0)
        Main.Gtk4.move_to(cr, 12.0, h - 14.0)
        Main.Cairo.show_text(cr, "(skyplot populates once the engine has run an epoch)")
        return
    end
    loc = bs.data.loc

    n_drawn = 0
    for sysf in (:gps, :glo, :gal, :bds)
        hasfield_p_safe(loc, sysf) || continue
        arr = getproperty(loc, sysf)
        size(arr, 1) == 0 && continue
        r, g, b = syscolors[sysf]
        Main.Gtk4.set_source_rgb(cr, r, g, b)
        for prn in 1:size(arr, 1)
            az_deg  = arr[prn, 1]
            elv_deg = arr[prn, 2]
            # PPPHVA's elvcut calls local_ae with dopt=1 → both columns are
            # already in DEGREES (not radians), so no further conversion.
            (isnan(az_deg) || isnan(elv_deg) || elv_deg <= 0) && continue
            # Standard nav projection: r ∝ (90° - elv), angle = azimuth
            # measured clockwise from north (so 0° = up, 90° = right).
            rr  = R * (90 - elv_deg) / 90
            ang = (az_deg - 90) * π/180
            xx = cx + rr * cos(ang)
            yy = cy + rr * sin(ang)
            Main.Cairo.new_sub_path(cr)
            Main.Cairo.arc(cr, xx, yy, 5.5, 0.0, 2π); Main.Gtk4.fill(cr)
            # PRN label next to the marker
            Main.Gtk4.set_source_rgb(cr, 0.0, 0.0, 0.0)
            Main.Cairo.set_font_size(cr, 10.0)
            Main.Gtk4.move_to(cr, xx + 7, yy + 4)
            Main.Cairo.show_text(cr, syslabel[sysf] * string(prn))
            Main.Gtk4.set_source_rgb(cr, r, g, b)
            n_drawn += 1
        end
    end

    # Footer with sat count
    Main.Gtk4.set_source_rgb(cr, 0.25, 0.25, 0.25)
    Main.Cairo.set_font_size(cr, 11.0)
    Main.Gtk4.move_to(cr, 12.0, h - 14.0)
    Main.Cairo.show_text(cr,
        @sprintf("tracking %d sats   (G=GPS  R=GLO  E=GAL  C=BDS)", n_drawn))
end

# ---------- Helper: generic single-panel time series ----------
# Centralised drawing so the σ̂ and DOP tabs share grid/axes logic with the
# main N/E/U panels. `series` is a vector of `(label, color::NTuple{3,Float64},
# values::Vector{Float64})`; all share the same time axis (`times`).
function _draw_timeseries_panel(cr, x0::Float64, y0::Float64, w::Float64, h::Float64,
                                title::AbstractString, times::AbstractVector{Float64},
                                series::Vector, settings::PlotSettings;
                                y_label::AbstractString = "",
                                y_min_override = nothing,
                                y_max_override = nothing,
                                show_legend::Bool = true,
                                show_x_labels::Bool = true)
    # Compute Y bounds from all series (unless overridden).
    ymin = Inf; ymax = -Inf
    for (_, _, vals) in series
        for v in vals
            isnan(v) && continue
            ymin = min(ymin, v); ymax = max(ymax, v)
        end
    end
    y_min_override !== nothing && (ymin = y_min_override)
    y_max_override !== nothing && (ymax = y_max_override)
    if !isfinite(ymin) || !isfinite(ymax) || ymax - ymin < 1e-9
        # Empty / degenerate — pad around mean (or zero).
        c = isfinite(ymin) ? 0.5*(ymin+ymax) : 0.0
        ymin, ymax = c - 1.0, c + 1.0
    end
    pad = 0.08 * (ymax - ymin); ymin -= pad; ymax += pad

    # Frame
    Main.Gtk4.set_source_rgb(cr, 0.55, 0.55, 0.55)
    Main.Gtk4.set_line_width(cr, 1.0)
    Main.Gtk4.rectangle(cr, x0, y0, w, h); Main.Gtk4.stroke(cr)

    # Y ticks + grid
    Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
    Main.Cairo.set_font_size(cr, 10.0)
    for ti in 0:4
        v  = ymin + (ymax - ymin) * ti / 4
        yy = y0 + h - (h * (v - ymin) / (ymax - ymin))
        if settings.show_grid
            Main.Gtk4.set_source_rgb(cr, 0.90, 0.90, 0.90)
            Main.Gtk4.move_to(cr, x0, yy); Main.Gtk4.line_to(cr, x0 + w, yy); Main.Gtk4.stroke(cr)
        end
        Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
        Main.Gtk4.move_to(cr, x0 - 52, yy + 4)
        Main.Cairo.show_text(cr, @sprintf("%8.3f", v))
    end

    # Time axis
    n = length(times)
    t0 = isempty(times) ? 0.0 : times[1]
    tn = isempty(times) ? 1.0 : times[end]
    tspan = max(tn - t0, 1.0)
    px(i) = x0 + w * (times[i] - t0) / tspan
    py(v) = y0 + h - (h * (v - ymin) / (ymax - ymin))

    # Time-axis vertical grid + HH:MM:SS tick labels.
    if !isempty(times)
        tick_step = _nice_time_step(tspan)
        t_tick = ceil((t0 - GPS_UTC_LEAP_S) / tick_step) * tick_step + GPS_UTC_LEAP_S   # round UTC times
        while t_tick <= tn
            xx = x0 + w * (t_tick - t0) / tspan
            if settings.show_grid
                Main.Gtk4.set_source_rgb(cr, 0.92, 0.92, 0.92)
                Main.Gtk4.move_to(cr, xx, y0)
                Main.Gtk4.line_to(cr, xx, y0 + h)
                Main.Gtk4.stroke(cr)
            end
            if show_x_labels
                Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
                Main.Gtk4.move_to(cr, xx - 22, y0 + h + 14)
                Main.Cairo.show_text(cr, _gps_sod_to_utc_hms(t_tick))
            end
            t_tick += tick_step
        end
        if show_x_labels
            Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
            Main.Gtk4.move_to(cr, x0 + w - 26, y0 + h + 26)
            Main.Cairo.show_text(cr, "UTC")
        end
    end

    # Series — thin line + small markers (same style as the NEU panels).
    # Reduced to per-pixel min/max first: this panel serves the residual and
    # the #sats/DOP tabs, which at 10 Hz over a long span were drawing tens of
    # thousands of segments per frame.
    tspan_p = n > 1 ? (times[end] - times[1]) : 0.0
    for (_, color, vals) in series
        Main.Gtk4.set_source_rgb(cr, color...)
        Main.Gtk4.set_line_width(cr, 0.8)
        lod = _lod_indices(times, vals, times[1], tspan_p, w)
        moving = false
        for i in lod
            v = vals[i]
            if isnan(v); moving = false; continue; end
            if !moving
                Main.Gtk4.move_to(cr, px(i), py(v)); moving = true
            else
                Main.Gtk4.line_to(cr, px(i), py(v))
            end
        end
        Main.Gtk4.stroke(cr)
        if length(lod) <= 600
            for i in lod
                v = vals[i]
                isnan(v) && continue
                Main.Cairo.new_sub_path(cr)
                Main.Cairo.arc(cr, px(i), py(v), 1.6, 0.0, 2π); Main.Gtk4.fill(cr)
            end
        end
    end

    # Title (top-left)
    Main.Gtk4.set_source_rgb(cr, 0.0, 0.0, 0.0)
    Main.Cairo.set_font_size(cr, 12.0)
    Main.Gtk4.move_to(cr, x0 + 6, y0 + 14)
    Main.Cairo.show_text(cr, title)

    # Legend (top-right) when multiple series share a panel.
    if show_legend && length(series) > 1
        Main.Cairo.set_font_size(cr, 11.0)
        legend_x = x0 + w - 8
        legend_y = y0 + 14
        for (label, color, _) in Iterators.reverse(series)
            tw = 7.0 * length(label) + 22.0
            Main.Gtk4.set_source_rgb(cr, color...)
            Main.Gtk4.rectangle(cr, legend_x - tw + 4, legend_y - 9, 12, 4)
            Main.Gtk4.fill(cr)
            Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15)
            Main.Gtk4.move_to(cr, legend_x - tw + 20, legend_y)
            Main.Cairo.show_text(cr, label)
            legend_x -= tw
        end
    end

    # Y-axis label
    if !isempty(y_label)
        Main.Gtk4.set_source_rgb(cr, 0.25, 0.25, 0.25)
        Main.Cairo.set_font_size(cr, 11.0)
        Main.Gtk4.move_to(cr, x0 - 50, y0 - 4)
        Main.Cairo.show_text(cr, y_label)
    end
end

# ---------- σ̂ residual history ----------
# Single-panel line plot of the post-fit residual σ̂ versus epoch SOD.
# Displayed in either metres or millimetres depending on the unit setting.
function _draw_residual(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)

    raw = sess === nothing ? NTuple{2,Float64}[] : sess.stats.residual_history
    hist = _filter_timespan(raw, settings)
    margin_left = 60.0; margin_right = 14.0
    margin_top  = 36.0; margin_bot   = 32.0
    pw = w - margin_left - margin_right
    ph = h - margin_top  - margin_bot
    (pw < 30 || ph < 30) && return

    scale = _y_scale(settings.y_unit)
    ulabel = _y_label(settings.y_unit)

    if length(hist) < 2
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 13.0)
        Main.Gtk4.move_to(cr, margin_left + 8, margin_top + 20)
        Main.Cairo.show_text(cr,
            isempty(hist) ? "(no σ̂ samples in the selected time-span)" :
                            "(waiting for second accepted epoch…)")
        return
    end

    col = _resid_column(settings.resid_method)
    times = Float64[r[1] for r in hist]
    vals  = Float64[r[col] * scale for r in hist]
    series = [("σ̂", (0.55, 0.10, 0.55), vals)]

    _draw_timeseries_panel(cr, margin_left, margin_top, pw, ph,
        _resid_title(settings.resid_method) * " ($(ulabel))", times, series, settings;
        y_label = ulabel,
        y_min_override = 0.0,
        show_legend = false)
    # one line on how this statistic is computed
    Main.Gtk4.set_source_rgb(cr, 0.35, 0.35, 0.35)
    Main.Cairo.set_font_size(cr, 10.0)
    Main.Gtk4.move_to(cr, margin_left + 6, margin_top + 12)
    Main.Cairo.show_text(cr, _resid_explain(settings.resid_method))

    # Stats overlay + sample count
    if settings.show_stats
        μ, σ, rms, ptp = _series_stats(vals)
        if isfinite(μ)
            Main.Gtk4.set_source_rgb(cr, 0.15, 0.15, 0.15)
            Main.Cairo.set_font_size(cr, 11.0)
            txt = @sprintf("μ=%.3f  σ=%.3f  rms=%.3f  peak=%.3f %s   n=%d",
                            μ, σ, rms, ptp, ulabel, length(vals))
            Main.Gtk4.move_to(cr, margin_left, h - 14)
            Main.Cairo.show_text(cr, txt)
        end
    end
end

# ---------- #sats + DOP tab ----------
# Two stacked panels: number of satellites on top, GDOP/PDOP/HDOP/VDOP on
# the bottom. Both honour the global timespan filter + grid setting.
function _draw_nsat_dop(cr, w::Float64, h::Float64, sess, settings::PlotSettings)
    Main.Gtk4.set_source_rgb(cr, 1.0, 1.0, 1.0)
    Main.Gtk4.rectangle(cr, 0, 0, w, h); Main.Gtk4.fill(cr)

    raw = sess === nothing ? NTuple{6,Float64}[] : sess.stats.dop_history
    hist = _filter_timespan(raw, settings)

    margin_left = 60.0; margin_right = 14.0
    margin_top  = 30.0; margin_bot   = 40.0
    panel_gap   = 18.0
    panel_h = (h - margin_top - margin_bot - panel_gap) / 2
    panel_w = w - margin_left - margin_right
    (panel_h < 30 || panel_w < 30) && return

    if length(hist) < 2
        Main.Gtk4.set_source_rgb(cr, 0.5, 0.5, 0.5)
        Main.Cairo.select_font_face(cr, "sans-serif", 0, 0)
        Main.Cairo.set_font_size(cr, 13.0)
        Main.Gtk4.move_to(cr, margin_left + 8, margin_top + 20)
        Main.Cairo.show_text(cr,
            isempty(hist) ? "(no DOP samples in the selected time-span)" :
                            "(waiting for second accepted epoch…)")
        return
    end

    times = Float64[t for (t, _nsat, _g, _p, _h, _v) in hist]

    # Panel 1: nsats
    nsats_vals = Float64[nsat for (_, nsat, _g, _p, _h, _v) in hist]
    nmax = maximum(filter(!isnan, nsats_vals); init = 0.0)
    series1 = [("# sats", (0.20, 0.40, 0.95), nsats_vals)]
    _draw_timeseries_panel(cr, margin_left, margin_top, panel_w, panel_h,
        "Number of satellites used", times, series1, settings;
        y_label = "n", y_min_override = 0.0,
        y_max_override = max(nmax + 1.0, 5.0),
        show_legend = false, show_x_labels = false)

    # Panel 2: GDOP/PDOP/HDOP/VDOP
    py2 = margin_top + panel_h + panel_gap
    gdop = Float64[g for (_, _n, g, _p, _h, _v) in hist]
    pdop = Float64[p for (_, _n, _g, p, _h, _v) in hist]
    hdop = Float64[hh for (_, _n, _g, _p, hh, _v) in hist]
    vdop = Float64[v for (_, _n, _g, _p, _h, v) in hist]
    series2 = [
        ("GDOP", (0.60, 0.60, 0.60), gdop),
        ("PDOP", (0.85, 0.10, 0.10), pdop),
        ("HDOP", (0.10, 0.55, 0.10), hdop),
        ("VDOP", (0.10, 0.20, 0.85), vdop),
    ]
    _draw_timeseries_panel(cr, margin_left, py2, panel_w, panel_h,
        "DOP", times, series2, settings;
        y_label = "DOP",
        y_min_override = 0.0)

    # Footer
    Main.Gtk4.set_source_rgb(cr, 0.25, 0.25, 0.25)
    Main.Cairo.set_font_size(cr, 11.0)
    Main.Gtk4.move_to(cr, margin_left, h - 12)
    if settings.show_stats && !isempty(hdop)
        μn, _, _, _ = _series_stats(nsats_vals)
        μh, _, _, _ = _series_stats(hdop)
        μv, _, _, _ = _series_stats(vdop)
        Main.Cairo.show_text(cr,
            @sprintf("n=%d samples · ⟨#sats⟩=%.1f · ⟨HDOP⟩=%.2f · ⟨VDOP⟩=%.2f",
                     length(times), μn, μh, μv))
    else
        Main.Cairo.show_text(cr,
            @sprintf("n=%d samples", length(times)))
    end
end

# ============================================================
# Web server — serve the Plot window's panels over HTTP
# ============================================================
# Renders each draw function to a Cairo ImageSurface, writes a PNG, and
# serves it. An index page auto-refreshes the five `<img>` tags every
# second so a browser on the LAN sees the same content as the desktop
# Plot window, with the same PlotSettings (units, span, ref-pos, …).

# Best-effort detection of the machine's primary LAN IPv4 address — the
# one another host on the network would use to reach this server. Tries
# `Sockets.getipaddrs()` (returns all bound interfaces) and picks the
# first non-loopback IPv4. Falls back to "127.0.0.1" on Windows hosts
# with no network adapter currently up.
function _primary_lan_ip()
    try
        addrs = Sockets.getipaddrs()
        for ip in addrs
            ip isa Sockets.IPv4 || continue
            s = string(ip)
            s == "127.0.0.1" && continue
            startswith(s, "169.254.") && continue   # link-local APIPA
            return s
        end
    catch err
        @debug "getipaddrs() failed" err
    end
    return "127.0.0.1"
end

# Build a PNG-encoded image of one panel into a Vector{UInt8}.
# Cairo.jl's `write_to_png` is most portable when given a file path, so
# we tee through a tempfile and `read` it back. Width/height match the
# default canvas size — a sensible compromise between detail and bandwidth.
function _render_panel_to_png_bytes(drawfn, w::Int, h::Int, sess, settings::PlotSettings)
    # Called once per panel per web request (5 panels/poll). `Cairo.finish`
    # only flushes pending drawing — it does NOT free the surface's pixel
    # buffer; that waits for Julia's GC to run the finalizer. Under a browser
    # polling for hours the surfaces pile up faster than GC reclaims them
    # (observed: RSS to ~30 GB / OOM over ~10 h). `Cairo.destroy` frees the C
    # object immediately, so each request releases its ~w*h*4 bytes at once.
    surf = Main.Cairo.CairoImageSurface(w, h, Main.Cairo.FORMAT_ARGB32)
    cr   = Main.Cairo.CairoContext(surf)
    try
        drawfn(cr, Float64(w), Float64(h), sess, settings)
    finally
        try; Main.Cairo.destroy(cr); catch; end
    end
    tmp = tempname() * ".png"
    try
        Main.Cairo.write_to_png(surf, tmp)
        return read(tmp)
    finally
        try; Main.Cairo.destroy(surf); catch; end
        try; isfile(tmp) && rm(tmp); catch; end
    end
end

# ---- Settings sync helpers ----
# Mutate `settings` from a URL query string (k=v&k=v…). Silently ignores
# unknown keys / malformed values so a bad client can't crash the server.
function _apply_query_to_settings!(settings::PlotSettings, qs::AbstractString)
    for pair in split(qs, '&')
        kv = split(pair, '='; limit = 2)
        length(kv) == 2 || continue
        k = String(kv[1]); v = String(kv[2])
        if k == "qty"
            settings.quantity = v == "vel" ? :vel : v == "acc" ? :acc : :pos
        elseif k == "resid"
            Symbol(v) in (:engine, :rms_w, :rms_u, :sigma_va) && (settings.resid_method = Symbol(v))
        elseif k == "unit"
            settings.y_unit = v == "cm" ? :cm : v == "m" ? :m : :mm
        elseif k == "span"
            sp = tryparse(Float64, v); sp !== nothing && (settings.timespan_sec = sp)
        elseif k == "grid"
            settings.show_grid = (v == "1" || v == "true")
        elseif k == "stats"
            settings.show_stats = (v == "1" || v == "true")
        elseif k == "cause"
            settings.cause_view = _cause_symbol(v)
        elseif k == "show_causes"
            settings.show_causes = (v == "1" || v == "true")
        elseif k == "web_refresh"
            r = tryparse(Float64, v); r !== nothing && (settings.web_refresh_s = clamp(r, 0.2, 60.0))
        elseif k == "paused"
            settings.paused = (v == "1" || v == "true")
        elseif k == "auto_y"
            settings.auto_y = (v == "1" || v == "true")
        elseif k == "ymin"
            ym = tryparse(Float64, v); ym !== nothing && (settings.y_min = ym)
        elseif k == "ymax"
            ym = tryparse(Float64, v); ym !== nothing && (settings.y_max = ym)
        elseif k == "refN"
            r = tryparse(Float64, v); r !== nothing && (settings.ref_dN_m = r)
        elseif k == "refE"
            r = tryparse(Float64, v); r !== nothing && (settings.ref_dE_m = r)
        elseif k == "refU"
            r = tryparse(Float64, v); r !== nothing && (settings.ref_dU_m = r)
        elseif k == "hp_s"
            r = tryparse(Float64, v); r !== nothing && (settings.hp_window_s = max(r, 0.0))
        elseif k == "kf_tau"
            r = tryparse(Float64, v); r !== nothing && (settings.kf_tau_s = max(r, 0.0))
        elseif k == "dec"
            r = tryparse(Int, v); r !== nothing && r >= 1 && (settings.decimate = r)
        elseif k == "dec_aa"
            settings.decimate_antialias = (v == "1" || v == "true")
        end
    end
    return settings
end

# Serialize PlotSettings to JSON (small enough to hand-write — avoids
# pulling in a JSON package as a hard dep).
# ---- Plot settings persistence ------------------------------------------
# Every PlotSettings field except `paused` is written to
# config/plot_settings.toml whenever it changes (the plot window's 1 s
# timer compares a signature) and read back when the plot window opens, so
# the high-pass window, Kalman time-constant, decimation, auto-flush, axis
# and reference settings survive a restart. The outlier guard's MAD
# threshold and window live in the profile and are saved there.
const _PLOT_SETTINGS_SKIP = (:paused,)
_plot_settings_path() = joinpath(config_dir(), "plot_settings.toml")
function _save_plot_settings(s::PlotSettings)
    d = Dict{String,Any}()
    for f in fieldnames(PlotSettings)
        f in _PLOT_SETTINGS_SKIP && continue
        v = getfield(s, f)
        d[String(f)] = v isa Symbol ? String(v) : v
    end
    path = _plot_settings_path()
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, d; sorted = true)
    end
    return path
end
function _load_plot_settings!(s::PlotSettings)
    path = _plot_settings_path()
    isfile(path) || return s
    d = try; TOML.parsefile(path); catch err
        @warn "plot_settings.toml unreadable — using defaults" path err
        return s
    end
    for f in fieldnames(PlotSettings)
        f in _PLOT_SETTINGS_SKIP && continue
        haskey(d, String(f)) || continue
        T = fieldtype(PlotSettings, f); v = d[String(f)]
        try
            setfield!(s, f, T === Symbol ? Symbol(v) : T === Int ? Int(round(v)) :
                            T === Bool ? Bool(v) : T === Float64 ? Float64(v) : v)
        catch err
            @debug "plot setting ignored" field=f value=v err
        end
    end
    return s
end

function _settings_to_json(s::PlotSettings)
    return string(
        "{",
        "\"quantity\":\"",     string(s.quantity), "\",",
        "\"resid_method\":\"", string(s.resid_method), "\",",
        "\"y_unit\":\"",       string(s.y_unit),   "\",",
        "\"timespan_sec\":",   s.timespan_sec, ",",
        "\"show_grid\":",      s.show_grid ? "true" : "false", ",",
        "\"show_stats\":",     s.show_stats ? "true" : "false", ",",
        "\"paused\":",         s.paused    ? "true" : "false", ",",
        "\"auto_y\":",         s.auto_y    ? "true" : "false", ",",
        "\"y_min\":",          s.y_min, ",",
        "\"y_max\":",          s.y_max, ",",
        "\"ref_dN_m\":",       s.ref_dN_m, ",",
        "\"ref_dE_m\":",       s.ref_dE_m, ",",
        "\"ref_dU_m\":",       s.ref_dU_m, ",",
        "\"hp_window_s\":",    s.hp_window_s, ",",
        "\"kf_tau_s\":",       s.kf_tau_s, ",",
        "\"decimate\":",       s.decimate, ",",
        "\"decimate_antialias\":", s.decimate_antialias ? "true" : "false", ",",
        "\"web_refresh_s\":",  s.web_refresh_s, ",",
        "\"cause_view\":\"", string(s.cause_view), "\",",
        "\"show_causes\":", s.show_causes ? "true" : "false",
        "}"
    )
end

# Snapshot of a session for rendering off the data thread: the rolling
# histories are copied under stats.lock, everything else is shared. Draw
# functions only read `sess.stats.*`, `sess.profile.*` and `sess.bridge_state`.
_copy_stat_field(v::AbstractVector) = copy(v)
_copy_stat_field(v::AbstractDict) = Dict(k => (x isa AbstractVector ? copy(x) : x) for (k, x) in v)
_copy_stat_field(v) = v
# Record "epoch → live client" latency: the newest flushed record's epoch
# against the wall clock when miniSEED bytes just went out to a puller.
function _note_mseed_delivery!(sess)
    sess === nothing && return
    st = sess.stats
    isnan(st.mseed_last_flush_sod) && return
    wall = _wall_utc_sod()
    lat = _sod_diff(wall, st.mseed_last_flush_sod - GPS_UTC_LEAP_S)
    lock(st.lock) do
        h = st.mseed_delivery_history
        # one sample per second is plenty
        (!isempty(h) && abs(_sod_diff(wall, h[end][1])) < 1.0) && return
        push!(h, (wall, lat))
        while length(h) > 1200; popfirst!(h); end
    end
    return
end

function _session_view(sess)
    sess === nothing && return nothing
    st = sess.stats
    snap = lock(st.lock) do
        SessionStats(; (f => _copy_stat_field(getfield(st, f))
                        for f in fieldnames(SessionStats) if f !== :lock)...)
    end
    return (stats = snap, profile = sess.profile, bridge_state = sess.bridge_state)
end

# Auto-refreshing HTML index with a control toolbar. The toolbar GETs
# `/settings?…` whenever a control changes, which mutates the SAME
# PlotSettings struct the desktop GUI uses → two-way sync between the
# browser and the Gtk window, both directions, on the next 1 s refresh.
const _PLOT_WEB_INDEX_HTML = """
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GaiaSeis — Live Plot</title>
<style>
  body { font-family: system-ui, sans-serif; background:#f4f4f4; margin:0; padding:14px; color:#222; }
  h2   { margin:0 0 12px 0; }
  h3   { margin:0 0 6px 0; font-weight:500; color:#444; font-size:14px; }
  .toolbar { background:#fff; border:1px solid #ddd; border-radius:6px;
             padding:10px 12px; margin-bottom:14px; display:flex;
             flex-wrap:wrap; gap:14px; align-items:center; font-size:14px; }
  .toolbar label { display:inline-flex; gap:5px; align-items:center; }
  .toolbar select, .toolbar input[type=number] { font-size:14px; padding:3px 5px; }
  .grid{ display:grid; grid-template-columns:1fr 1fr; gap:14px; }
  .grid > div { background:#fff; border:1px solid #ddd; border-radius:6px; padding:10px; }
  .wide { grid-column: 1 / span 2; }
  img  { width:100%; height:auto; display:block; }
  .panel { background:#fff; border:1px solid #ddd; border-radius:6px;
            padding:10px 12px; margin-top:14px; }
  .mshead { display:flex; align-items:center; gap:10px; margin-bottom:8px; }
  .msdir { font-family:ui-monospace, Menlo, Consolas, monospace;
           font-size:12px; color:#777; overflow-wrap:anywhere; }
  .mstable { width:100%; border-collapse:collapse; font-size:13px; }
  .mstable th, .mstable td { text-align:left; padding:5px 8px;
                             border-bottom:1px solid #eee; }
  .mstable th { color:#666; font-weight:500; }
  .mstable td.num, .mstable th.num { text-align:right; }
  .mono { font-family:ui-monospace, Menlo, Consolas, monospace; }
  .live { background:#2e7d32; color:#fff; border-radius:3px;
          padding:1px 5px; font-size:11px; margin-left:6px; }
  .dl { display:inline-block; padding:3px 10px; border:1px solid #bbb;
        border-radius:4px; text-decoration:none; color:#123; background:#f7f7f7; }
  .dl:hover { background:#eaeaea; }
  .msempty { color:#888; font-style:italic; }
  .msnote { color:#777; font-size:12px; margin-top:8px; }
  .prof { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:15px;
           font-weight:600; color:#1b5e20; background:#e8f2e8;
           border:1px solid #c3d8c3; border-radius:5px; padding:2px 10px;
           vertical-align:2px; }
  .uptime { font-family:ui-monospace, Menlo, Consolas, monospace; font-size:13px;
            color:#333; background:#eef3ee; border:1px solid #cfd9cf;
            border-radius:4px; padding:2px 8px; }
  .csvrow { display:flex; flex-wrap:wrap; gap:10px; align-items:center; }
  .rogroups { display:flex; flex-wrap:wrap; gap:18px; }
  .rogroup { border:1px solid #e3e3e3; border-radius:6px; padding:8px 12px 10px;
             min-width:210px; background:#fafafa; }
  .rogroup h4 { margin:0 0 7px 0; font-size:12px; font-weight:600; color:#555;
                text-transform:uppercase; letter-spacing:.04em; }
  .rorow { display:flex; align-items:center; justify-content:space-between;
           gap:10px; font-size:13px; padding:2px 0; color:#666; }
  .rorow input[type=text] { width:74px; font-size:13px; padding:2px 5px;
                            text-align:right; font-family:ui-monospace, Menlo, Consolas, monospace; }
  .rogroup input:disabled, .rogroup select:disabled {
      background:#f0f0f0; color:#777; border:1px solid #d8d8d8; cursor:not-allowed; }
  .lockmsg { font-size:12.5px; color:#8a6d1f; background:#fdf6e3;
             border:1px solid #ecd9a0; border-radius:5px; padding:6px 10px;
             margin-bottom:10px; }
  .backdrop { position:fixed; inset:0; background:rgba(0,0,0,.45); display:none;
              align-items:center; justify-content:center; padding:20px; z-index:50; }
  .backdrop.on { display:flex; }
  .modal { background:#fff; border-radius:8px; max-width:820px; width:100%;
           max-height:85vh; display:flex; flex-direction:column; }
  .modal h3 { margin:0; padding:12px 16px; border-bottom:1px solid #e2e2e2; font-size:15px; }
  .modal .logos { display:flex; gap:18px; align-items:center; justify-content:center; padding:12px 16px 4px; }
  .modal .logos img { height:56px; width:auto; }
  .modal pre { margin:0; padding:16px; overflow:auto; white-space:pre-wrap;
               font-family:ui-monospace, Menlo, Consolas, monospace;
               font-size:12.5px; line-height:1.45; }
  .modal .foot { padding:10px 16px; border-top:1px solid #e2e2e2; text-align:right; }
  footer { margin-top:18px; color:#777; font-size:12px; }
</style></head>
<body>
<h2>GaiaSeis — Live Plot <span id="profname" class="prof">&mdash;</span> <span id="degrade" style="display:none;color:#c40000;font-size:13px;font-weight:600;margin-left:14px;vertical-align:middle"></span></h2>

<div class="toolbar">
  <label>Span:
    <select id="span">
      <option value="60">Last 1 min</option>
      <option value="300">Last 5 min</option>
      <option value="600">Last 10 min</option>
      <option value="1800">Last 30 min</option>
    </select>
  </label>
  <label>Qty:
    <select id="qty">
      <option value="pos">Displacement/epoch</option>
      <option value="vel">Velocity</option>
      <option value="acc">Acceleration</option>
    </select>
  </label>
  <label>Units:
    <select id="resid" title="statistic shown on the Residual panel">
      <option value="engine">Residual: engine's own σ̂</option>
      <option value="rms_w">Residual: weighted RMS</option>
      <option value="rms_u">Residual: unweighted RMS</option>
      <option value="sigma_va">Residual: smoothed σ̂ (300/30-epoch window)</option>
    </select>
    <select id="unit">
      <option value="mm">mm</option>
      <option value="cm">cm</option>
      <option value="m">m</option>
    </select>
  </label>
  <label id="cause_label">Cause:
    <select id="cause" title="Cause shown on the Causes panel: description, cases of this session, 24 h UTC timeline">
      <option value="missing">Missing epochs (caster)</option>
      <option value="skips">Skipped solves (catch-up)</option>
      <option value="rebaseline">Re-baselined after a hole</option>
      <option value="outlier">Amplitude outliers (flagged)</option>
      <option value="qualgate">Blanked by the quality gate</option>
      <option value="spike">Spikes passed to the output</option>
      <option value="satflag">Satellites flagged by residual</option>
      <option value="ephswitch">Ephemeris changeovers</option>
      <option value="partial">Epochs solved with a constellation missing</option>
      <option value="overload">CPU overload by other processes</option>
      <option value="outage">Stream drops / reconnects</option>
      <option value="alarm">Alarms</option>
      <option value="livecap">Live-stream cap reached</option>
    </select>
  </label>
  <label><input type="checkbox" id="grid">  Grid</label>
  <label><input type="checkbox" id="stats"> Stats</label>
  <label><input type="checkbox" id="auto_y" checked>  Auto Y</label>
  <label>Ymin: <input type="number" id="ymin" step="0.5" style="width:80px"></label>
  <label>Ymax: <input type="number" id="ymax" step="0.5" style="width:80px"></label>
  <label><input type="checkbox" id="paused"> Pause GUI</label>
  <span id="syncmsg" style="color:#888;font-size:12px"></span>
  <span style="flex:1"></span>
  <span id="config" class="uptime" title="constellations in use · processing mode (DFV = dual-frequency, SFV = single-frequency) · epoch rate"></span>
  <span id="uptime" class="uptime" title="time this streaming session has been running">session &mdash;</span>
  <button id="enginebtn" type="button" title="the displacement engine in use">About engine</button>
  <button id="aboutbtn" type="button">About</button>
</div>

<div class="grid">
  <div><h3 id="h_i1">Displacement per epoch (N/E/U), time axis UTC</h3><img id="i1"></div>
  <div><h3>Ground track (E–N)</h3><img id="i2"></div>
  <div><h3>Skyplot</h3><img id="i3"></div>
  <div><h3 id="h_i4">Residual σ̂</h3><img id="i4"><p id="resid_hint" style="color:#666;font-size:12px;margin:4px 0 0"></p></div>
  <div class="wide"><h3>#sats / DOP</h3><img id="i5"></div>
  <div class="wide"><h3>Latency / delays (arrival · solution · miniSEED on disk · missing epochs · solve time)</h3><img id="i6"></div>
  <div class="wide"><h3>Health (CPU per process, load, memory, disk, GC, delay chain, warnings)</h3><img id="i7"></div>
  <div class="wide" id="causes_div"><h3>Causes of missing epochs, skipped solves and spikes — pick one in the Cause dropdown</h3><img id="i8"></div>
</div>
<div class="panel">
  <div class="mshead">
    <h3 style="margin:0">miniSEED files</h3>
    <span id="msdir" class="msdir"></span>
    <span style="flex:1"></span>
    <label style="font-size:13px"><input type="checkbox" id="msauto" checked> auto</label>
    <button id="msrefresh" type="button">Refresh</button>
  </div>
  <table class="mstable">
    <thead><tr>
      <th>File</th><th>Chan</th><th class="num">Size</th>
      <th class="num">Records</th><th>Modified</th><th></th>
    </tr></thead>
    <tbody id="msbody"><tr><td colspan="6" class="msempty">loading&hellip;</td></tr></tbody>
  </table>
  <div class="msnote">
    Written to disk on the profile's miniSEED flush interval, so the newest
    samples may not be in the file yet. A file marked
    <span class="live">live</span> is still being appended to &mdash; it is a
    valid miniSEED file at every point, just short of the buffered tail.
    <b>Live &darr;</b> starts a download that never finishes &mdash; whole
    512-byte records are appended to your file as the writer flushes them.
  </div>
</div>

<div class="panel">
  <div class="mshead">
    <h3 style="margin:0">Web viewers</h3>
    <span id="viewcount" class="msdir"></span>
    <span style="flex:1"></span>
    <a class="dl" href="/logs/access.log" target="_blank">Access history</a>
  </div>
  <table class="mstable">
    <thead><tr>
      <th>Client</th><th>Browser</th><th>Connected since</th>
      <th class="num">For</th><th class="num">Requests</th>
      <th class="num">Data</th><th class="num">Idle</th>
    </tr></thead>
    <tbody id="viewbody"><tr><td colspan="7" class="msempty">loading&hellip;</td></tr></tbody>
  </table>
  <div class="msnote">
    A viewer drops off this list after <span id="viewidle">120</span> s of
    silence, and the session is written to the access history with its
    duration, request count and bytes served. The history is a plain text log
    at <span class="mono">logs/web_access.log</span> and survives restarts.
  </div>
</div>

<div class="panel">
  <div class="mshead"><h3 style="margin:0">Processing options</h3></div>
  <div class="lockmsg">
    Read-only here &mdash; these are controlled from the <b>GaiaSeis controller</b>
    (the desktop Plot window). Values below track the controller live.
  </div>
  <div class="rogroups">
    <div class="rogroup">
      <h4>Drift mitigation</h4>
      <div class="rorow"><label>HP filter (s)</label>
        <input type="text" id="ro_hp" disabled></div>
      <div class="rorow"><label>Kalman &tau; (s)</label>
        <input type="text" id="ro_kf" disabled></div>
      <div class="rorow"><label>Decimate 1/N</label>
        <input type="text" id="ro_dec" disabled></div>
      <div class="rorow"><label>Anti-alias (Lanczos)</label>
        <input type="checkbox" id="ro_aa" disabled></div>
    </div>
    <div class="rogroup">
      <h4>Outlier guard</h4>
      <div class="rorow"><label>MAD threshold</label>
        <input type="text" id="ro_mad" disabled></div>
      <div class="rorow"><label>Window (epochs)</label>
        <input type="text" id="ro_ow" disabled></div>
    </div>
    <div class="rogroup">
      <h4>Reference position</h4>
      <div class="rorow"><label>ref N (m)</label>
        <input type="text" id="ro_rn" disabled></div>
      <div class="rorow"><label>ref E (m)</label>
        <input type="text" id="ro_re" disabled></div>
      <div class="rorow"><label>ref U (m)</label>
        <input type="text" id="ro_ru" disabled></div>
    </div>
  </div>
  <div class="msnote">
    Auto-flush and the snapshot / reference-position actions exist only on the
    controller and have no read-only equivalent here.
  </div>
</div>

<div class="panel">
  <div class="mshead"><h3 style="margin:0">CSV export</h3></div>
  <div class="csvrow">
    <a class="dl" href="/csv/session.csv">Download session CSV</a>
    <a class="dl" id="livecsv" href="/csv/live.csv">Start live CSV &darr;</a>
    <span class="msnote" style="margin:0">
      The session CSV is a snapshot of the rolling buffer. The live CSV is a
      download that never finishes &mdash; rows are appended to the file as
      each epoch is solved. Stop it by cancelling the download in the browser.
    </span>
  </div>
  <div class="msnote">
    Columns: <span class="mono">iso_utc, sod, N_m, E_m, U_m, sigma_m, nsats, hdop, vdop</span>
  </div>
</div>

<div class="backdrop" id="aboutbox">
  <div class="modal">
    <h3>About GaiaSeis</h3>
    <div class="logos"><img src="/logo/GaiaSeis_icon" alt="GaiaSeis"><img src="/logo/CRL_logo" alt="CRL"><img src="/logo/DeformingGaia_logo" alt="Deforming Gaia Lab"></div>
    <pre id="abouttext">loading&hellip;</pre>
    <div class="foot"><button id="aboutclose" type="button">Close</button></div>
  </div>
</div>
<div class="backdrop" id="enginebox">
  <div class="modal">
    <h3>About engine</h3>
    <div class="logos"><img src="/logo/GaiaSeis_icon" alt="GaiaSeis"><img id="enginelablogo" src="/logo/DeformingGaia_logo" alt="Deforming Gaia Lab"></div>
    <pre id="enginetext">loading&hellip;</pre>
    <div class="foot"><button id="engineclose" type="button">Close</button></div>
  </div>
</div>

<footer>
  Auto-refreshes every 1 s. Changes here are mirrored back into the
  desktop Plot window (and vice-versa) on the next refresh.
</footer>

<script>
const IMGS=[['i1','/position.png'],['i2','/scatter.png'],
            ['i3','/skyplot.png'],['i4','/residual.png'],['i5','/dop.png'],
            ['i6','/metrics.png'],['i7','/health.png'],['i8','/causes.png']];
const CTRLS={qty:'qty', unit:'unit', span:'span', cause:'cause',
             grid:'grid', stats:'stats', paused:'paused',
             auto_y:'auto_y', ymin:'ymin', ymax:'ymax'};

// Conditional fetch per panel: the server answers 304 (no body) while its
// cached render is unchanged, so an idle poll costs a few hundred bytes.
const ETAGS = {}, URLS = {};
let imgsBusy = false;
async function refreshImgs(){
  if (imgsBusy) return;            // never let polls pile up on a slow link
  imgsBusy = true;
  try {
    await Promise.all(IMGS.map(async ([id, b]) => {
      const img0 = document.getElementById(id);
      if (!img0 || img0.offsetParent === null) return;      // panel hidden: do not fetch it
      const hdrs = ETAGS[id] ? {'If-None-Match': ETAGS[id]} : {};
      try {
        const r = await fetch(b + '?t=' + Date.now(), {cache: 'no-store', headers: hdrs});
        if (r.status !== 200) return;          // 304 → keep what is shown
        const et = r.headers.get('ETag'); if (et) ETAGS[id] = et;
        const url = URL.createObjectURL(await r.blob());
        const img = document.getElementById(id);
        img.onload = () => { if (URLS[id]) URL.revokeObjectURL(URLS[id]); URLS[id] = url; };
        img.src = url;
      } catch (e) { /* transient; next poll retries */ }
    }));
  } finally { imgsBusy = false; }
}

function applyServer(json){
  document.getElementById('qty').value    = json.quantity;
  const rs = document.getElementById('resid'); if (rs && json.resid_method) rs.value = json.resid_method;
  const RH = {engine: ["Residual σ̂ (engine's own)", "The figure the engine reports: PPPHVA's windowed σ̂, GaiaVario's weighted post-fit RMS of the epoch."],
              rms_w: ["Weighted post-fit RMS", "sqrt(Σ w·r² / Σ w) over the satellites kept in the fit, w = the engine's weights (sin² elevation in GaiaVario); each engine's own unit-weight figure."],
              rms_u: ["Unweighted post-fit RMS", "sqrt(Σ r² / n) over the satellites kept: the same formula for every engine, so it is the one to compare engines with (together with n)."],
              sigma_va: ["Smoothed σ̂ (300/30-epoch window)", "Cumulative mean of the weighted RMS for 300 epochs, then an exponential average (300 epochs up, 30 down) with each epoch capped at 3× the current value."]};
  const rh = RH[json.resid_method] || RH.engine;
  const h4 = document.getElementById('h_i4'); if (h4) h4.textContent = rh[0];
  const hint = document.getElementById('resid_hint'); if (hint) hint.textContent = rh[1];
  const h1 = document.getElementById('h_i1');
  if (h1) h1.textContent = (json.quantity === 'vel' ? 'Velocity' : json.quantity === 'acc' ? 'Acceleration' : 'Displacement per epoch') + ' (N/E/U), time axis UTC';
  document.getElementById('unit').value   = json.y_unit;
  if (json.cause_view) document.getElementById('cause').value = json.cause_view;
  // The "Web" tick beside the Cause dropdown in the plot window decides whether
  // the dropdown and the Causes panel appear here.
  const showC = json.show_causes !== false;
  const cl = document.getElementById('cause_label'), cd = document.getElementById('causes_div');
  if (cl) cl.style.display = showC ? '' : 'none';
  if (cd) cd.style.display = showC ? '' : 'none';
  document.getElementById('span').value   = String(json.timespan_sec);
  document.getElementById('grid').checked = !!json.show_grid;
  document.getElementById('stats').checked= !!json.show_stats;
  document.getElementById('auto_y').checked = !!json.auto_y;
  document.getElementById('paused').checked = !!json.paused;
  document.getElementById('ymin').value   = json.y_min;
  document.getElementById('ymax').value   = json.y_max;
  // Read-only mirrors of the controller-side options.
  const set = (id, v) => { const e = document.getElementById(id); if (e) e.value = v; };
  set('ro_hp',  json.hp_window_s > 0 ? json.hp_window_s : 'off');
  set('ro_kf',  json.kf_tau_s    > 0 ? json.kf_tau_s    : 'off');
  set('ro_dec', json.decimate    > 1 ? ('1/' + json.decimate) : 'off');
  set('ro_rn',  json.ref_dN_m);
  set('ro_re',  json.ref_dE_m);
  set('ro_ru',  json.ref_dU_m);
  const aa = document.getElementById('ro_aa');
  if (aa) aa.checked = !!json.decimate_antialias;
  if (json.web_refresh_s) imgPollMs = Math.max(200, json.web_refresh_s * 1000);
}

// Every 5 s the page pulls the plot settings from the server so the
// controls follow the GUI. A failed pull (server restarting, or busy) used
// to leave "sync error" on screen for good; now the note clears on the next
// successful pull and says what failed.
async function pullSettings(){
  try{
    const r = await fetch('/settings?t=' + Date.now(), {cache:'no-store'});
    if (r.ok) { applyServer(await r.json()); const m = document.getElementById('syncmsg'); if (m.textContent.indexOf('failed') >= 0) m.textContent = ''; }
    else document.getElementById('syncmsg').textContent = 'settings pull failed (HTTP ' + r.status + ')';
  }catch(e){ document.getElementById('syncmsg').textContent = 'settings pull failed (server unreachable)'; }
}

async function pushSettings(){
  const v = id => document.getElementById(id).value;
  const c = id => document.getElementById(id).checked ? '1' : '0';
  const q = new URLSearchParams({
    qty: v('qty'), resid: v('resid'), unit: v('unit'), span: v('span'), cause: v('cause'),
    grid: c('grid'), stats: c('stats'), paused: c('paused'),
    auto_y: c('auto_y'), ymin: v('ymin'), ymax: v('ymax')
  });
  try{
    await fetch('/settings?' + q.toString(), {cache:'no-store'});
    document.getElementById('syncmsg').textContent = 'synced ' + new Date().toLocaleTimeString();
    refreshImgs();
  }catch(e){ document.getElementById('syncmsg').textContent = 'push error'; }
}

// Bind every control to push on change.
for (const id of Object.values(CTRLS)){
  const el = document.getElementById(id);
  el && el.addEventListener('change', pushSettings);
}

// Profile names and caster hosts come from the user's TOML, so they are
// escaped rather than dropped straight into innerHTML.
function escapeHtml(t){
  return String(t).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',
                                              '"':'&quot;',"'":'&#39;'}[c]));
}

// ---- session uptime ----
function fmtDur(s){
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s/3600), m = Math.floor((s%3600)/60), x = s%60;
  return String(h).padStart(2,'0') + ':' + String(m).padStart(2,'0') + ':' +
         String(x).padStart(2,'0');
}
async function refreshStatus(){
  try{
    const r = await fetch('/status.json?t=' + Date.now(), {cache:'no-store'});
    if (!r.ok) return;
    const j = await r.json();
    const pn = document.getElementById('profname');
    pn.textContent = j.profile ? j.profile : '(no profile)';
    document.title = (j.profile ? j.profile + ' — ' : '') + 'GaiaSeis Live Plot';
    const setro = (id, v) => { const e = document.getElementById(id);
                               if (e) e.value = (v === undefined ? '—' : v); };
    setro('ro_mad', j.outlier_mad);
    setro('ro_ow',  j.outlier_window);
    const dg = document.getElementById('degrade');
    if (dg) { if (j.degradation) { dg.textContent = j.degradation; dg.style.display = 'inline'; } else { dg.style.display = 'none'; } }
    const cf = document.getElementById('config');
    if (cf) cf.textContent = j.running
        ? (j.constellations + ' \u00b7 ' + (j.engine || j.process_mode) +
           (j.input_interval_s ? ' \u00b7 ' + (1 / j.input_interval_s).toFixed(0) + ' Hz' : '') + '  \u00b7 ')
        : '';
    const el = document.getElementById('uptime');
    const miss = (j.input_epochs + j.input_missing) > 0
        ? ('  ·  missing from stream ' + j.input_missing + ' (' + j.input_missing_pct + ' %), last 60 s: ' + j.missing_last_60s)
        : '';
    el.textContent = j.running ? ('session ' + fmtDur(j.uptime_s) + miss) : 'not streaming';
    el.title = j.started_at ? ('started ' + j.started_at +
               '  |  profile ' + j.profile + '  |  reconnects ' + j.reconnects)
               : 'no session';
  }catch(e){}
}
refreshStatus();
setInterval(refreshStatus, 1000);

// ---- About ----
let aboutLoaded = false;
async function openAbout(){
  const box = document.getElementById('aboutbox');
  box.classList.add('on');
  if (!aboutLoaded){
    try{
      const r = await fetch('/about.txt', {cache:'no-store'});
      document.getElementById('abouttext').textContent =
        r.ok ? await r.text() : 'could not load About text';
      aboutLoaded = true;
    }catch(e){
      document.getElementById('abouttext').textContent = 'could not load About text';
    }
  }
}
document.getElementById('aboutbtn').addEventListener('click', openAbout);
async function openEngine(){
  const box = document.getElementById('enginebox');
  box.classList.add('on');
  try{
    const r = await fetch('/engine.txt', {cache:'no-store'});
    const t = r.ok ? await r.text() : 'could not load the engine description';
    document.getElementById('enginetext').textContent = t;
    document.getElementById('enginelablogo').hidden = !/GaiaVario/.test(t);
  }catch(e){ document.getElementById('enginetext').textContent = 'could not load the engine description'; }
}
document.getElementById('enginebtn').addEventListener('click', openEngine);
document.getElementById('resid').addEventListener('change', pushSettings);
document.getElementById('engineclose').addEventListener('click', () => document.getElementById('enginebox').classList.remove('on'));
document.getElementById('enginebox').addEventListener('click', (e) => { if (e.target.id === 'enginebox') e.target.classList.remove('on'); });
document.getElementById('aboutclose').addEventListener('click', function(){
  document.getElementById('aboutbox').classList.remove('on');
});
document.getElementById('aboutbox').addEventListener('click', function(e){
  if (e.target === this) this.classList.remove('on');
});
document.addEventListener('keydown', function(e){
  if (e.key === 'Escape') document.getElementById('aboutbox').classList.remove('on');
});

// ---- web viewers ----
function shortUA(ua){
  if (!ua) return '—';
  const known = ['Firefox','Edg','Chrome','Safari','curl','Wget','python-requests','HTTP.jl'];
  for (const k of known){
    const i = ua.indexOf(k);
    if (i >= 0){
      const tail = ua.slice(i + k.length + 1, i + k.length + 6);
      const ver = tail.split('.')[0];
      const name = (k === 'Edg') ? 'Edge' : k;
      const okv = ver.length > 0 && !isNaN(Number(ver));
      return okv ? (name + ' ' + ver) : name;
    }
  }
  return ua.length > 24 ? ua.slice(0,24) + '…' : ua;
}
async function refreshViewers(){
  try{
    const r = await fetch('/clients.json?t=' + Date.now(), {cache:'no-store'});
    if (!r.ok) return;
    const j = await r.json();
    document.getElementById('viewidle').textContent = j.idle_timeout_s;
    document.getElementById('viewcount').textContent =
      j.clients.length + ' now · ' + j.completed_sessions + ' finished this run';
    const b = document.getElementById('viewbody');
    if (!j.clients.length){
      b.innerHTML = '<tr><td colspan="7" class="msempty">no viewers connected</td></tr>';
      return;
    }
    let h = '';
    for (const c of j.clients){
      h += '<tr><td class="mono">' + escapeHtml(c.ip) + '</td>' +
           '<td>' + escapeHtml(shortUA(c.ua)) + '</td>' +
           '<td>' + escapeHtml(c.first_seen) + '</td>' +
           '<td class="num">' + fmtDur(c.connected_s) + '</td>' +
           '<td class="num">' + c.requests + '</td>' +
           '<td class="num">' + fmtSize(c.bytes) + '</td>' +
           '<td class="num">' + c.idle_s.toFixed(1) + ' s</td></tr>';
    }
    b.innerHTML = h;
  }catch(e){}
}
refreshViewers();
setInterval(refreshViewers, 3000);

// ---- miniSEED panel ----
function fmtSize(n){
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n/1024).toFixed(1) + ' KB';
  return (n/1048576).toFixed(2) + ' MB';
}
// NET.STA.LOC.CHA.D.YYYY.DOY -> CHA
function chanOf(name){
  const p = name.split('.');
  return p.length >= 4 ? p[3] : '';
}
async function refreshMseed(){
  try{
    const r = await fetch('/mseed.json?t=' + Date.now(), {cache:'no-store'});
    if (!r.ok) return;
    const j = await r.json();
    document.getElementById('msdir').textContent =
      j.dir ? j.dir : '(no miniSEED directory set on this profile)';
    const b = document.getElementById('msbody');
    if (!j.files || !j.files.length){
      b.innerHTML = '<tr><td colspan="6" class="msempty">' +
        (j.exists ? 'no miniSEED files yet' : 'directory does not exist') +
        '</td></tr>';
      return;
    }
    let h = '';
    for (const f of j.files){
      h += '<tr><td class="mono">' + f.name +
           (f.live ? ' <span class="live">live</span>' : '') + '</td>' +
           '<td class="mono">' + chanOf(f.name) + '</td>' +
           '<td class="num">' + fmtSize(f.size) + '</td>' +
           '<td class="num">' + f.records + '</td>' +
           '<td>' + new Date(f.mtime * 1000).toLocaleString() + '</td>' +
           '<td><a class="dl" href="/mseed/download?f=' +
           encodeURIComponent(f.name) + '">Download</a>' +
           (f.live ? ' <a class="dl" href="/mseed/live?f=' +
                     encodeURIComponent(f.name) +
                     '" title="keeps downloading, appending records as they are written"'
                     + '>Live &darr;</a>' : '') +
           '</td></tr>';
    }
    b.innerHTML = h;
  }catch(e){ /* keep the last good listing on screen */ }
}
document.getElementById('msrefresh').addEventListener('click', refreshMseed);
refreshMseed();
setInterval(function(){
  if (document.getElementById('msauto').checked) refreshMseed();
}, 5000);

// Initial bootstrap + cadence: pull settings every 5 s (so GUI-side
// changes show up in our toolbar), refresh images every 1 s.
pullSettings();
setInterval(pullSettings, 5000);
let imgPollMs = 1000;
async function imgLoop(){ try { await refreshImgs(); } catch(e) {} setTimeout(imgLoop, imgPollMs); }
imgLoop();
</script>
</body></html>
"""

# ---- miniSEED browser ----
# The panel lists whatever is in the session's miniSEED output directory and
# hands each file back over HTTP. The writers are the authority on where that
# is (the bridge builds them from the profile and never rewrites `base_dir`);
# the profile field is the fallback so the panel still lists the previous
# run's files before a new stream has created any writer.
function _mseed_dir_for(sess)
    sess === nothing && return ""
    try
        ws = sess.mseed_writers
        ws === nothing || return abspath(ws.N.base_dir)
    catch err
        @debug "mseed writer dir lookup failed" err
    end
    try
        d = sess.profile.miniseed_mseed_dir
        return isempty(d) ? "" : abspath(d)
    catch err
        @debug "mseed profile dir lookup failed" err
        return ""
    end
end

# Basenames of the files the writers currently hold open — shown as "live"
# so it is obvious which ones are still growing.
function _mseed_live_names(sess)
    live = Set{String}()
    sess === nothing && return live
    try
        ws = sess.mseed_writers
        ws === nothing && return live
        for w in (ws.N, ws.E, ws.Z)
            w.io === nothing && continue
            push!(live, basename(_mseed_path(w, w.current_year, w.current_doy)))
        end
    catch err
        @debug "live mseed path lookup failed" err
    end
    return live
end

_json_escape(s::AbstractString) = replace(String(s),
    '\\' => "\\\\", '"' => "\\\"",
    '\n' => "\\n", '\r' => "\\r", '\t' => "\\t")

# Directory listing as JSON. Hand-rolled to match `_settings_to_json` — the
# package has no JSON dependency and this is not worth adding one for.
function _mseed_list_json(sess)
    dir = _mseed_dir_for(sess)
    if isempty(dir) || !isdir(dir)
        return string("{\"dir\":\"", _json_escape(dir), "\",",
                      "\"exists\":false,\"files\":[]}")
    end
    live = _mseed_live_names(sess)
    entries = String[]
    for name in sort(readdir(dir))
        startswith(name, ".") && continue
        full = joinpath(dir, name)
        isfile(full) || continue
        sz = 0
        mt = 0.0
        try
            sz = filesize(full)
            mt = mtime(full)
        catch err
            @debug "stat failed" full err
        end
        push!(entries, string(
            "{\"name\":\"", _json_escape(name), "\"",
            ",\"size\":", sz,
            ",\"mtime\":", round(Int, mt),
            ",\"records\":", sz ÷ MSEED_RECORD_LEN,
            ",\"live\":", (name in live) ? "true" : "false",
            "}"))
    end
    return string("{\"dir\":\"", _json_escape(dir), "\",",
                  "\"exists\":true,\"files\":[", join(entries, ","), "]}")
end

# Resolve `?f=<name>` against the miniSEED directory, refusing anything that
# is not a bare basename already present in the listing. Shared by the plain
# download and the live tail so both enforce the identical containment rule.
# Returns the full path, or an HTTP.Response describing the refusal.
function _mseed_resolve(sess, query::AbstractString)
    dir = _mseed_dir_for(sess)
    (isempty(dir) || !isdir(dir)) &&
        return HTTP.Response(404, "no miniSEED directory configured")
    name = ""
    for pair in split(query, '&')
        kv = split(pair, '='; limit = 2)
        length(kv) == 2 || continue
        String(kv[1]) == "f" || continue
        name = try; HTTP.unescapeuri(String(kv[2])); catch; ""; end
    end
    isempty(name) && return HTTP.Response(400, "missing ?f=<filename>")
    name == basename(name) || return HTTP.Response(400, "bad filename")
    (name in readdir(dir)) || return HTTP.Response(404, "no such file: $name")
    full = joinpath(dir, name)
    isfile(full) || return HTTP.Response(404, "not a file: $name")
    return (full, name)
end

# A miniSEED download that never finishes: send what is on disk, then keep
# appending as the writer flushes new records. The browser writes a growing
# .mseed file the whole time the stream runs.
#
# Only whole 512-byte records are ever emitted, so the partial file on the
# client is a VALID miniSEED file at every instant — never a torn record.
#
# Like the live CSV, the producer cannot observe the client hanging up, so it
# stops on an undrained backlog or the hard time cap.
# Upper bound on concurrently served live streams (CSV + miniSEED). Each
# one is a producer task plus buffers; beyond this a leak or a runaway
# client would start to starve the data thread.
const _LIVE_MAX = 8

function _mseed_live_response(sess, query::AbstractString)
    resolved = _mseed_resolve(sess, query)
    resolved isa HTTP.Response && return resolved
    _LIVE_TASKS[] >= _LIVE_MAX &&
        (_cause_event!(:livecap, 1, "/mseed/live refused"); return HTTP.Response(503, "too many live streams ($(_LIVE_TASKS[])); retry later"))
    full, name = resolved
    # Optional `from=<bytes>`: resume at that offset (rounded down to a
    # record) instead of re-sending the whole file. tools/mseed_http_puller.py
    # uses it; a client without it still gets the file from byte 0.
    from = 0
    for pair in split(query, '&')
        kv = split(pair, '='; limit = 2)
        length(kv) == 2 && String(kv[1]) == "from" || continue
        v = tryparse(Int, String(kv[2])); v === nothing && continue
        from = (max(v, 0) ÷ MSEED_RECORD_LEN) * MSEED_RECORD_LEN
    end
    io = Base.BufferStream()
    # Worker pool, not @async: the HTTP handler runs on the interactive
    # thread, which with `-t auto` is thread 1 — the Gtk loop, decoder and
    # solver. Six 200 MB replays running there tripled the solve time.
    Threads.@spawn begin
        t0 = time()
        pos = min(from, isfile(full) ? filesize(full) : 0)
        stuck = Ref(0.0)
        Threads.atomic_add!(_LIVE_TASKS, 1)
        try
            while true
                if isfile(full)
                    sz = filesize(full)
                    # Round down to a record boundary.
                    avail = ((sz - pos) ÷ MSEED_RECORD_LEN) * MSEED_RECORD_LEN
                    if avail > 0
                        open(full, "r") do fh
                            seek(fh, pos)
                            remaining = avail
                            while remaining > 0 && isopen(io)
                                if bytesavailable(io) > _LIVE_CHUNK_HIGHWATER
                                    sleep(0.02); continue      # client still draining
                                end
                                n = min(remaining, _LIVE_CHUNK)
                                write(io, read(fh, n)); flush(io)
                                remaining -= n; pos += n
                            end
                        end
                    end
                end
                _live_stream_healthy!(io, stuck, t0) || break
                sleep(1.0)
            end
        catch err
            @debug "live miniSEED producer ended" err
        finally
            Threads.atomic_sub!(_LIVE_TASKS, 1)
            try; close(io); catch; end
        end
    end
    return HTTP.Response(200,
        ["Content-Type" => "application/vnd.fdsn.mseed",
         "Content-Disposition" => "attachment; filename=\"$(name)\"",
         "Cache-Control" => "no-store"];
        body = io)
end

# Serve one file as a download. This server binds 0.0.0.0, so the filename
# from the query string is untrusted: we accept only a bare basename that is
# actually present in the directory listing, which makes `f=../../etc/passwd`
# (and any symlink or absolute path) impossible to express.
function _mseed_download_response(sess, query::AbstractString)
    resolved = _mseed_resolve(sess, query)
    resolved isa HTTP.Response && return resolved
    full, name = resolved
    bytes = read(full)
    return HTTP.Response(200,
        ["Content-Type" => "application/vnd.fdsn.mseed",
         "Content-Disposition" => "attachment; filename=\"$name\"",
         "Content-Length" => string(length(bytes)),
         "Cache-Control" => "no-store"],
        bytes)
end

# ---- Session status (uptime banner) ----
# "Missing epochs: 172 of 1985 (8.7 %) · last 60 s: 6" — shared by the main
# window, the Plot window toolbar and the panel corner text.
function _missing_summary(st; short::Bool = false)
    tot = st.input_epochs + st.input_missing
    tot == 0 && return short ? "—" : "Missing epochs: —"
    pct = 100.0 * st.input_missing / tot
    short && return @sprintf("%d/%d (%.1f %%)", st.input_missing, tot, pct)
    last60 = _missing_last(st, 60.0)
    @sprintf("Missing epochs: %d of %d (%.1f %%) · last 60 s: %d", st.input_missing, tot, pct, last60)
end
function _missing_last(st, secs::Float64)
    isnan(st.input_last_sod) && return 0
    n = 0
    for (gs, nm) in st.input_gaps
        age = st.input_last_sod - gs; age < 0 && (age += 86400.0)
        age <= secs && (n += nm)
    end
    n
end

function _status_json(sess)
    if sess === nothing
        return "{\"running\":false,\"uptime_s\":0,\"started_at\":\"\",\"profile\":\"\",\"constellations\":\"\",\"process_mode\":\"\"}"
    end
    st = sess.stats
    pr = sess.profile
    constellations = join([n for (n, on) in (("GPS", pr.enable_gps), ("GLO", pr.enable_glo),
                                             ("GAL", pr.enable_gal), ("BDS", pr.enable_bds)) if on], "+")
    up = st.started_at == DateTime(0) ? 0.0 :
         Dates.value(Dates.now() - st.started_at) / 1000
    return string("{",
        "\"running\":",   isrunning(sess) ? "true" : "false", ",",
        "\"uptime_s\":",  round(up; digits = 1), ",",
        "\"started_at\":\"", st.started_at == DateTime(0) ? "" :
                              Dates.format(st.started_at, "yyyy-mm-dd HH:MM:SS"), "\",",
        "\"profile\":\"",     _json_escape(sess.profile.name), "\",",
        "\"constellations\":\"", constellations, "\",",
        "\"process_mode\":\"", pr.process_mode, "\",",
        "\"engine\":\"", _json_escape(engine_label(pr)), "\",",
        "\"engine_info\":\"", _json_escape(sess.bridge_state === nothing ? "" : sess.bridge_state.engine_info), "\",",
        "\"nsat\":",      st.last_epoch_nsat, ",",
        "\"bytes\":",     st.bytes_received, ",",
        "\"reconnects\":", st.reconnects_obs, ",",
        # Pipeline-health counters, so a missing-epoch complaint can be
        # attributed without a restart: backpressure skips = thread 1 was
        # busy (>1 enabled epoch per read batch); outliers = guard blanks.
        "\"epochs_skipped_backpressure\":", st.epochs_skipped_backpressure, ",",
        "\"epochs_caught_up\":", st.epochs_caught_up, ",",
        "\"solve_ms_ema\":", isnan(st.solve_ms_ema) ? "null" : round(st.solve_ms_ema; digits = 1), ",",
        # Receiver/caster-side completeness (see MANUAL 11.8a): holes in the
        # primary constellation's epoch sequence, counted before processing.
        "\"input_epochs\":",   st.input_epochs, ",",
        "\"input_missing\":",  st.input_missing, ",",
        "\"input_missing_pct\":", round(100.0 * st.input_missing / max(st.input_epochs + st.input_missing, 1); digits = 2), ",",
        "\"missing_last_60s\":", _missing_last(st, 60.0), ",",
        "\"epochs_rebaselined\":", st.epochs_rebaselined, ",",
        "\"max_gap_epochs\":", sess.profile.max_gap_epochs, ",",
        "\"input_interval_s\":", isnan(st.input_interval_s) ? "null" : st.input_interval_s, ",",
        "\"outliers_rejected\":", sess.bridge_state === nothing ? 0 :
                                    sess.bridge_state.outlier_total, ",",
        "\"outlier_mad\":",    sess.profile.outlier_mad_threshold, ",",
        "\"outlier_window\":", sess.profile.outlier_window, ",",
        "\"sats_used\":", sess.bridge_state === nothing ? 0 : sess.bridge_state.sats_used, ",",
        "\"constellations_used\":\"", sess.bridge_state === nothing ? "" : sess.bridge_state.cons_used, "\",",
        "\"ssr_mode\":\"", _ssr_mode(sess), "\",",
        "\"ssr_sats\":\"", _ssr_sats(sess), "\",",
        "\"alarms\":[", join(("\"$(_json_escape(t))\"" for (_, t) in _alarms(sess)), ","), "],",
        "\"eph_changes\":", sess.bridge_state === nothing ? 0 : sess.bridge_state.eph_changes, ",",
        "\"eph_rebuilds\":", sess.bridge_state === nothing ? 0 : sess.bridge_state.eph_rebuilds, ",",
        "\"qgate_blanked\":", sess.bridge_state === nothing ? 0 :
                                    sess.bridge_state.qgate.total, ",",
        "\"qgate_by\":", sess.bridge_state === nothing ? "{}" :
            string("{", join(["\"$(k)\":$(v)" for (k, v) in sort!(collect(sess.bridge_state.qgate.by); by = first)], ","), "}"), ",",
        "\"satflag_epochs\":", sess.bridge_state === nothing ? 0 :
                                    sess.bridge_state.satflag.epochs_flagged, ",",
        "\"satflag_sat_flags\":", sess.bridge_state === nothing ? 0 :
                                    sess.bridge_state.satflag.sat_flags, ",",
        # Memory forensics: Julia-heap live bytes vs process RSS tells whether
        # growth is uncollected Julia garbage or C-side (Cairo/GTK/libuv).
        "\"gc_live_mb\":",     round(Base.gc_live_bytes() / 1e6; digits = 1), ",",
        "\"gc_full_sweeps\":", Base.gc_num().full_sweep, ",",
        "\"gc_pause_ms\":",    round(Base.gc_num().total_time / 1e6; digits = 1), ",",
        "\"maxrss_mb\":",      round(Sys.maxrss() / 1e6; digits = 1), ",",
        "\"live_stream_tasks\":", _LIVE_TASKS[], ",",
        (_DEGRADE_SESS[] = sess; _health_json_fields()),
        "}")
end

# ---- CSV export ----
# Same quantities the file sink writes, rebuilt from the rolling history so
# the browser can pull them without touching the sink file.
const _CSV_HEADER = "iso_utc,sod,N_m,E_m,U_m,sigma_m,nsats,hdop,vdop"

function _csv_row(sess, sod::Float64, N::Float64, E::Float64, U::Float64)
    st = sess.stats
    sigma = NaN
    for i in length(st.residual_history):-1:1
        t, v = st.residual_history[i]
        if t == sod; sigma = v; break; end
        t < sod && break
    end
    nsat = 0; hd = NaN; vd = NaN
    for i in length(st.dop_history):-1:1
        rec = st.dop_history[i]
        if rec[1] == sod
            nsat = round(Int, rec[2]); hd = rec[5]; vd = rec[6]; break
        end
        rec[1] < sod && break
    end
    dt = _stream_datetime(sod, st.last_obs_byte_at;
                          gps_week = st.gps_week, obs_tow_s = st.last_obs_stream_tow)
    iso = dt === nothing ? "" : Dates.format(dt, "yyyy-mm-ddTHH:MM:SS.sss") * "Z"
    f(x) = isnan(x) ? "" : string(round(x; digits = 6))
    return string(iso, ",", round(sod; digits = 3), ",",
                  f(N), ",", f(E), ",", f(U), ",", f(sigma), ",",
                  nsat, ",", f(hd), ",", f(vd))
end

# Everything currently in the rolling buffer, as one finished file.
function _csv_snapshot(sess)
    io = IOBuffer()
    println(io, _CSV_HEADER)
    if sess !== nothing
        for (sod, N, E, U) in copy(sess.stats.displacement_history)
            println(io, _csv_row(sess, sod, N, E, U))
        end
    end
    return String(take!(io))
end

# A response whose body never ends: emit the buffer so far, then append each
# new epoch as the bridge produces it. HTTP.jl streams a `BufferStream` body
# incrementally, so the browser writes rows to the file as they arrive.
#
# The producer cannot see the client hang up (it writes into the buffer, not
# the socket), so it stops when the consumer clearly is not draining and
# after a hard time cap — otherwise an abandoned download would grow in
# memory forever.
const _CSV_LIVE_MAX_BACKLOG = 1_000_000     # bytes undrained
const _CSV_LIVE_MAX_SECONDS = 24 * 3600
const _LIVE_STUCK_GRACE     = 120.0         # seconds over-cap before giving up
# /mseed/live sends the day file in chunks and waits for the client to drain
# the buffer before reading more. Reading the whole file at once allocated
# the entire day file per request (177 MB per channel at 10 Hz / flush 0) —
# hundreds of MB of transient memory per poll from a re-connecting consumer.
const _LIVE_CHUNK           = 256 << 10     # 256 KiB (multiple of 512)
const _LIVE_CHUNK_HIGHWATER = 512 << 10     # pause reading above this backlog
# Live producer tasks currently alive (both endpoints). Exposed in
# /status.json so an abandoned-stream leak shows up as a growing number.
const _LIVE_TASKS = Threads.Atomic{Int}(0)

# Should a live stream keep producing?
#
# The producer writes into a BufferStream, not the socket, so it cannot see
# the client hang up; an abandoned download would otherwise grow in memory
# forever. But a single over-cap reading is NOT evidence of that: the initial
# catch-up send legitimately parks megabytes in the buffer before HTTP.jl has
# drained any of it. Only a backlog that STAYS over the cap means nobody is
# reading. `stuck_since` holds when it first went over (0.0 = draining fine).
function _live_stream_healthy!(io, stuck_since::Ref{Float64}, t0::Float64)
    # The HTTP wrapper closes the BufferStream when the client hangs up; a
    # producer that has nothing to write (idle file) would otherwise never
    # notice and idle for up to _CSV_LIVE_MAX_SECONDS.
    isopen(io) || return false
    time() - t0 > _CSV_LIVE_MAX_SECONDS && return false
    if bytesavailable(io) > _CSV_LIVE_MAX_BACKLOG
        stuck_since[] == 0.0 && (stuck_since[] = time())
        return time() - stuck_since[] < _LIVE_STUCK_GRACE
    end
    stuck_since[] = 0.0
    return true
end

function _csv_live_response(state)
    _LIVE_TASKS[] >= _LIVE_MAX &&
        (_cause_event!(:livecap, 1, "/metrics/live refused"); return HTTP.Response(503, "too many live streams ($(_LIVE_TASKS[])); retry later"))
    io = Base.BufferStream()
    Threads.@spawn begin
        t0 = time()
        stuck = Ref(0.0)
        Threads.atomic_add!(_LIVE_TASKS, 1)
        try
            write(io, _CSV_HEADER, "\n"); flush(io)
            last_sod = -Inf
            while true
                sess = state[:session]
                if sess !== nothing
                    emitted = false
                    for (sod, N, E, U) in copy(sess.stats.displacement_history)
                        sod > last_sod || continue
                        write(io, _csv_row(sess, sod, N, E, U), "\n")
                        last_sod = sod
                        emitted = true
                    end
                    emitted && flush(io)
                end
                _live_stream_healthy!(io, stuck, t0) || break
                sleep(0.5)
            end
        catch err
            @debug "live CSV producer ended" err
        finally
            Threads.atomic_sub!(_LIVE_TASKS, 1)
            try; close(io); catch; end
        end
    end
    return HTTP.Response(200,
        ["Content-Type" => "text/csv; charset=utf-8",
         "Content-Disposition" => "attachment; filename=\"gaiaseis_live.csv\"",
         "Cache-Control" => "no-store"];
        body = io)
end

# ---- Web access tracking ----
# Who is looking at the web interface right now, and a durable history of who
# has looked at it before.
#
# The page polls ~6 requests a second per viewer, so logging every request
# would produce half a million lines a day and bury the useful signal. We log
# VIEWER SESSIONS instead: one line when a browser first appears, one when it
# has been silent for `_WEB_IDLE_S`, carrying duration, request count and
# bytes. Live per-request state is kept in memory for the viewers panel.
const _WEB_IDLE_S = 120.0

mutable struct WebClient
    ip::String
    ua::String
    first_seen::Float64
    last_seen::Float64
    requests::Int
    bytes::Int
    # Request count per path (query stripped), so a client hammering one
    # endpoint (e.g. a curl loop on /mseed/live) is visible in /clients.json.
    paths::Dict{String,Int}
end

struct WebAccessTracker
    clients::Dict{String,WebClient}
    lock::ReentrantLock
    logpath::String
    sessions::Base.RefValue{Int}      # completed sessions this run
    active::Base.RefValue{Bool}       # cleared by the server's on_shutdown
end

# Live trackers, so a shutdown that never reaches the server's `on_shutdown`
# (an `exit`, Ctrl-C or `kill`) still closes every open viewer session in the
# log instead of leaving a dangling CONNECT.
const _WEB_TRACKERS = Set{Any}()
const _WEB_TRACKERS_LOCK = ReentrantLock()

function _close_open_web_sessions!(tr, note::AbstractString)
    lock(tr.lock) do
        for (ip, c) in collect(tr.clients)
            _web_log!(tr, string(_web_now_iso(), "  DISCONNECT  ", rpad(ip, 16),
                                 "  dur=", round(Int, c.last_seen - c.first_seen), "s",
                                 "  reqs=", c.requests, "  bytes=", c.bytes, "  ", note))
        end
        empty!(tr.clients)
    end
    return nothing
end

# Called from the atexit hook in session.jl.
function _flush_web_trackers!()
    for tr in lock(() -> collect(_WEB_TRACKERS), _WEB_TRACKERS_LOCK)
        try
            _close_open_web_sessions!(tr, "(shutdown)")
        catch err
            @debug "web tracker flush failed" err
        end
    end
    return nothing
end

function WebAccessTracker()
    dir = try; logs_dir(); catch; "logs"; end
    try; mkpath(dir); catch err; @debug "web access log dir failed" err; end
    tr = WebAccessTracker(Dict{String,WebClient}(), ReentrantLock(),
                          joinpath(dir, "web_access.log"), Ref(0), Ref(true))
    lock(() -> push!(_WEB_TRACKERS, tr), _WEB_TRACKERS_LOCK)
    return tr
end

_web_now_iso() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

function _web_log!(tr::WebAccessTracker, line::AbstractString)
    try
        open(tr.logpath, "a") do io
            println(io, line)
        end
    catch err
        @debug "web access log write failed" err
    end
end

# Record one request. Returns nothing; never throws into the handler.
function _web_record!(tr::WebAccessTracker, ip::AbstractString,
                      ua::AbstractString, nbytes::Integer, path::AbstractString = "")
    try
        now = time()
        lock(tr.lock) do
            c = get(tr.clients, ip, nothing)
            if c === nothing
                c = WebClient(String(ip), String(ua), now, now, 0, 0, Dict{String,Int}())
                tr.clients[ip] = c
                _web_log!(tr, string(_web_now_iso(), "  CONNECT     ", rpad(ip, 16),
                                     "  ua=\"", ua, "\""))
            end
            c.last_seen = now
            c.requests += 1
            c.bytes += Int(nbytes)
            isempty(path) || (c.paths[path] = get(c.paths, path, 0) + 1)
            isempty(c.ua) && (c.ua = String(ua))
        end
    catch err
        @debug "web access record failed" err
    end
    return nothing
end

# Retire viewers that have gone quiet, writing their session line.
function _web_expire!(tr::WebAccessTracker)
    now = time()
    lock(tr.lock) do
        for (ip, c) in collect(tr.clients)
            if now - c.last_seen > _WEB_IDLE_S
                dur = c.last_seen - c.first_seen
                _web_log!(tr, string(_web_now_iso(), "  DISCONNECT  ", rpad(ip, 16),
                                     "  dur=", round(Int, dur), "s",
                                     "  reqs=", c.requests,
                                     "  bytes=", c.bytes))
                delete!(tr.clients, ip)
                tr.sessions[] += 1
            end
        end
    end
    return nothing
end

# Path without the query string — the key used for per-client path counts.
function _req_path(req)
    t = String(req.target); q = findfirst('?', t)
    return q === nothing ? t : t[1:q-1]
end

function _clients_json(tr::WebAccessTracker)
    now = time()
    parts = String[]
    total_sessions = 0
    lock(tr.lock) do
        total_sessions = tr.sessions[]
        for (ip, c) in sort(collect(tr.clients), by = x -> x[2].first_seen)
            push!(parts, string("{",
                "\"ip\":\"", _json_escape(ip), "\",",
                "\"ua\":\"", _json_escape(c.ua), "\",",
                "\"first_seen\":\"",
                    Dates.format(Dates.unix2datetime(c.first_seen), "yyyy-mm-dd HH:MM:SS"), "\",",
                "\"connected_s\":", round(now - c.first_seen; digits = 1), ",",
                "\"idle_s\":",      round(now - c.last_seen;  digits = 1), ",",
                "\"requests\":",    c.requests, ",",
                "\"bytes\":",       c.bytes, ",",
                "\"paths\":{", join([string("\"", _json_escape(k), "\":", v)
                                     for (k, v) in sort(collect(c.paths), by = x -> -x[2])], ","), "}",
                "}"))
        end
    end
    return string("{\"idle_timeout_s\":", _WEB_IDLE_S,
                  ",\"completed_sessions\":", total_sessions,
                  ",\"clients\":[", join(parts, ","), "]}")
end

# Start an HTTP.serve! on `port`, returning the server handle. The handler
# closes over `state` (for the live `session`) and `settings`, so any GUI
# toolbar change is reflected on the next browser refresh.
# How long a rendered panel may be reused. The page refreshes images once a
# second and asks for all five at once, so without this a single tick can
# re-render the same frame several times over.
# Panels are rendered by a worker thread every `settings.web_refresh_s`
# seconds (while a viewer has asked for one in the last 15 s) from a locked
# snapshot of the session histories; the HTTP handler only serves the cache.
# Thread 1 (Gtk loop, decoder, solver) never renders for the web.
const _PANEL_IDLE_STOP_S = 15.0

function _start_plot_web_server(port::Int, state, settings::PlotSettings;
                                 W::Int = 880, H::Int = 600)
    # path -> (rendered_at, settings_json, bytes, etag). Keyed on the settings
    # JSON as well as the clock so a toolbar change is never served from
    # cache. The ETag identifies one render; a browser that still holds it
    # gets a bodiless 304 instead of the same PNG again (a viewer polling
    # five panels every second pulled ~150 MB per 10 min before, 2026-09-11).
    panel_cache = Dict{String,Tuple{Float64,String,Vector{UInt8},String}}()
    cache_lock  = ReentrantLock()
    tracker     = WebAccessTracker()
    last_panel_request = Ref(0.0)
    panel_route = Dict(
        "/position.png" => _draw_neu_stacked,
        "/scatter.png"  => _draw_en_scatter,
        "/skyplot.png"  => _draw_skyplot,
        "/residual.png" => _draw_residual,
        "/dop.png"      => _draw_nsat_dop,
        "/metrics.png"  => _draw_metrics,
        "/health.png"   => _draw_health,
        "/causes.png"   => _draw_causes,
    )
    _start_sys_sampler!()
    # ---- render worker (own thread) ----
    Threads.@spawn begin
        while tracker.active[]
            try
                if time() - last_panel_request[] < _PANEL_IDLE_STOP_S
                    view = _session_view(state[:session])
                    sig  = _settings_to_json(settings)
                    for (path, drawfn) in panel_route
                        bytes = _render_panel_to_png_bytes(drawfn, W, H, view, settings)
                        t_r   = time()
                        etag  = string('"', round(Int, t_r * 1000), '-', hash(sig) % 100_000, '"')
                        lock(cache_lock) do
                            panel_cache[path] = (t_r, sig, bytes, etag)
                        end
                    end
                end
            catch err
                @debug "web render worker failed" err
            end
            sleep(clamp(settings.web_refresh_s, 0.2, 60.0))
        end
    end
    handler = function(req)
        target = req.target
        # Split path / query — we use the query both for cache-busting and
        # (on /settings) for client-driven updates.
        qpos = findfirst('?', target)
        path  = qpos === nothing ? target : target[1:qpos-1]
        query = qpos === nothing ? ""     : target[qpos+1:end]
        if path == "/" || path == "/index.html"
            return HTTP.Response(200,
                ["Content-Type" => "text/html; charset=utf-8",
                 "Cache-Control" => "no-store"],
                _PLOT_WEB_INDEX_HTML)
        elseif path == "/settings"
            # Apply any updates carried in the query string, then return
            # the current state as JSON. Used by the browser toolbar to
            # both push changes and bootstrap form values.
            !isempty(query) && _apply_query_to_settings!(settings, query)
            return HTTP.Response(200,
                ["Content-Type" => "application/json",
                 "Cache-Control" => "no-store"],
                _settings_to_json(settings))
        elseif path == "/clients.json"
            _web_expire!(tracker)
            return HTTP.Response(200,
                ["Content-Type" => "application/json",
                 "Cache-Control" => "no-store"],
                _clients_json(tracker))
        elseif path == "/logs/access.log"
            # Fixed path, no user input — the viewer-session history.
            if !isfile(tracker.logpath)
                return HTTP.Response(200,
                    ["Content-Type" => "text/plain; charset=utf-8"],
                    "# no web access recorded yet\n")
            end
            return HTTP.Response(200,
                ["Content-Type" => "text/plain; charset=utf-8",
                 "Cache-Control" => "no-store"],
                read(tracker.logpath))
        elseif path == "/engine.txt"
            return HTTP.Response(200,
                ["Content-Type" => "text/plain; charset=utf-8",
                 "Cache-Control" => "no-store"],
                engine_about_text(state[:session]))
        elseif path == "/about.txt"
            return HTTP.Response(200,
                ["Content-Type" => "text/plain; charset=utf-8",
                 "Cache-Control" => "no-store"],
                _ABOUT_TEXT)
        elseif startswith(path, "/logo/")
            # the three logos of the About boxes, from docs/assets (sized copies)
            name = path[7:end]
            name in ("GaiaSeis_icon", "CRL_logo", "DeformingGaia_logo") || return HTTP.Response(404, "no such logo")
            lp = _logo_path(name, 120)
            isempty(lp) && return HTTP.Response(404, "logo file missing")
            return HTTP.Response(200, ["Content-Type" => "image/png", "Cache-Control" => "max-age=86400"], read(lp))
        elseif path == "/status.json"
            return HTTP.Response(200,
                ["Content-Type" => "application/json",
                 "Cache-Control" => "no-store"],
                _status_json(state[:session]))
        elseif path == "/metrics.json"
            return HTTP.Response(200,
                ["Content-Type" => "application/json",
                 "Cache-Control" => "no-store"],
                _metrics_json(state[:session]))
        elseif path == "/metrics.txt"
            return HTTP.Response(200,
                ["Content-Type" => "text/plain; charset=utf-8",
                 "Cache-Control" => "no-store"],
                _metrics_summary_text(state[:session], 60.0))
        elseif path == "/csv/session.csv"
            return HTTP.Response(200,
                ["Content-Type" => "text/csv; charset=utf-8",
                 "Content-Disposition" => "attachment; filename=\"gaiaseis_session.csv\"",
                 "Cache-Control" => "no-store"],
                _csv_snapshot(state[:session]))
        elseif path == "/csv/live.csv"
            return _csv_live_response(state)
        elseif path == "/mseed.json"
            # Directory listing for the miniSEED panel.
            return HTTP.Response(200,
                ["Content-Type" => "application/json",
                 "Cache-Control" => "no-store"],
                _mseed_list_json(state[:session]))
        elseif path == "/mseed/live"
            try
                return _mseed_live_response(state[:session], query)
            catch err
                @warn "live miniSEED failed" query err
                return HTTP.Response(500, "live error: $(sprint(showerror, err))")
            end
        elseif path == "/mseed/download"
            try
                return _mseed_download_response(state[:session], query)
            catch err
                @warn "miniSEED download failed" query err
                return HTTP.Response(500, "download error: $(sprint(showerror, err))")
            end
        elseif haskey(panel_route, path)
            try
                last_panel_request[] = time()
                cached = lock(cache_lock) do
                    hit = get(panel_cache, path, nothing)
                    hit === nothing ? nothing : (hit[3], hit[4])
                end
                if cached === nothing
                    # First request after idle: the worker has not rendered
                    # yet. Give it one interval, then fall back to a direct
                    # render (on this handler's thread, not thread 1).
                    wait_s = clamp(settings.web_refresh_s, 0.2, 2.0)
                    t_w = time()
                    while cached === nothing && time() - t_w < wait_s
                        sleep(0.05)
                        cached = lock(cache_lock) do
                            hit = get(panel_cache, path, nothing)
                            hit === nothing ? nothing : (hit[3], hit[4])
                        end
                    end
                end
                if cached === nothing
                    sig   = _settings_to_json(settings)
                    bytes = _render_panel_to_png_bytes(panel_route[path], W, H,
                                                       _session_view(state[:session]), settings)
                    t_r   = time()
                    etag  = string('"', round(Int, t_r * 1000), '-', hash(sig) % 100_000, '"')
                    lock(cache_lock) do
                        panel_cache[path] = (t_r, sig, bytes, etag)
                    end
                else
                    bytes, etag = cached
                end
                if HTTP.header(req, "If-None-Match", "") == etag
                    return HTTP.Response(304,
                        ["ETag" => etag, "Cache-Control" => "no-cache"])
                end
                return HTTP.Response(200,
                    ["Content-Type" => "image/png",
                     "Cache-Control" => "no-cache",
                     "ETag" => etag],
                    bytes)
            catch err
                @warn "panel render failed" path err
                return HTTP.Response(500, "render error: $(sprint(showerror, err))")
            end
        else
            return HTTP.Response(404, "not found: $path")
        end
    end
    # Retire idle viewers even when nobody is requesting anything.
    @async begin
        while tracker.active[]
            sleep(15.0)
            tracker.active[] || break
            try; _web_expire!(tracker); catch err; @debug "sweep failed" err; end
        end
        # Final flush so a shutdown closes every open session in the log.
        try
            _close_open_web_sessions!(tracker, "(server stopped)")
        catch err
            @debug "final flush failed" err
        end
        lock(() -> delete!(_WEB_TRACKERS, tracker), _WEB_TRACKERS_LOCK)
    end

    # Bind to 0.0.0.0 so machines on the LAN can connect; switch to
    # "127.0.0.1" if you want localhost-only.
    #
    # `stream = true` because the plain request handler cannot see who is
    # connecting: HTTP 1.11 leaves `req.context` empty, while the stream's
    # underlying connection carries `peerip`. The route logic below is
    # untouched — this only wraps it.
    return HTTP.serve!("0.0.0.0", port; verbose = false, stream = true,
                       on_shutdown = () -> (tracker.active[] = false)) do http::HTTP.Stream
        req = http.message
        req.body = read(http)
        ip = try; string(http.stream.peerip); catch; "unknown"; end
        ua = HTTP.header(req, "User-Agent", "")
        local resp
        try
            resp = handler(req)
        catch err
            @warn "web handler failed" target=req.target err
            resp = HTTP.Response(500, "internal error")
        end
        HTTP.setstatus(http, resp.status)
        for (k, v) in resp.headers
            lowercase(k) == "content-length" && continue
            HTTP.setheader(http, k => v)
        end
        body = resp.body
        if body isa IO
            # Never-ending bodies (live CSV / live miniSEED). Chunked, and the
            # producer is closed as soon as the client goes away — which the
            # old buffered path could only guess at from a backlog heuristic.
            HTTP.startwrite(http)
            n = 0
            # A client that hangs up while the producer has nothing to write
            # was never noticed: `eof(body)` blocked until the next record
            # (a 1 Hz channel yields one 512-byte record every ~2 min) and
            # only the next `write` failed. A puller that times out and
            # reconnects every minute left one producer task, one CLOSE-WAIT
            # socket and the chunk buffers behind per attempt — 1030 tasks,
            # 2.4 GB and an 8-minute processing backlog after 6 h
            # (2026-09-12). Watch the raw socket for the peer's FIN instead.
            raw  = try; http.stream.io; catch; nothing; end
            gone = raw === nothing ? nothing :
                   Threads.@spawn (try; eof(raw); catch; true; end)
            # The copy loop runs on the worker pool for the same reason as
            # the producer; the handler task just waits for it.
            is_mseed_live = _req_path(req) == "/mseed/live"
            n = fetch(Threads.@spawn begin
                m = 0
                try
                    while true
                        if bytesavailable(body) > 0
                            chunk = readavailable(body)
                            write(http, chunk)
                            m += length(chunk)
                            is_mseed_live && _note_mseed_delivery!(state[:session])
                        elseif !isopen(body)
                            break                               # producer finished
                        elseif gone !== nothing && istaskdone(gone) && fetch(gone) === true
                            break                               # client hung up
                        else
                            sleep(0.05)
                        end
                    end
                catch err
                    @debug "live client disconnected" ip err
                finally
                    try; close(body); catch; end
                end
                m
            end)
            _web_record!(tracker, ip, ua, n, _req_path(req))
        else
            bytes = body isa Vector{UInt8} ? body : Vector{UInt8}(codeunits(String(body)))
            HTTP.setheader(http, "Content-Length" => string(length(bytes)))
            HTTP.startwrite(http)
            write(http, bytes)
            _web_record!(tracker, ip, ua, length(bytes), _req_path(req))
        end
        return nothing
    end
end

# ---------- Residual statistic: choices, titles and explanations ----------
const _RESID_CHOICES = [(:engine, "Engine's own σ̂"), (:rms_w, "Weighted post-fit RMS"),
                        (:rms_u, "Unweighted post-fit RMS"), (:sigma_va, "Smoothed σ̂ (300/30-epoch window)")]
_resid_column(m::Symbol) = m === :rms_w ? 3 : m === :rms_u ? 4 : m === :sigma_va ? 5 : 2
_resid_title(m::Symbol) = m === :rms_w ? "Weighted post-fit RMS" : m === :rms_u ? "Unweighted post-fit RMS" :
                          m === :sigma_va ? "Smoothed σ̂ (300/30-epoch window)" : "Post-fit residual σ̂ (engine's own)"
function _resid_explain(m::Symbol)
    m === :rms_w && return "sqrt(Σ w·r² / Σ w) over the satellites kept in the fit; w = the engine's weights (sin² of elevation in GaiaVario). Each engine's own unit-weight figure."
    m === :rms_u && return "sqrt(Σ r² / n) over the satellites kept: the same formula for every engine, the one to compare engines with (together with n)."
    m === :sigma_va && return "Cumulative mean of the weighted RMS for the first 300 epochs, then an exponential average (300 epochs up, 30 down); each epoch enters capped at 3× the current value, so one bad epoch cannot poison it."
    return "The figure the engine reports for the epoch: PPPHVA's windowed σ̂, GaiaVario's weighted post-fit RMS."
end
const _RESID_NOTE = "r is the post-fit residual of one satellite's pair observation (phase change minus modelled change minus the fitted displacement and clock), in metres. The four statistics are computed for every epoch and kept in the history, so the choice applies to the whole window at once. Per-epoch figures are noisy by nature (30 observations); the smoothed one is for trend watching."
_fmt_duration(s::Real) = s < 3600 ? @sprintf("%d:%02d", floor(Int, s / 60), floor(Int, mod(s, 60))) :
                         @sprintf("%d h %02d min", floor(Int, s / 3600), floor(Int, mod(s, 3600) / 60))
