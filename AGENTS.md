# AGENTS.md

Sarashina.jl は Sarashina API (https://docs.sarashina.ai/) 向けの Julia クライアントパッケージ。
`/models` の全 9 モデル(chat 3 種・guard・embedding・rerank・translate・ASR・TTS)を扱える。

## プロジェクト構成

- `Project.toml` — 依存: `HTTP`, `JSON`, `DotEnv`
- `src/Sarashina.jl` — モジュール本体(`Client`, `SarashinaError`, `chat`, `chat_stream`, `content`, `guard`, `embed`, `rerank`, `translate`, `transcribe`, `speak`, `list_models`, `MODELS`)
- `test/runtests.jl` — オフライン検証(引数検証・WAV 変換)+ 実 API テスト(キーがある場合のみ)
- `test/mock_tests.jl` — ローカルモックサーバーに対するリクエスト/レスポンス・SSE・multipart・リトライの検証
- `.env` — `SARASHINA_API_KEY` を保持(git 管理外にすること。下記「秘密情報」参照)

## 秘密情報の扱い

- **`.env` の中身を読まない・出力しない。** 存在確認だけ行う。
- API キーの確認例(値は出力しない):

  ```julia
  using DotEnv
  cfg = DotEnv.config()          # EnvOverlay を返す。`cfg.dict` は存在しない
  haskey(cfg, "SARASHINA_API_KEY")
  ```

- DotEnv v1 の `config()` の戻り値は `DotEnv.EnvOverlay`。`haskey` / `get` / インデックスで参照する。
- ログ・エラーメッセージ・テスト出力に `Authorization` ヘッダーを含めない。

## Sarashina API 仕様(2026-11-20 時点のドキュメント)

- ベース URL: `https://api.sarashina.ai`(パスは `/v1` 配下)
- 認証: `Authorization: Bearer <SARASHINA_API_KEY>`
- エラー: 4xx/5xx は JSON `{"message": "..."}`。`429` は `Retry-After`(秒、整数)に従って再試行する。

### エンドポイント

| メソッド・パス | 用途 | 要点 |
|---|---|---|
| `POST /v1/chat/completions` | 対話生成 | Function Calling、Structured Outputs(`response_format` の `json_schema` / `json_object`)、`reasoning_effort`、`stream=true` で SSE。Guard もここ経由 |
| `POST /v1/embeddings` | ベクトル化 | 1536 次元。1 リクエスト 1 テキスト、8,000 トークンまで。`task_type` **必須** |
| `POST /v1/rerank` | リランク | クエリ 1 件、文書 1〜20 件。`task_type` 既定 `GENERAL_RETRIEVAL`。`CUSTOMIZE` は `query_instruction` 必須 |
| `POST /v1/translate` | 日英・英日翻訳 | `source_lang`/`target_lang` は `ja`/`en`。`style`: `auto`/`plain`/`polite`(β、日本語訳のみ)。5,000 文字まで。ストリーミング非対応。`model` 不要 |
| `POST /v1/audio/transcriptions` | 音声認識 | multipart。WAV(16kHz・16bit PCM・モノラル、0.1〜60 秒)。`response_format`: `json`/`text`/`verbose_json`。`keywords`(JSON 配列文字列、最大 200 語・各 1〜64 文字)、`biasing_threshold`((0,1]、既定 0.5)。他形式の WAV は `transcribe` が自動変換する |
| `POST /v1/audio/speech` | 音声合成 | `input` 2〜700 文字。`voice`: `ja_f_1`/`ja_f_2`/`ja_m_1`。形式 wav/pcm/flac/mp3/opus。`speed` 0.25〜4.0、`seed` 可。バイナリを返す。出力は wav/pcm/flac/mp3 が 24kHz、opus が 48kHz でいずれもモノラル |
| `GET /v1/models` | モデル一覧 | OpenAI 互換。`/v1/models/{id}` は無い。`sarashina3.2-translate` は一覧に含まれない |

- `embeddings` の `task_type`: `RETRIEVAL_DOCUMENT` / `RETRIEVAL_QUERY` / `SEMANTIC_SIMILARITY` / `QUESTION_ANSWERING` / `FACT_VERIFICATION` / `CLASSIFICATION` / `CLUSTERING`
- `rerank` の `task_type`: `GENERAL_RETRIEVAL` / `GENERAL_QA` / `NEWS_RETRIEVAL` / `SEMANTIC_SIMILARITY` / `CUSTOMIZE`
- リクエストサイズ上限(超過で 413): Chat / Embeddings / Rerank / TTS は 4MiB、Translate は 1MiB、ASR は 2MiB

### モデル ID

| ID | 用途 | 入力上限 |
|---|---|---|
| `sarashina3.2-mini-thinking` | 思考モデル(`reasoning_effort`: low/medium/high)、Tool calling | 128k |
| `sarashina3-mini` | 標準対話、Tool calling。**2026-11-27 以降に提供終了予定**(後継は 3.2-mini-thinking) | 128k |
| `sarashina3-nano` | 高速・軽量 | 128k |
| `sarashina3-guard` | 安全性判定(「安全」/「有害」+ T1〜T12) | 64k |
| `sarashina3-embedding` | Embeddings | 8,000 tokens |
| `sarashina3-rerank` | Rerank | 8,000 tokens(クエリ+最長文書) |
| `sarashina3.2-translate` | Translate | 5,000 文字 |
| `sarashina3.2-asr` | ASR | 60 秒 |
| `sarashina3.2-tts` | TTS | 700 文字 |

- デフォルトモデルに `sarashina3-mini` を使わない(提供終了予定)。`sarashina3.2-mini-thinking` か `sarashina3-nano` を使う。
- 料金・最大出力トークン数はドキュメントに記載がない。推測で実装に埋め込まない。

### レート制限

契約主体 × モデルごとの RPM。60 秒の固定窓で判定し、バーストは不可。TPM・同時実行数の記載はない。

| モデル | RPM |
|---|---|
| `sarashina3-guard`, `sarashina3.2-tts` | 6 |
| `sarashina3.2-mini-thinking`, `sarashina3-mini`, `sarashina3.2-translate`, `sarashina3.2-asr` | 30 |
| `sarashina3-nano`, `sarashina3-embedding`, `sarashina3-rerank` | 60 |

- 429 時は `Retry-After` 秒(最大 120 秒)待って再試行する。500/502/503/504 は指数バックオフ(1, 2, 4, … 最大 30 秒)で再試行する。いずれも `Client` の `max_retries` 回まで(クライアントに実装済み)。ただし `chat_stream` は対象外(呼び出し側で処理する)。
- `X-RateLimit-*` 系ヘッダーは返らないため、残数をヘッダーから取得する実装は不可。
- テストで実 API を叩く場合は上記 RPM に注意する。特に TTS / Guard は 6 RPM。

## 実装メモ

- リクエストのフィールド名はリファレンスで確認済み: translate は `text` → 応答 `translated_text`、embeddings は `data[1].embedding`、rerank は `data[1].result[]`(`document_id` は 0 始まり、`Sarashina.rerank` は 1 始まりに変換)、ASR は `text`(`verbose_json` で `language`/`duration`)。
- ASR の `keywords` は JSON 配列文字列で送る。TTS 出力は 24kHz、ASR 入力は 16kHz・16bit PCM・モノラル必須だが、`transcribe` が WAV ヘッダを読んで自動変換する(`_to_asr_wav`。16kHz/16bit/モノラルの PCM はそのまま送る。非 WAV や解析できない形式はそのまま送って API のエラーに任せる)。
- Guard は `chat` 経由で、応答は `安全` または `有害\nT8, T9` 形式。`tools`/`tool_choice` は不可。
- `reasoning_effort` は思考モデルのみ(非思考モデルに指定すると 400)。
- `HTTP.request` には必ず `retry = false` を渡す。HTTP.jl 自身のリトライ(冪等な GET は 429 でも最大 4 回)が `Retry-After` を無視し、`Sarashina._request` の再試行と二重になる(モックテストで判明: 想定 3 回のところ 15 回リクエストしていた)。429 と 5xx は `_request` だけで処理する。
- `chat_stream` は `HTTP.open` を直接使うため `_request` を通らず、**429/5xx の再試行をしない**(意図した仕様。モックテストで「429 でもリクエストは 1 回だけ」を固定している)。SSE のパースは `data:` 行のみを見て `[DONE]` で終了し、`choices` が空の usage チャンクは無視する。改行は LF/CRLF の両方を許容する。
- `transcribe` の WAV 変換:`_wav_info` が RIFF/WAVE ヘッダ(fmt / data チャンク)を読み、`_wav_samples` が 8/16/24/32bit PCM と 32bit float を Float64 にデコードしてチャンネルを平均でモノラル化、`_resample` が線形補間で 16kHz に変換し、`_encode_wav16k` が 16bit PCM の WAV を組み立てる。16kHz・16bit・モノラル PCM はそのまま送る。非 WAV や未対応形式はそのまま送って API のエラーに任せる。2MiB の上限チェックは変換後のバイト列に対して行う。
- `test/mock_tests.jl` は `HTTP.serve!` のローカルモックサーバーで、リクエスト/レスポンス形式・SSE(チャンク型、usage のみの最終チャンク、CRLF/コメント行、do-block 省略、429 非再試行)・multipart・429/5xx リトライ・`read_idle_timeout` を検証する。サーバー起動後に定義した応答関数を呼ぶため `Base.invokelatest` が必要(world age エラー回避)。リクエストごとの本文は `REQUESTS` に記録される。`test/runtests.jl` の `make_pcm16_wav` でテスト用 WAV を生成し、`WAV conversion for ASR` テストセットが 24kHz→16kHz、ステレオ→モノラル、8kHz→16kHz、適合済み WAV のパススルーを確認する。
- 実 API テストは `Pkg.test()` だとカレントが違い `.env` が見つからずスキップされる。プロジェクトルートから `julia --project=. -e 'using Test; include("test/runtests.jl")'` で実行する。TTS/Guard は 6 RPM なので連続実行に注意。
- README の「API 一覧」は `names(Sarashina)` のエクスポートと一致させる。エクスポートを変えたら `julia --project=. -e 'using Sarashina; println(sort(filter(n -> n != :Sarashina, names(Sarashina))))'` で確認して README を更新する。

## ドキュメントの既知の不整合

- モデル性能ページで `Sarashina3 mini` のスコアが表間で食い違う(例: BFCL v3 が 0.598 と 0.67)。性能値を実装やドキュメントに引用するときは出典の表を明記する。

## 参照

- https://docs.sarashina.ai/
- API リファレンス: `/api-reference/{chat-completions,embeddings,rerank,translate,speech-recognition,speech-synthesis,models}`
- `/models`, `/model-performance`, `/rate-limits`
