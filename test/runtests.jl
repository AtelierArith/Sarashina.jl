using Test
using Sarashina
using Sarashina: _parse_guard, MODELS

@testset "Sarashina" begin
    @testset "model list covers docs.sarashina.ai/models" begin
        @test sort(collect(values(MODELS))) == sort([
            "sarashina3.2-mini-thinking", "sarashina3-mini", "sarashina3-nano",
            "sarashina3-guard", "sarashina3-embedding", "sarashina3-rerank",
            "sarashina3.2-translate", "sarashina3.2-tts", "sarashina3.2-asr"])
    end

    @testset "guard parsing" begin
        @test _parse_guard("安全") == (safe = true, categories = String[], raw = "安全")
        @test _parse_guard("有害\nT8, T9").categories == ["T8", "T9"]
        @test !_parse_guard("有害\nT8").safe
    end

    c = Client(api_key = "dummy")
    @testset "argument validation" begin
        @test_throws ArgumentError embed(c, "x"; task_type = "BAD")
        @test_throws ArgumentError rerank(c, "q", String[])
        @test_throws ArgumentError rerank(c, "q", ["a"]; task_type = "CUSTOMIZE")
        @test_throws ArgumentError translate(c, "x"; source_lang = "ja", target_lang = "ja")
        @test_throws ArgumentError translate(c, "x"; source_lang = "fr", target_lang = "ja")
        @test_throws ArgumentError speak(c, "x")
        @test_throws ArgumentError speak(c, "こんにちは"; voice = "nope")
        @test_throws ArgumentError speak(c, "こんにちは"; speed = 10)
        @test_throws ArgumentError chat(c, "hi"; reasoning_effort = "max")
        @test_throws ArgumentError transcribe(c, UInt8[]; response_format = "srt")
    end
    @test !occursin("dummy", sprint(show, c))
end

include("mock_tests.jl")

# Convert a 24 kHz 16-bit mono WAV (as produced by `speak`) to 16 kHz by linear interpolation.
function resample_wav_16k(wav::Vector{UInt8}; from = 24_000, to = 16_000)
    pcm = reinterpret(Int16, wav[45:end - (length(wav) - 44) % 2])
    n = floor(Int, length(pcm) * to / from)
    out = Vector{Int16}(undef, n)
    for i in 1:n
        x = (i - 1) * from / to + 1
        lo = floor(Int, x); hi = min(lo + 1, length(pcm)); f = x - lo
        out[i] = round(Int16, (1 - f) * pcm[lo] + f * pcm[hi])
    end
    data = collect(reinterpret(UInt8, out))
    io = IOBuffer()
    write(io, b"RIFF", UInt32(36 + length(data)), b"WAVE", b"fmt ", UInt32(16),
          UInt16(1), UInt16(1), UInt32(to), UInt32(to * 2), UInt16(2), UInt16(16),
          b"data", UInt32(length(data)), data)
    return take!(io)
end

# Live API tests: run only when a key is available. Mind per-model RPM (TTS/Guard: 6).
using DotEnv
const HAS_KEY = haskey(ENV, "SARASHINA_API_KEY") || haskey(DotEnv.config(), "SARASHINA_API_KEY")
if HAS_KEY
    @testset "live API" begin
        c = Client()
        ids = list_models(c)
        @test "sarashina3-nano" in ids

        r = chat(c, "1+1は？ 数字だけ答えて。"; model = MODELS.nano, max_completion_tokens = 16)
        @test !isempty(content(r))

        t = chat_stream(c, "こんにちは"; model = MODELS.nano, max_completion_tokens = 16)
        @test !isempty(t)

        r = chat(c, "2+3は？"; model = MODELS.mini_thinking, reasoning_effort = "low")
        @test !isempty(content(r))

        g = guard(c, "今日は天気がいいですね。")
        @test g.safe

        v = embed(c, "更級日記"; task_type = "RETRIEVAL_DOCUMENT")
        @test length(v) == 1536

        rr = rerank(c, "日本の首都は？", ["東京は日本の首都です。", "犬は動物です。"])
        @test rr[1].document_id == 1

        @test !isempty(translate(c, "The results will be published next week."; source_lang = "en", target_lang = "ja"))

        audio = speak(c, "こんにちは。"; response_format = "wav")
        @test length(audio) > 44
        @test String(audio[1:4]) == "RIFF"
        txt = transcribe(c, resample_wav_16k(audio))   # TTS is 24 kHz; ASR requires 16 kHz
        @test txt isa String
        @test !isempty(txt)
    end
end
