# Launch the Gtk4 GUI and block until the window is closed.
using GaiaSeis
using Gtk4

# Rendering, the RTCM decoder and the engine bridge (the displacement engine
# is a plug-in, GaiaVario by default) all share the Julia scheduler. A panel render is CPU-bound with no yield points, so on one
# thread a slow redraw stalls the decoder — very visible at 10 Hz with a
# long plot span. `-t auto` moves that work off the bridge's thread.
if Threads.nthreads() == 1
    @warn "running single-threaded — at 10 Hz the plot redraw competes with " *
          "the decoder. Relaunch with `julia -t auto --project=. ...` for " *
          "smoother plots and steadier decoding."
end

win = launch_gui()

# Block the main task on a condition that the window-close handler will signal.
# Using a Condition lets the GLib event loop (which runs on its own task) keep
# pumping events — a `while true; sleep(1); end` here would block the Gtk loop
# and the window would render blank with a wait cursor.
closed = Base.Event()
Gtk4.signal_connect(win, "close-request") do _
    notify(closed)
    false                # return false → let the window actually close
end
# Gtk4.jl only auto-starts the GLib main loop when `isinteractive()` is true
# (see Gtk4.jl `__init__`). Under `julia examples/gui.jl` it therefore never
# starts: the window maps and gets a WM frame, but nothing ever iterates the
# main context, so it never paints and looks invisible against the desktop.
# Start it explicitly, and wait until it is actually running.
Gtk4.GLib.is_loop_running() || Gtk4.GLib.start_main_loop(true)

wait(closed)
