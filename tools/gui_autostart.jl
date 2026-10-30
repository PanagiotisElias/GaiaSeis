using GaiaSeis, Gtk4, Dates
win = launch_gui()
Gtk4.GLib.is_loop_running() || Gtk4.GLib.start_main_loop(true)
function walk(w, f); f(w); c = Gtk4.G_.get_first_child(w); while c !== nothing; walk(c, f); c = Gtk4.G_.get_next_sibling(c); end; end
function buttons(root); d = Dict{String,Any}(); walk(root, w -> (w isa Gtk4.GtkButton && (try; d[Gtk4.get_gtk_property(w, :label, String)] = w; catch; end))); d; end
b = buttons(win)
Gtk4.signal_emit(b["Start stream"], "clicked", Nothing); println("[drive] stream started ", now()); flush(stdout)
sleep(3); Gtk4.signal_emit(b["Plot"], "clicked", Nothing); sleep(3); println("[drive] plot opened")
# The web server's Start button lives in the plot window: find it among the
# top-level windows (gtk_window_list_toplevels returns a GList of GObject
# pointers) and click it.
# The port comes from $GAIASEIS_WEB_PORT (default 8765): the toolbar entry
# holding "8765" is overwritten before Start is clicked.
webport = get(ENV, "GAIASEIS_WEB_PORT", "8765")
try
    for obj in Gtk4.G_.list_toplevels()
        w = convert(Gtk4.GtkWidget, obj)
        w === win && continue
        pb = buttons(w)
        if haskey(pb, "Start")
            walk(w, e -> (e isa Gtk4.GtkEntry &&
                          (try; Gtk4.get_gtk_property(e, :text, String) == "8765"; catch; false; end) &&
                          Gtk4.set_gtk_property!(e, :text, webport)))
            Gtk4.signal_emit(pb["Start"], "clicked", Nothing); println("[drive] web server started (port $webport)"); break
        end
    end
catch err; println("[drive] web server not started: ", sprint(showerror, err)); end
flush(stdout)
while true; sleep(60); end
