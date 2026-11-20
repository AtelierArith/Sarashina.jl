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
chat(c, "天気は？"; tools = [...], tool_choice = "auto")
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
speak(c, "こんにちは。"; voice = "ja_f_1", response_format = "wav", path = "hello.wav")
transcribe(c, "audio.wav"; keywords = ["Sarashina"])   # WAV: 16kHz・16bit PCM・モノラル、0.1〜60 秒
```

## 補足

- **レート制限**: モデルごとの RPM 制限があります(guard / TTS は 6、mini / thinking / translate / ASR は 30、nano / embedding / rerank は 60)。
  `429` のときは `Retry-After` に従って自動で再試行します(`Client(max_retries = 3)` で回数を変更)。
- **エラー**: 2xx 以外は `SarashinaError(status, message)` を投げます。
- **TTS と ASR のサンプルレート**: TTS 出力は 24kHz、ASR 入力は 16kHz が必須です。
- 料金や最大出力トークン数など、ドキュメントに記載がない情報は扱っていません。

## テスト

```
julia --project=. -e 'using Pkg; Pkg.test()'
```

- オフライン: 引数検証、ローカルのモックサーバーによるリクエスト/レスポンス形式・SSE・multipart・429 リトライの検証。
- 実 API: `SARASHINA_API_KEY` がある場合のみ実行されます。`.env` を読ませるため、プロジェクトルートから
  `julia --project=. -e 'using Test; include("test/runtests.jl")'` で実行してください(TTS / Guard は 6 RPM に注意)。

## ライセンス・免責

非公式のクライアントであり、SB Intuitions とは関係ありません。
