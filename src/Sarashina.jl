module Sarashina

using DotEnv
using HTTP
using JSON

export Client, SarashinaError
export chat, chat_stream, content, guard, embed, rerank, translate, transcribe, speak, list_models
export MODELS

# ---------------------------------------------------------------------------
# Models (https://docs.sarashina.ai/models)
# ---------------------------------------------------------------------------

"""
Model IDs offered by Sarashina API, keyed by a short symbol.
"""
const MODELS = (
    mini_thinking = "sarashina3.2-mini-thinking",
    mini = "sarashina3-mini",   # deprecated: scheduled to end on/after 2026-11-27
    nano = "sarashina3-nano",
    guard = "sarashina3-guard",
    embedding = "sarashina3-embedding",
    rerank = "sarashina3-rerank",
    translate = "sarashina3.2-translate",
    asr = "sarashina3.2-asr",
    tts = "sarashina3.2-tts",
)

const DEFAULT_BASE_URL = "https://api.sarashina.ai"
const EMBEDDING_TASK_TYPES = (
    "RETRIEVAL_DOCUMENT", "RETRIEVAL_QUERY", "SEMANTIC_SIMILARITY",
    "QUESTION_ANSWERING", "FACT_VERIFICATION", "CLASSIFICATION", "CLUSTERING",
)
const RERANK_TASK_TYPES = (
    "GENERAL_RETRIEVAL", "GENERAL_QA", "NEWS_RETRIEVAL",
    "SEMANTIC_SIMILARITY", "CUSTOMIZE",
)
const TTS_VOICES = ("ja_f_1", "ja_f_2", "ja_m_1")
const TTS_FORMATS = ("wav", "pcm", "flac", "mp3", "opus")
const ASR_FORMATS = ("json", "text", "verbose_json")
const REASONING_EFFORTS = ("low", "medium", "high")
const RETRY_SERVER_ERRORS = (500, 502, 503, 504)
const MAX_RETRY_AFTER = 120   # seconds; upper bound for honoring `Retry-After`
const MAX_BACKOFF = 30.0      # seconds; upper bound for the 5xx exponential backoff

# ---------------------------------------------------------------------------
# Client / errors
# ---------------------------------------------------------------------------

"""
    SarashinaError(status, message)

Raised on a non-2xx response. `message` is the `message` field of the JSON body when present.
"""
struct SarashinaError <: Exception
    status::Int
    message::String
end
function Base.showerror(io::IO, e::SarashinaError)
    print(io, "SarashinaError(", e.status, "): ", e.message)
    if e.status == 401
        print(io, "\nCheck that SARASHINA_API_KEY holds a valid API key ",
            "(issue one at https://chat.sarashina.ai/dashboard/api-keys).")
    elseif e.status == 403
        print(io, "\nThe Sarashina API rejects access from outside Japan.")
    end
end

"""
    Client(; api_key, base_url, max_retries, read_idle_timeout)

API client. `api_key` defaults to `ENV["SARASHINA_API_KEY"]`, falling back to a `.env` file
loaded with DotEnv.jl.

Requests are retried up to `max_retries` times on `429` (waiting for the number of seconds in
the `Retry-After` header, at most $(MAX_RETRY_AFTER) s) and on `500`/`502`/`503`/`504`
(exponential backoff: 1, 2, 4, ... up to $(MAX_BACKOFF) s).

`read_idle_timeout` is the number of seconds without incoming data after which a request
fails; `nothing` (the default) leaves it to HTTP.jl.
"""
struct Client
    api_key::String
    base_url::String
    max_retries::Int
    read_idle_timeout::Union{Nothing,Int}
end

function Client(; api_key::Union{Nothing,AbstractString} = nothing,
                  base_url::AbstractString = DEFAULT_BASE_URL,
                  max_retries::Integer = 3,
                  read_idle_timeout::Union{Nothing,Integer} = nothing)
    key = api_key === nothing ? _load_api_key() : String(api_key)
    timeout = read_idle_timeout === nothing ? nothing : Int(read_idle_timeout)
    return Client(key, rstrip(String(base_url), '/'), Int(max_retries), timeout)
