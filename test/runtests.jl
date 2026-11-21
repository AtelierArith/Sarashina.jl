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

# Build a 16-bit PCM WAV in memory (0.5 s, 440 Hz sine unless `seconds` is given).
function make_pcm16_wav(rate::Int; channels::Int = 1, seconds = 0.5)
    frames = round(Int, rate * seconds)
    samples = Int16[round(Int16, 10_000 * sin(2π * 440 * i / rate)) for i in 0:frames - 1]
    pcm = repeat(samples, inner = channels)
    data = collect(reinterpret(UInt8, pcm))
    io = IOBuffer()
    write(io, b"RIFF", UInt32(36 + length(data)), b"WAVE", b"fmt ", UInt32(16),
          UInt16(1), UInt16(channels), UInt32(rate), UInt32(rate * 2 * channels),
          UInt16(2 * channels), UInt16(16), b"data", UInt32(length(data)), data)
    return take!(io)
end

@testset "WAV conversion for ASR" begin
    wav24 = make_pcm16_wav(24_000)
    out = Sarashina._to_asr_wav(wav24)
    info = Sarashina._wav_info(out)
    @test info.sample_rate == 16_000
    @test info.channels == 1
    @test info.bits_per_sample == 16
    @test info.audio_format == 1
    @test info.data_length == 2 * 8_000          # 0.5 s at 16 kHz
    @test length(out) == 44 + info.data_length

    wav16 = make_pcm16_wav(16_000)
    @test Sarashina._to_asr_wav(wav16) === wav16  # already 16 kHz/16-bit/mono: returned untouched

    o2 = Sarashina._to_asr_wav(make_pcm16_wav(16_000; channels = 2))
    @test Sarashina._wav_info(o2).channels == 1
    @test Sarashina._wav_info(o2).sample_rate == 16_000

    o3 = Sarashina._to_asr_wav(make_pcm16_wav(8_000))
    @test Sarashina._wav_info(o3).sample_rate == 16_000
    @test Sarashina._wav_info(o3).data_length == 2 * 8_000

    @test Sarashina._to_asr_wav(UInt8[1, 2, 3]) == UInt8[1, 2, 3]   # not a WAV: passed through
end

include("mock_tests.jl")

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

        chunks = Any[]
        t = chat_stream(c, "こんにちは"; model = MODELS.nano, max_completion_tokens = 16) do chunk
            push!(chunks, chunk)
        end
        @test !isempty(t)
        @test all(ch -> ch isa AbstractDict, chunks)
        # The return value is the concatenation of delta.content; the usage-only final chunk
        # (choices == []) must not break the stream.
        deltas = String[ch["choices"][1]["delta"]["content"] for ch in chunks
                        if !isempty(ch["choices"]) &&
                           get(ch["choices"][1]["delta"], "content", nothing) isa AbstractString]
        @test t == join(deltas)
        @test !isempty(chat_stream(c, "こんにちは"; model = MODELS.nano, max_completion_tokens = 16))

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
        txt = transcribe(c, audio)   # TTS returns 24 kHz; transcribe converts it to 16 kHz
        @test txt isa String
        @test !isempty(txt)
    end
end
