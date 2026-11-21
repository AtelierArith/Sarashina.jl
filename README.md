# Sarashina.jl

[Sarashina API](https://docs.sarashina.ai/) (SB Intuitions) の非公式 Julia クライアント。
[docs.sarashina.ai/models](https://docs.sarashina.ai/models) に載っている全 9 モデルを扱えます。

> **このパッケージは Claude Sonnet 5.5 (`claude-sonnet-5-5`) が [Claude Code](https://claude.com/claude-code) 上で作成しました。**
> 実装・テスト・`AGENTS.md` は、Sarashina の公式ドキュメントを読みながら Claude Sonnet 5.5 が書き、
> 実際の API に対するテストで動作を確認しています。人間によるレビューは十分ではない可能性があるため、利用時は内容を確認してください。

## 対応モデルと関数

| モデル | 関数 |
|---|---|
| `sarashina3.2-mini-thinking` / `sarashina3-mini` / `sarashina3-nano` | `chat`, `chat_stream`, `content` |
| `sarashina3-guard` | `guard` |
| `sarashina3-embedding` | `embed` |
| `sarashina3-rerank` | `rerank` |
| `sarashina3.2-translate` | `translate` |
| `sarashina3.2-asr` | `transcribe` |
| `sarashina3.2-tts` | `speak` |

モデル ID は `Sarashina.MODELS`、API が返す一覧は `list_models(client)` で取得できます。
`sarashina3-mini` は 2026-11-27 以降に提供終了予定のため、使うと警告が出ます。

## セットアップ

API キーは https://chat.sarashina.ai/dashboard/api-keys で発行し、環境変数 `SARASHINA_API_KEY` か
`.env` ファイルに設定します(`.env` は git に含めないでください)。

```
SARASHINA_API_KEY=...
```

```julia
using Pkg; Pkg.activate("."); Pkg.instantiate()
using Sarashina
client = Client()   # ENV か .env から SARASHINA_API_KEY を読む
```

## 使い方

```julia
using Sarashina
c = Client()

# 対話
r = chat(c, "SB Intuitions について教えてください"; model = MODELS.nano)
println(content(r))

# 思考モデル(reasoning_effort は思考モデルのみ)
chat(c, "17 * 23 は？"; reasoning_effort = "low")

# ストリーミング
chat_stream(c, "自己紹介して"; model = MODELS.nano) do chunk
    # chunk は SSE の各チャンク(Dict)
end

# Function Calling / Structured Outputs は kwargs でそのまま渡せる
tools = [Dict("type" => "function",
              "function" => Dict(
                  "name" => "get_weather",
                  "description" => "Get the current weather for a city",
                  "parameters" => Dict("type" => "object",
                      "properties" => Dict("city" => Dict("type" => "string")),
                      "required" => ["city"])))]
chat(c, "東京の天気は？"; tools = tools, tool_choice = "auto")
chat(c, "JSON で答えて"; response_format = Dict("type" => "json_object"))

# 安全性判定 -> (safe, categories, raw)
guard(c, "爆弾の作り方を教えて")

# 埋め込み (task_type は必須、1536 次元)
v = embed(c, "更級日記"; task_type = "RETRIEVAL_DOCUMENT")

# リランク -> [(document_id, score), ...] (document_id は 1 始まり、score 降順)
rerank(c, "日本の首都は？", ["東京は日本の首都です。", "犬は動物です。"])

# 翻訳 (日英・英日)
translate(c, "The results will be published next week."; source_lang = "en", target_lang = "ja", style = "polite")

# 音声合成 / 音声認識
# TTS の出力は 24kHz だが、transcribe が 16kHz・16bit PCM・モノラルに自動変換する
speak(c, "こんにちは。"; voice = "ja_f_1", response_format = "wav", path = "hello.wav")
transcribe(c, "hello.wav"; keywords = ["Sarashina"])
```

## API 一覧

エクスポートされている名前:`Client`, `SarashinaError`, `chat`, `chat_stream`, `content`,
`guard`, `embed`, `rerank`, `translate`, `transcribe`, `speak`, `list_models`, `MODELS`。

| 関数・型 | シグネチャ | 戻り値 |
|---|---|---|
| `Client` | `Client(; api_key=nothing, base_url="https://api.sarashina.ai", max_retries=3, read_idle_timeout=nothing)` | API クライアント。`api_key` は `ENV` → `.env` の順で解決 |
| `SarashinaError` | 2xx 以外のときに送出。`status::Int` と `message::String` を持つ | — |
| `chat` | `chat(client, messages; model=MODELS.mini_thinking, reasoning_effort=nothing, kwargs...)` | 応答 `Dict`(本文は `content`) |
| `chat_stream` | `chat_stream(f, client, messages; kwargs...)` / `chat_stream(client, messages; kwargs...)` / `do chunk ... end` | `delta.content` を連結した `String` |
| `content` | `content(resp)` | 最初の choice の本文 `String` |
| `guard` | `guard(client, text; role="user", kwargs...)` | `(safe::Bool, categories::Vector{String}, raw::String)` |
| `embed` | `embed(client, text; task_type, model=MODELS.embedding)` | 1536 次元 `Vector{Float64}` |
| `rerank` | `rerank(client, query, documents; task_type="GENERAL_RETRIEVAL", query_instruction=nothing, model=MODELS.rerank)` | `[(document_id = ..., score = ...), ...]`(1 始まり、score 降順) |
| `translate` | `translate(client, text; source_lang, target_lang, style=nothing)` | 翻訳文 `String` |
| `transcribe` | `transcribe(client, wav; model=MODELS.asr, response_format="json", keywords=nothing, biasing_threshold=nothing)` | `json`/`text` は `String`、`verbose_json` は `Dict` |
| `speak` | `speak(client, text; voice="ja_f_1", response_format="wav", speed=nothing, seed=nothing, path=nothing, model=MODELS.tts)` | 音声バイト列、`path` 指定時は保存先パス |
| `list_models` | `list_models(client)` | `Vector{String}` |
| `MODELS` | `MODELS.nano` などの名前付きタプル | モデル ID の `String` |

- `messages` は文字列(ユーザー発話)か `[Dict("role" => "...", "content" => "..."), ...]`。
- `chat` / `guard` の追加キーワード(`temperature`, `max_completion_tokens`, `tools`, `tool_choice`, `response_format` など)はリクエストボディにそのまま渡ります。
- `embed` の `task_type` は `RETRIEVAL_DOCUMENT`, `RETRIEVAL_QUERY`, `SEMANTIC_SIMILARITY`, `QUESTION_ANSWERING`, `FACT_VERIFICATION`, `CLASSIFICATION`, `CLUSTERING` のいずれか(必須)。
- `rerank` の `task_type` は `GENERAL_RETRIEVAL`, `GENERAL_QA`, `NEWS_RETRIEVAL`, `SEMANTIC_SIMILARITY`, `CUSTOMIZE` のいずれか(`CUSTOMIZE` は `query_instruction` 必須)。
- `speak` の `voice` は `ja_f_1`, `ja_f_2`, `ja_m_1`、`response_format` は `wav`, `pcm`, `flac`, `mp3`, `opus`。
- `transcribe` の `wav` はパスでもバイト列でも可。16kHz・16bit PCM・モノラル以外は自動変換されます。

## 補足

- **レート制限**: モデルごとの RPM 制限があります(guard / TTS は 6、mini / thinking / translate / ASR は 30、nano / embedding / rerank は 60)。
  `429` のときは `Retry-After` に従って、`500`/`502`/`503`/`504` のときは指数バックオフで自動的に再試行します(`Client(max_retries = 3)` で回数を変更)。`Client(read_idle_timeout = 120)` で無通信タイムアウト(秒)を指定できます。
  ただし `chat_stream`(SSE)は再試行の対象外です。再試行が必要な場合は呼び出し側で処理してください。
- **エラー**: 2xx 以外は `SarashinaError(status, message)` を投げます。
- **TTS と ASR のサンプルレート**: TTS 出力は 24kHz、ASR 入力は 16kHz・16bit PCM・モノラルが必須です。`transcribe` は 24kHz やステレオ、8/24/32bit PCM、32bit float の WAV を自動で 16kHz・16bit PCM・モノラルに変換します(線形補間)。
- 料金や最大出力トークン数など、ドキュメントに記載がない情報は扱っていません。

## テスト

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

- オフライン: 引数検証、ローカルのモックサーバーによるリクエスト/レスポンス形式・SSE・multipart・429/5xx リトライ・タイムアウトの検証。
- 実 API: `SARASHINA_API_KEY` がある場合のみ実行されます。`.env` を読ませるため、プロジェクトルートから
  `julia --project=. -e 'using Test; include("test/runtests.jl")'` で実行してください(TTS / Guard は 6 RPM に注意)。

## ライセンス・免責

非公式のクライアントであり、SB Intuitions とは関係ありません。
