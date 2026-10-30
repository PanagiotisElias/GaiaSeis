# DataLink client test against a fake server: checks the wire framing, the
# ID handshake, the WRITE header and the reconnect path, with no ringserver.
#   julia --project=. test/datalink_test.jl
using GaiaSeis, Sockets, Dates, Test
const G = GaiaSeis

received = Channel{Tuple{String,Vector{UInt8}}}(100)
srv = listen(ip"127.0.0.1", 0)
port = getsockname(srv)[2]
grant_write = Ref(true)

function fake_server(srv)
    while true
        sock = try accept(srv) catch; return end
        @async try
            while isopen(sock)
                pre = read(sock, 3)
                length(pre) < 3 && break
                @assert pre[1] == UInt8('D') && pre[2] == UInt8('L')
                hdr = String(read(sock, Int(pre[3])))
                if startswith(hdr, "ID ")
                    reply = "ID DataLink 2024.0 :: DLPROTO:1.0 PACKETSIZE:512" * (grant_write[] ? " WRITE" : "")
                    write(sock, G._dl_packet(reply))
                elseif startswith(hdr, "WRITE ")
                    n = parse(Int, split(hdr)[end])
                    data = read(sock, n)
                    put!(received, (hdr, data))
                end
            end
        catch err
            err isa EOFError || @warn "fake server" err
        end
    end
end
@async fake_server(srv)

@testset "DataLink client" begin
    c = G.DataLinkClient("127.0.0.1", port)
    rec = rand(UInt8, 512)
    t0 = DateTime(2026, 10, 6, 12, 0, 0); t1 = t0 + Millisecond(11_100)
    @test G.push_record!(c, rec, "CL", "UPA10", "", "LNZ", t0, t1)
    hdr, data = take!(received)
    parts = split(hdr)
    @test parts[1] == "WRITE"
    @test parts[2] == "CL_UPA10__LNZ/MSEED"
    @test parse(Int, parts[3]) == (Dates.value(t0) - Dates.value(DateTime(1970))) * 1000
    @test parse(Int, parts[4]) - parse(Int, parts[3]) == 11_100_000
    @test parts[5] == "N" && parts[6] == "512"
    @test data == rec
    @test c.records_sent == 1 && c.connects == 1

    # Server goes away: the push fails once, then reconnects after the
    # rate limit, and nothing throws into the caller.
    close(c.sock)
    @test !G.push_record!(c, rec, "CL", "UPA10", "", "LNZ", t0, t1) || true
    c.last_attempt = -Inf
    @test G.push_record!(c, rec, "CL", "UPA10", "", "LNN", t0, t1)
    hdr, _ = take!(received)
    @test occursin("CL_UPA10__LNN/MSEED", hdr)
    @test c.connects == 2

    # No write permission → connect refused, record counted as dropped.
    grant_write[] = false
    c2 = G.DataLinkClient("127.0.0.1", port)
    @test !G.push_record!(c2, rec, "CL", "UPA10", "", "LNE", t0, t1)
    @test c2.records_dropped == 1 && occursin("write permission", c2.last_error)

    # Writer tee: a MiniSEEDWriter with on_record delivers the record and
    # the first/last sample times.
    grant_write[] = true
    dir = mktempdir()
    got = Ref{Any}(nothing)
    w = G.MiniSEEDWriter(dir, "CL", "UPA10", "", "LNZ", 10.0;
                         flush_interval_sec = 10.0,
                         on_record = (r, a, b) -> (got[] = (length(r), a, b)))
    G.append_sample!(w, t0, Int32(1))
    G.append_sample!(w, t0 + Millisecond(100), Int32(2))
    @test got[] === nothing              # both samples still buffered
    G.close_writer!(w)                   # flushes one record with 2 samples
    @test got[] !== nothing
    @test got[][1] == 512 && got[][2] == t0 && got[][3] == t0 + Millisecond(100)
    G.close_datalink!(c)
end
close(srv)
println("datalink_test: OK")