end

Base.show(io::IO, c::Client) = print(io, "Client(base_url=", c.base_url, ", api_key=***)")

function _load_api_key()
    k = "SARASHINA_API_KEY"
    haskey(ENV, k) && !isempty(ENV[k]) && return ENV[k]
    cfg = DotEnv.config()
    v = get(cfg, k, "")
    isempty(v) && error("SARASHINA_API_KEY is not set (environment variable or .env)")
    return String(v)
end

_headers(c::Client; json::Bool = true) = begin
    h = Pair{String,String}["Authorization" => "Bearer $(c.api_key)"]
    json && push!(h, "Content-Type" => "application/json")
    h
end

function _error_message(body::AbstractVector{UInt8})
    s = String(copy(body))
    try
        obj = JSON.parse(s; dicttype = Dict{String,Any})
        obj isa AbstractDict && haskey(obj, "message") && return string(obj["message"])
    catch
    end
    return s
end

# Seconds to wait before retrying `resp` (a retryable response), or `nothing` if it is not retryable.
function _retry_delay(resp, attempt::Int)
    if resp.status == 429
        s = something(tryparse(Int, strip(HTTP.header(resp, "Retry-After", "1"))), 1)
        return clamp(s, 1, MAX_RETRY_AFTER)
    elseif resp.status in RETRY_SERVER_ERRORS
        return min(2.0^attempt, MAX_BACKOFF)
    end
    return nothing
end

# Send a request, retrying on 429 (Retry-After) and transient 5xx (exponential backoff).
function _request(c::Client, method::String, path::String, body, headers)
    url = c.base_url * path
    opts = c.read_idle_timeout === nothing ? (;) : (; read_idle_timeout = c.read_idle_timeout)
    attempt = 0
    while true
        # retry = false: HTTP.jl's own retry would ignore Retry-After; we handle retries ourselves.
        resp = HTTP.request(method, url, headers, body; status_exception = false, retry = false, opts...)
        delay = _retry_delay(resp, attempt)
        if delay !== nothing && attempt < c.max_retries
            @debug "Sarashina API returned $(resp.status); retrying in $(delay) s" attempt
            attempt += 1
            sleep(delay)
            continue
        end
        200 <= resp.status < 300 || throw(SarashinaError(resp.status, _error_message(resp.body)))
        return resp
    end
end

_parse(resp) = JSON.parse(String(copy(resp.body)); dicttype = Dict{String,Any})

function _post_json(c::Client, path, payload)
    return _request(c, "POST", path, JSON.json(payload), _headers(c))
end

function _check_in(name, value, allowed)
    value in allowed || throw(ArgumentError("$name must be one of $(join(allowed, ", ")); got $(repr(value))"))
end

_messages(prompt::AbstractString) = [Dict("role" => "user", "content" => prompt)]
_messages(msgs::AbstractVector) = msgs

function _warn_deprecated(model)
    model == MODELS.mini &&
        @warn "sarashina3-mini is scheduled to be retired on/after 2026-11-27; use sarashina3.2-mini-thinking" maxlog = 1
end

# ---------------------------------------------------------------------------
# Chat Completions (sarashina3.2-mini-thinking / sarashina3-mini / sarashina3-nano)
# ---------------------------------------------------------------------------

function _chat_payload(model, messages; reasoning_effort, extra...)
    _warn_deprecated(model)
    payload = Dict{String,Any}("model" => model, "messages" => _messages(messages))
    if reasoning_effort !== nothing
        _check_in("reasoning_effort", reasoning_effort, REASONING_EFFORTS)
        payload["reasoning_effort"] = reasoning_effort
    end
    for (k, v) in extra
        v === nothing || (payload[String(k)] = v)
    end
    return payload
end

