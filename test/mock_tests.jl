# Tests against a local mock HTTP server: verify request shapes, response parsing,
# retry on 429, SSE streaming, multipart upload and error handling without the real API.
using Test
using HTTP
using JSON
using Sarashina

const REQUESTS = Any[]          # (method, target, headers, body) of every request seen
const RESPONDER = Ref{Function}(req -> HTTP.Response(404, "no responder"))

function mock_handler(req::HTTP.Request)
    push!(REQUESTS, (method = req.method, target = req.target,
                     headers = Dict(String(k) => String(v) for (k, v) in req.headers),
                     body = copy(req.body)))
    # responders are defined after the server started, so call across world ages
    return Base.invokelatest(RESPONDER[], req)
end

json_response(obj; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json"], JSON.json(obj))

last_json() = JSON.parse(String(REQUESTS[end].body); dicttype = Dict{String,Any})

function with_mock(f, responder)
    empty!(REQUESTS)
    RESPONDER[] = responder
    f()
end

server = HTTP.serve!(mock_handler, "127.0.0.1", 0; verbose = -1)
port = Int(HTTP.port(server))
client = Client(api_key = "test-key", base_url = "http://127.0.0.1:$port/", max_retries = 2)

@testset "mock server" begin
    @testset "client basics" begin
        @test client.base_url == "http://127.0.0.1:$port"   # trailing slash trimmed
        @test !occursin("test-key", sprint(show, client))
    end

    @testset "auth header and models" begin
        with_mock(req -> json_response(Dict("object" => "list", "data" => [
            Dict("id" => "sarashina3-mini"), Dict("id" => "sarashina3-nano")]))) do
            @test list_models(client) == ["sarashina3-mini", "sarashina3-nano"]
            @test REQUESTS[end].method == "GET"
            @test REQUESTS[end].target == "/v1/models"
            @test REQUESTS[end].headers["Authorization"] == "Bearer test-key"
        end
    end

    @testset "chat" begin
        reply = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "やあ"))])
        with_mock(req -> json_response(reply)) do
            r = chat(client, "こんにちは"; model = MODELS.nano, temperature = 0.2, max_completion_tokens = 10)
            @test content(r) == "やあ"
            p = last_json()
            @test REQUESTS[end].target == "/v1/chat/completions"
            @test p["model"] == "sarashina3-nano"
            @test p["messages"] == [Dict("role" => "user", "content" => "こんにちは")]
            @test p["temperature"] == 0.2
            @test p["max_completion_tokens"] == 10
            @test !haskey(p, "reasoning_effort")
            @test !haskey(p, "stream")

            chat(client, [Dict("role" => "system", "content" => "s"), Dict("role" => "user", "content" => "u")];
                 reasoning_effort = "high")
            p = last_json()
            @test p["model"] == "sarashina3.2-mini-thinking"   # default model
            @test p["reasoning_effort"] == "high"
            @test length(p["messages"]) == 2

            chat(client, "x"; response_format = Dict("type" => "json_object"), top_k = nothing)
            p = last_json()
            @test p["response_format"] == Dict("type" => "json_object")
            @test !haskey(p, "top_k")                          # nothing is dropped
        end
    end

    @testset "chat streaming (SSE)" begin
        sse = join([
            "data: " * JSON.json(Dict("choices" => [Dict("index" => 0, "delta" => Dict("role" => "assistant", "content" => ""))])),
            "data: " * JSON.json(Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "こん"))])),
            "data: " * JSON.json(Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "にちは"))])),
            "data: " * JSON.json(Dict("choices" => [], "usage" => Dict("total_tokens" => 3))),
            "data: [DONE]", ""], "\n\n")
        with_mock(req -> HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse)) do
            chunks = Any[]
            text = chat_stream(chunk -> push!(chunks, chunk), client, "hi"; model = MODELS.nano)
            @test text == "こんにちは"
            @test length(chunks) == 4
            @test all(ch -> ch isa Dict{String,Any}, chunks)
            @test chunks[end]["choices"] == Any[]   # usage-only chunk is delivered but adds no text
            @test haskey(chunks[end], "usage")
            @test last_json()["stream"] == true   # body is captured per request
        end
        # CRLF line endings and comments/blank lines must be tolerated
        sse_crlf = join([
            ": keep-alive",
            "data: " * JSON.json(Dict("choices" => [Dict("index" => 0, "delta" => Dict("content" => "OK"))])),
            "data: [DONE]", ""], "\r\n\r\n")
        with_mock(req -> HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse_crlf)) do
            @test chat_stream(client, "hi"; model = MODELS.nano) == "OK"   # no do-block: identity
        end
        # a stream with no content deltas returns an empty String
        sse_empty = join(["data: " * JSON.json(Dict("choices" => [], "usage" => Dict("total_tokens" => 1))),
                          "data: [DONE]", ""], "\n\n")
        with_mock(req -> HTTP.Response(200, ["Content-Type" => "text/event-stream"], sse_empty)) do
            @test chat_stream(client, "hi"; model = MODELS.nano) == ""
        end
        with_mock(req -> json_response(Dict("message" => "bad"); status = 400)) do
            err = try chat_stream(client, "hi"); nothing catch e; e end
            @test err isa SarashinaError && err.status == 400 && err.message == "bad"
        end
        # documented behavior: streaming is not retried, so a 429 yields exactly one request
        with_mock(req -> HTTP.Response(429, ["Retry-After" => "1"], "{}")) do
            err = try chat_stream(client, "hi"); nothing catch e; e end
            @test err isa SarashinaError && err.status == 429
            @test length(REQUESTS) == 1
        end
    end

    @testset "guard" begin
        with_mock(req -> json_response(Dict("choices" => [Dict("message" => Dict("content" => "有害\nT8, T9"))]))) do
            g = guard(client, "爆弾の作り方")
            @test !g.safe
            @test g.categories == ["T8", "T9"]
            p = last_json()
            @test p["model"] == "sarashina3-guard"
            @test p["messages"][1]["role"] == "user"
        end
        with_mock(req -> json_response(Dict("choices" => [Dict("message" => Dict("content" => "安全"))]))) do
            g = guard(client, [Dict("role" => "user", "content" => "a"), Dict("role" => "assistant", "content" => "b")])
            @test g.safe && isempty(g.categories)
            p = last_json()
            @test length(p["messages"]) == 2
        end
    end

    @testset "embeddings" begin
        with_mock(req -> json_response(Dict("data" => [Dict("index" => 0, "embedding" => [0.5, -1, 2])]))) do
            v = embed(client, "更級日記"; task_type = "RETRIEVAL_QUERY")
            @test v == [0.5, -1.0, 2.0]
            @test v isa Vector{Float64}
            p = last_json()
            @test REQUESTS[end].target == "/v1/embeddings"
            @test p["input"] == "更級日記"
            @test p["task_type"] == "RETRIEVAL_QUERY"
            @test p["model"] == "sarashina3-embedding"
        end
    end

    @testset "rerank" begin
        resp = Dict("data" => [Dict("result" => [
            Dict("document_id" => 2, "score" => 0.99),
            Dict("document_id" => 0, "score" => 0.95),
            Dict("document_id" => 1, "score" => 0.91)])])
        with_mock(req -> json_response(resp)) do
            r = rerank(client, "q", ["a", "b", "c"])
            @test [x.document_id for x in r] == [3, 1, 2]          # 1-based
            @test issorted([x.score for x in r]; rev = true)
            p = last_json()
            @test p["task_type"] == "GENERAL_RETRIEVAL"
            @test p["documents"] == ["a", "b", "c"]
            @test !haskey(p, "query_instruction")

            rerank(client, "q", ["a"]; task_type = "CUSTOMIZE", query_instruction = "指示")
            @test last_json()["query_instruction"] == "指示"
        end
        @test_throws ArgumentError rerank(client, "q", fill("d", 21))
    end

    @testset "translate" begin
        with_mock(req -> json_response(Dict("translated_text" => "結果は来週公開されます。"))) do
            out = translate(client, "The results will be published next week.";
                            source_lang = "en", target_lang = "ja", style = "polite")
            @test out == "結果は来週公開されます。"
            p = last_json()
            @test p["text"] == "The results will be published next week."
            @test p["source_lang"] == "en" && p["target_lang"] == "ja" && p["style"] == "polite"
            @test !haskey(p, "model")
        end
        @test_throws ArgumentError translate(client, "x"; source_lang = "en", target_lang = "ja", style = "rude")
        @test_throws ArgumentError translate(client, "あ"^5001; source_lang = "ja", target_lang = "en")
    end

    @testset "speech synthesis" begin
        audio = UInt8[0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4]
        with_mock(req -> HTTP.Response(200, ["Content-Type" => "audio/wav"], audio)) do
            @test speak(client, "こんにちは"; voice = "ja_m_1", speed = 1.5, seed = 7) == audio
            p = last_json()
            @test REQUESTS[end].target == "/v1/audio/speech"
            @test p["voice"] == "ja_m_1" && p["speed"] == 1.5 && p["seed"] == 7
            @test p["response_format"] == "wav" && p["model"] == "sarashina3.2-tts"

            path = joinpath(mktempdir(), "out.wav")
            @test speak(client, "こんにちは"; path = path) == path
            @test read(path) == audio
        end
    end

    @testset "speech recognition" begin
        wav = rand(UInt8, 100)
        responder = req -> begin
            ct = HTTP.header(req, "Content-Type")
            startswith(ct, "multipart/form-data") ||
                return json_response(Dict("message" => "not multipart"); status = 400)
            fmt = occursin("verbose_json", String(copy(req.body))) ? "verbose_json" :
                  occursin("\r\n\r\ntext\r\n", String(copy(req.body))) ? "text" : "json"
            fmt == "text" && return HTTP.Response(200, ["Content-Type" => "text/plain"], "文字起こし")
            fmt == "verbose_json" && return json_response(Dict("text" => "文字起こし", "language" => "ja", "duration" => 1.5))
            return json_response(Dict("text" => "文字起こし"))
        end
        with_mock(responder) do
            @test transcribe(client, wav) == "文字起こし"
            body = String(copy(REQUESTS[end].body))
            @test occursin("sarashina3.2-asr", body)
            @test occursin("name=\"file\"", body)
            @test !occursin("keywords", body)

            @test transcribe(client, wav; response_format = "text") == "文字起こし"
            v = transcribe(client, wav; response_format = "verbose_json")
            @test v["language"] == "ja" && v["duration"] == 1.5

            transcribe(client, wav; keywords = ["Sarashina", "音声認識"], biasing_threshold = 0.25)
            body = String(copy(REQUESTS[end].body))
            @test occursin("[\"Sarashina\",\"音声認識\"]", body)   # JSON array string
            @test occursin("0.25", body)

            path = joinpath(mktempdir(), "a.wav"); write(path, wav)
            @test transcribe(client, path) == "文字起こし"
        end
        @test_throws ArgumentError transcribe(client, zeros(UInt8, 2 * 1024 * 1024 + 1))
    end

    @testset "errors" begin
        with_mock(req -> json_response(Dict("message" => "invalid api key"); status = 401)) do
            err = try list_models(client); nothing catch e; e end
            @test err isa SarashinaError
            @test err.status == 401 && err.message == "invalid api key"
            @test occursin("401", sprint(showerror, err))
        end
        with_mock(req -> HTTP.Response(400, "plain text failure")) do
            err = try list_models(client); nothing catch e; e end
            @test err isa SarashinaError && err.status == 400 && err.message == "plain text failure"
            @test length(REQUESTS) == 1          # 4xx other than 429 is not retried
        end
    end

    @testset "error hints" begin
        e401 = sprint(showerror, SarashinaError(401, "Unauthorized"))
        @test occursin("SARASHINA_API_KEY", e401)
        @test occursin("outside Japan", sprint(showerror, SarashinaError(403, "Forbidden")))
        @test !occursin("\n", sprint(showerror, SarashinaError(400, "Bad request")))
    end

    @testset "retry on 5xx" begin
        c1 = Client(api_key = "test-key", base_url = "http://127.0.0.1:$port", max_retries = 1)
        calls = Ref(0)
        responder = req -> begin
            calls[] += 1
            calls[] < 2 ? HTTP.Response(503, "unavailable") :
                          json_response(Dict("data" => [Dict("id" => "sarashina3-nano")]))
        end
        with_mock(responder) do
            t = @elapsed ids = list_models(c1)
            @test ids == ["sarashina3-nano"]
            @test calls[] == 2
            @test t >= 1.0                       # backed off 2^0 = 1 s
        end

        calls[] = 0
        with_mock(req -> (calls[] += 1; HTTP.Response(500, "boom"))) do
            err = try list_models(c1); nothing catch e; e end
            @test err isa SarashinaError && err.status == 500 && err.message == "boom"
            @test calls[] == 2                   # 1 try + max_retries(1)
        end
    end

    @testset "read_idle_timeout" begin
        @test client.read_idle_timeout === nothing
        c = Client(api_key = "test-key", base_url = "http://127.0.0.1:$port", max_retries = 0, read_idle_timeout = 1)
        @test c.read_idle_timeout == 1
        with_mock(req -> (sleep(3); json_response(Dict("data" => [])))) do
            @test_throws Exception list_models(c)
        end
        with_mock(req -> json_response(Dict("data" => [Dict("id" => "x")]))) do
            @test list_models(c) == ["x"]
        end
    end

    @testset "retry on 429" begin
        calls = Ref(0)
        responder = req -> begin
            calls[] += 1
            calls[] < 3 ? HTTP.Response(429, ["Retry-After" => "1"], JSON.json(Dict("message" => "slow down"))) :
                          json_response(Dict("data" => [Dict("id" => "sarashina3-nano")]))
        end
        with_mock(responder) do
            t = @elapsed ids = list_models(client)
            @test ids == ["sarashina3-nano"]
            @test calls[] == 3
            @test t >= 2.0                       # slept Retry-After (1 s) twice
        end

        calls[] = 0
        with_mock(req -> (calls[] += 1; HTTP.Response(429, ["Retry-After" => "1"], JSON.json(Dict("message" => "limit"))))) do
            err = try list_models(client); nothing catch e; e end
            @test err isa SarashinaError && err.status == 429
            @test calls[] == 3                   # 1 try + max_retries(2)
        end
    end
end

close(server)