"""
    chat(client, messages; model=MODELS.mini_thinking, reasoning_effort=nothing, kwargs...)

POST `/v1/chat/completions`. `messages` is a prompt `String` or a vector of
`Dict("role"=>..., "content"=>...)`. Extra keyword arguments (`temperature`, `max_tokens`,
`tools`, `tool_choice`, `response_format`, ...) are passed through to the request body.
Returns the parsed response `Dict`; the answer is
`resp["choices"][1]["message"]["content"]` (see also [`content`](@ref)).

`reasoning_effort` (`"low"`, `"medium"`, `"high"`) is meaningful for `sarashina3.2-mini-thinking`.
"""
function chat(c::Client, messages; model::AbstractString = MODELS.mini_thinking,
              reasoning_effort = nothing, kwargs...)
    payload = _chat_payload(model, messages; reasoning_effort, kwargs...)
    return _parse(_post_json(c, "/v1/chat/completions", payload))
end

"""
    chat_stream(f, client, messages; model, reasoning_effort, kwargs...)

Streaming chat (`stream=true`, Server-Sent Events). `f` is called with each parsed chunk
`Dict`. Returns the concatenated `delta.content` text.
"""
function chat_stream(f, c::Client, messages; model::AbstractString = MODELS.mini_thinking,
                     reasoning_effort = nothing, kwargs...)
    payload = _chat_payload(model, messages; reasoning_effort, kwargs...)
    payload["stream"] = true
    out = IOBuffer()
    opts = c.read_idle_timeout === nothing ? (;) : (; read_idle_timeout = c.read_idle_timeout)
    HTTP.open("POST", c.base_url * "/v1/chat/completions", _headers(c);
              status_exception = false, opts...) do io
        write(io, JSON.json(payload))
        HTTP.closewrite(io)
        resp = HTTP.startread(io)
        if !(200 <= resp.status < 300)
            throw(SarashinaError(resp.status, _error_message(read(io))))
        end
        while !eof(io)
            line = strip(readline(io))
            startswith(line, "data:") || continue
            data = strip(line[6:end])
            data == "[DONE]" && break
            isempty(data) && continue
            chunk = JSON.parse(data; dicttype = Dict{String,Any})
            f(chunk)
            for ch in get(chunk, "choices", Any[])
                delta = get(ch, "delta", nothing)
                delta isa AbstractDict || continue
                txt = get(delta, "content", nothing)
                txt isa AbstractString && write(out, txt)
            end
        end
    end
    return String(take!(out))
end
chat_stream(c::Client, messages; kwargs...) = chat_stream(identity, c, messages; kwargs...)

"""
    content(resp) -> String

Text of the first choice of a [`chat`](@ref) response.
"""
content(resp::AbstractDict) = String(resp["choices"][1]["message"]["content"])

# ---------------------------------------------------------------------------
# Guard (sarashina3-guard, via Chat Completions)
# ---------------------------------------------------------------------------

"""
    guard(client, text; role="user") -> NamedTuple{(:safe, :categories, :raw)}

Safety classification with `sarashina3-guard` (via `/v1/chat/completions`). The model answers
"安全", or "有害" followed by a newline and category codes such as `T8, T9` (T1–T12).
Returns `(safe::Bool, categories::Vector{String}, raw::String)`. To judge a whole conversation,
pass a vector of messages instead of a `String`. `tools`/`tool_choice` are unsupported by Guard.
Guard is limited to 6 RPM.
"""
function guard(c::Client, text; role::AbstractString = "user", kwargs...)
    msgs = text isa AbstractString ? [Dict("role" => role, "content" => text)] : text
    resp = chat(c, msgs; model = MODELS.guard, kwargs...)
    return _parse_guard(content(resp))
end

function _parse_guard(raw::AbstractString)
    lines = split(strip(raw), '\n')
    safe = !startswith(strip(first(lines)), "有害")
    cats = String[]
    for l in lines[2:end], m in eachmatch(r"T\d+", l)
        push!(cats, m.match)
    end
    return (safe = safe, categories = cats, raw = String(raw))
end

# ---------------------------------------------------------------------------
# Embeddings (sarashina3-embedding)
# ---------------------------------------------------------------------------

"""
    embed(client, text; task_type, model=MODELS.embedding) -> Vector{Float64}

POST `/v1/embeddings`. One text per request (up to 8,000 tokens); returns a 1536-dim vector.
`task_type` is required: $(join(EMBEDDING_TASK_TYPES, ", ")).
"""
function embed(c::Client, text::AbstractString; task_type::AbstractString,
               model::AbstractString = MODELS.embedding, kwargs...)
    _check_in("task_type", task_type, EMBEDDING_TASK_TYPES)
    payload = Dict{String,Any}("model" => model, "input" => text, "task_type" => task_type)
    for (k, v) in kwargs
        payload[String(k)] = v
    end
    resp = _parse(_post_json(c, "/v1/embeddings", payload))
    return Float64.(resp["data"][1]["embedding"])
end

# ---------------------------------------------------------------------------
# Rerank (sarashina3-rerank)
# ---------------------------------------------------------------------------

"""
    rerank(client, query, documents; task_type="GENERAL_RETRIEVAL", query_instruction=nothing)

POST `/v1/rerank`. Scores 1–20 `documents` against `query`. `task_type`: $(join(RERANK_TASK_TYPES, ", ")).
`CUSTOMIZE` requires `query_instruction`. Returns a `Vector` of `(document_id, score)` named tuples sorted by score descending;
`document_id` is the 1-based index into `documents`. Scores are ranking signals only
(do not compare across queries or apply an absolute threshold).
"""
function rerank(c::Client, query::AbstractString, documents::AbstractVector{<:AbstractString};
                task_type::AbstractString = "GENERAL_RETRIEVAL",
                query_instruction::Union{Nothing,AbstractString} = nothing,
                model::AbstractString = MODELS.rerank, kwargs...)
    _check_in("task_type", task_type, RERANK_TASK_TYPES)
    1 <= length(documents) <= 20 ||
        throw(ArgumentError("documents must contain 1 to 20 items; got $(length(documents))"))
    task_type == "CUSTOMIZE" && query_instruction === nothing &&
        throw(ArgumentError("query_instruction is required when task_type is CUSTOMIZE"))
    payload = Dict{String,Any}("model" => model, "query" => query,
                               "documents" => collect(String, documents), "task_type" => task_type)
    query_instruction === nothing || (payload["query_instruction"] = query_instruction)
    for (k, v) in kwargs
        payload[String(k)] = v
    end
    resp = _parse(_post_json(c, "/v1/rerank", payload))
    res = resp["data"][1]["result"]
    out = [(document_id = Int(r["document_id"]) + 1, score = Float64(r["score"])) for r in res]
    return sort!(out; by = r -> r.score, rev = true)
end

# ---------------------------------------------------------------------------
# Translate (sarashina3.2-translate)
# ---------------------------------------------------------------------------

"""
    translate(client, text; source_lang, target_lang, style=nothing)

POST `/v1/translate` (ja↔en, up to 5,000 characters, no streaming). `style` is one of
`"auto"`, `"plain"`, `"polite"` (beta; effective only for Japanese output). Returns the translated `String`
(`translated_text`). The `model` is not needed by this endpoint.
"""
function translate(c::Client, text::AbstractString; source_lang::AbstractString,
                   target_lang::AbstractString, style::Union{Nothing,AbstractString} = nothing, kwargs...)
    _check_in("source_lang", source_lang, ("ja", "en"))
    _check_in("target_lang", target_lang, ("ja", "en"))
    source_lang == target_lang && throw(ArgumentError("source_lang and target_lang must differ"))
    length(text) <= 5000 || throw(ArgumentError("text must be at most 5,000 characters"))
    payload = Dict{String,Any}("text" => text, "source_lang" => source_lang, "target_lang" => target_lang)
    if style !== nothing
        _check_in("style", style, ("auto", "plain", "polite"))
        payload["style"] = style
    end
    for (k, v) in kwargs
        payload[String(k)] = v
    end
    return String(_parse(_post_json(c, "/v1/translate", payload))["translated_text"])
end

# ---------------------------------------------------------------------------
# ASR (sarashina3.2-asr)
# ---------------------------------------------------------------------------

"""
    transcribe(client, wav; response_format="json", keywords=nothing, biasing_threshold=nothing)

POST `/v1/audio/transcriptions` (multipart). `wav` is a path or the raw bytes of a WAV file
(16 kHz, 16-bit PCM, mono, 0.1–60 s, at most 2 MiB). `keywords` (a vector of strings) biases
recognition toward proper nouns. Returns the transcript `String` for `json` and `text`, or the full `Dict`
(`text`, `language`, `duration`) for `verbose_json`.
"""
function transcribe(c::Client, wav::Union{AbstractString,AbstractVector{UInt8}};
                    model::AbstractString = MODELS.asr, response_format::AbstractString = "json",
                    keywords = nothing, biasing_threshold = nothing)
    _check_in("response_format", response_format, ASR_FORMATS)
    bytes = wav isa AbstractString ? read(wav) : wav
    length(bytes) <= 2 * 1024 * 1024 || throw(ArgumentError("audio must be at most 2 MiB"))
    fields = Pair{String,Any}[
        "file" => HTTP.Multipart("audio.wav", IOBuffer(bytes), "audio/wav"),
        "model" => model,
        "response_format" => response_format,
    ]
    if keywords !== nothing
        push!(fields, "keywords" => keywords isa AbstractString ? keywords : JSON.json(collect(String, keywords)))
    end
    biasing_threshold === nothing || push!(fields, "biasing_threshold" => string(biasing_threshold))
    form = HTTP.Form(Dict(fields))
    resp = _request(c, "POST", "/v1/audio/transcriptions", form, _headers(c; json = false))
    response_format == "text" && return String(copy(resp.body))
    parsed = _parse(resp)
    return response_format == "json" ? String(parsed["text"]) : parsed
end

# ---------------------------------------------------------------------------
# TTS (sarashina3.2-tts)
# ---------------------------------------------------------------------------

"""
    speak(client, text; voice="ja_f_1", response_format="wav", speed=nothing, seed=nothing, path=nothing)

POST `/v1/audio/speech` (2–700 characters). Returns the audio bytes; if `path` is given, also
writes them there and returns `path`. `voice`: $(join(TTS_VOICES, ", ")). `response_format`:
$(join(TTS_FORMATS, ", ")). `speed` is in 0.25–4.0. Note: TTS is limited to 6 RPM.
"""
function speak(c::Client, text::AbstractString; voice::AbstractString = "ja_f_1",
               response_format::AbstractString = "wav", speed = nothing, seed = nothing,
               path::Union{Nothing,AbstractString} = nothing, model::AbstractString = MODELS.tts)
    2 <= length(text) <= 700 || throw(ArgumentError("text must be 2 to 700 characters"))
    _check_in("voice", voice, TTS_VOICES)
    _check_in("response_format", response_format, TTS_FORMATS)
    payload = Dict{String,Any}("model" => model, "input" => text, "voice" => voice,
                               "response_format" => response_format)
    if speed !== nothing
        0.25 <= speed <= 4.0 || throw(ArgumentError("speed must be in 0.25..4.0"))
        payload["speed"] = speed
    end
    seed === nothing || (payload["seed"] = seed)
    audio = copy(_post_json(c, "/v1/audio/speech", payload).body)
    path === nothing && return audio
    write(path, audio)
    return path
end

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

"""
    list_models(client) -> Vector{String}

GET `/v1/models`. Returns the model IDs. (`sarashina3.2-translate` is not listed by the API.)
"""
function list_models(c::Client)
    resp = _parse(_request(c, "GET", "/v1/models", nothing, _headers(c; json = false)))
    return String[m["id"] for m in resp["data"]]
end

end # module Sarashina
