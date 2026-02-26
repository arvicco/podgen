# Podcast Agent — Claude Code Instructions

## Project Overview
Fully autonomous podcast generation pipeline. Two pipeline types:

1. **News pipeline** (`type: news`): Researches topics, writes a script, generates multi-language audio via TTS, assembles final MP3s.
2. **Language pipeline** (`type: language`): Downloads episodes from RSS, transcribes via multi-engine STT + Claude reconciliation, auto-trims outro music via word timestamps, assembles clean MP3 + formatted transcript.

Zero human involvement beyond editing config files.

**Status:** Production-ready. All phases complete.

---

## Tech Stack
- **Language:** Ruby 3.2+ — **Gems:** anthropic, exa-ai, httparty, dotenv, rexml, rss (all pinned `~> x.y` in Gemfile)
- **APIs:** Anthropic Claude (topics, scripting, translation, web search), Exa.ai (research), ElevenLabs (TTS), OpenAI (transcription — language pipeline)
- **Audio:** ffmpeg via `Open3.capture3` — concat filter, two-pass loudnorm, 44100 Hz mono, 192 kbps MP3
- **Images:** ImageMagick (`magick`) + librsvg (`rsvg-convert`) — SVG text rendering via pango/fontconfig, then composite onto base image
- **Config:** YAML + Markdown — **Platform:** macOS (launchd scheduling)

---

## Project Structure
```
podgen/
├── bin/podgen                    # CLI entry point
├── podcasts/<name>/              # Per-podcast config
│   ├── guidelines.md             # Format, tone, sources, languages
│   ├── queue.yml                 # Fallback topics
│   ├── pronunciation.pls         # TTS pronunciation overrides (optional, PLS/XML format)
│   ├── pronunciation.yml         # Cached dictionary ID from ElevenLabs (auto-generated)
│   └── .env                      # Per-podcast overrides (optional, gitignored)
├── assets/                       # (deprecated — intro/outro now per-podcast)
├── lib/
│   ├── cli.rb                    # CLI dispatcher (OptionParser + command registry)
│   ├── cli/
│   │   ├── version.rb            # PodgenCLI::VERSION
│   │   ├── generate_command.rb   # Pipeline dispatcher: news or language (based on type in ## Podcast)
│   │   ├── translate_command.rb  # Backfill translations for existing episodes + regenerate RSS
│   │   ├── language_pipeline.rb  # Language pipeline: RSS → download → transcribe → trim outro → assemble
│   │   ├── scrap_command.rb     # Remove last episode + history entry
│   │   ├── rss_command.rb        # RSS feed generation + cover copy + transcript conversion
│   │   ├── publish_command.rb    # Publish to Cloudflare R2 via rclone, or to LingQ (--lingq)
│   │   ├── list_command.rb       # List available podcasts
│   │   ├── test_command.rb       # Delegates to test/ (minitest) and scripts/ (diagnostic)
│   │   └── schedule_command.rb   # Installs launchd plist
│   ├── podcast_config.rb         # Resolves all paths, parses sources/languages from guidelines
│   ├── source_manager.rb         # Parallel multi-source research coordinator + cache integration
│   ├── research_cache.rb         # File-based research cache (SHA256 keys, 24h TTL, atomic writes)
│   ├── transcription/
│   │   ├── base_engine.rb        # Shared base class (retries, logging, validation)
│   │   ├── openai_engine.rb      # OpenAI Whisper/gpt-4o-transcribe (engine: "open")
│   │   ├── elevenlabs_engine.rb  # ElevenLabs Scribe v2 (engine: "elab")
│   │   ├── groq_engine.rb        # Groq hosted Whisper + word timestamps (engine: "groq")
│   │   ├── engine_manager.rb     # Orchestrator: single or parallel comparison mode, primary fallback
│   │   └── reconciler.rb         # Claude Opus reconciliation + formatting of multi-engine transcripts
│   ├── agents/
│   │   ├── topic_agent.rb        # Claude topic generation
│   │   ├── research_agent.rb     # Exa.ai search
│   │   ├── script_agent.rb       # Claude script generation (structured output)
│   │   ├── tts_agent.rb          # ElevenLabs TTS (chunking, UTF-8-safe splitting, pronunciation dictionaries, trailing hallucination trimming)
│   │   ├── translation_agent.rb  # Claude script translation
│   │   ├── transcription_agent.rb # Backward-compat shim → Transcription::OpenaiEngine
│   │   ├── lingq_agent.rb        # LingQ lesson upload (language pipeline)
│   │   └── cover_agent.rb        # ImageMagick cover image generation (language pipeline)
│   ├── sources/
│   │   ├── rss_source.rb         # RSS/Atom feeds (topic matching + episode fetching)
│   │   ├── hn_source.rb          # Hacker News Algolia API
│   │   ├── claude_web_source.rb  # Claude + web_search tool (configurable model/max_results)
│   │   ├── bluesky_source.rb    # Bluesky AT Protocol authenticated post search
│   │   └── x_source.rb          # X (Twitter) via SocialData.tools API
│   ├── episode_history.rb        # Episode dedup (atomic YAML writes, 7-day lookback)
│   ├── audio_assembler.rb        # ffmpeg wrapper (crossfades, loudnorm, trim, extract)
│   ├── rss_generator.rb          # RSS 2.0 + iTunes + Podcasting 2.0 feed (cover, transcripts)
│   └── logger.rb                 # Structured run logging with phase timings
├── docs/
│   └── pronunciation.md          # PLS format guide, IPA reference, alias vs phoneme rules
├── Rakefile                      # rake test, rake test:unit, test:integration, test:api
├── test/
│   ├── test_helper.rb            # Minitest setup, skip helpers
│   ├── unit/                     # Pure logic tests (no external deps)
│   ├── integration/              # Needs ffmpeg or filesystem fixtures
│   └── api/                      # Needs API keys + network (auto-skip when missing)
├── scripts/
│   ├── serve.rb                  # WEBrick static file server (correct MIME types for mp3/xml/md)
│   └── test_*.rb                 # Diagnostic scripts (transcription, cover, lingq_upload, trim)
├── output/<name>/
│   ├── episodes/                 # MP3s + scripts/transcripts: {name}-{date}[-lang].mp3
│   ├── tails/                    # Trimmed outro tails for review: {name}-{date}_tail.mp3
│   ├── research_cache/           # Cached research results (auto-managed)
│   ├── history.yml               # Episode history for deduplication
│   ├── lingq_uploads.yml         # LingQ upload tracking (collection → base_name → lesson_id)
│   ├── cover.jpg                 # Podcast cover (copied from podcasts/<name>/ by rss command)
│   └── feed.xml                  # RSS feed
└── logs/<name>/                  # Per-podcast run logs
```

---

## Pipeline Flow

### News pipeline (type: `news`, default)
```
generate_command.rb:
  1. Load config + verify prerequisites (ffmpeg, guidelines)
  2. Topics:    TopicAgent (Claude) → fallback: queue.yml
  3. Research:  SourceManager → parallel threads per source → cache → merge + dedup
  4. Script:    ScriptAgent (Claude structured output) → save _script.md
  5. Per language:
     a. Translation (skip English) → TranslationAgent (Claude)
     b. TTS → TTSAgent (ElevenLabs, chunked)
     c. Assembly → AudioAssembler (ffmpeg: concat + crossfade + loudnorm)
  6. Record history → done
```

### Language pipeline (type: `language`)
```
language_pipeline.rb:
  1. Fetch next episode from RSS (exclude already-processed URLs)
  2. Download source audio + skip fixed intro (if configured)
  3. Transcribe full audio via EngineManager (all engines in parallel)
     - Groq returns word-level timestamps alongside text
     - Reconciler (Claude Opus) drops hallucinated content, produces clean text
  4. Trim outro via reconciled text + Groq word timestamps:
     a. Match last words of reconciled text in Groq's word timestamps
     b. speech_end = matched word's end timestamp + 2s padding
     c. Trim audio at speech_end, save tail for review
     (Requires 2+ engines with groq; single engine → no outro detection)
  5. Build transcript from reconciled text (or raw text if single engine)
  6. Assemble: intro.mp3 + trimmed audio + outro.mp3 → loudnorm
  7. Save transcript(s) — primary + per-engine files in comparison mode
  8. LingQ upload (only with --lingq flag, if ## LingQ section + LINGQ_API_KEY present) — non-fatal
     - Cover generation: if `base_image` configured, overlays uppercased title via ImageMagick
  9. Record history → done
```

### Key behaviors
- **Multi-podcast:** Each podcast in `podcasts/<name>/` with own config. CLI: `podgen generate <name>`
- **Multi-language:** `language` list in `## Podcast` section. English script generated first, translated for other languages. Per-language voice IDs. Output: `name-date-lang.mp3`
- **Same-day suffix:** `name-2026-02-18.mp3`, then `name-2026-02-18a.mp3`, etc.
- **Episode dedup:** History records topics + URLs; TopicAgent avoids repeats, sources exclude used URLs. 7-day lookback window.
- **Translate:** `podgen translate <name>` backfills translations for existing episodes. Discovers untranslated episodes by checking if `{basename}-{lang}.mp3` exists for each English `_script.md`. Translates, synthesizes TTS, assembles MP3s, then regenerates RSS feeds. Supports `--last N` (limit to N most recent), `--lang xx` (single language), `--dry-run`.
- **Scrap:** `podgen scrap <name>` removes last episode files (MP3 + scripts, all languages) and last history entry. Supports `--dry-run`.
- **Research sources:** Parallel execution via threads. Sources: `exa`, `hackernews`, `rss` (with feed URLs), `claude_web`, `bluesky`, `x`. Default: exa only. 24h file-based cache per source+topics.
- **Transcript post-processing:** Claude Opus processes all transcripts. Multi-engine (2+ engines): reconciles sentence-by-sentence, picks best rendering, removes hallucination artifacts. Single engine: cleans up grammar, punctuation, and STT artifacts. Both modes format output with paragraphs, dialog in straight quotes `"..."`, separate speaker turns. Result becomes primary transcript. Non-fatal if post-processing fails.
- **Outro detection:** In multi-engine mode with Groq, the reconciled text (hallucination-free) is mapped back to Groq's word-level timestamps to find precise speech end. Audio is trimmed at speech_end + 2s; the tail is saved to `output/<podcast>/tails/` for review. Requires 2+ engines with "groq" included. Single engine or no Groq → no outro detection.
- **LingQ upload:** Requires `--lingq` flag. Two modes: (1) `podgen generate <name> --lingq` uploads during generation (same as before, non-fatal). (2) `podgen publish <name> --lingq` bulk-uploads all un-uploaded episodes from episodes dir. Tracks uploads in `output/<podcast>/lingq_uploads.yml` (keyed by collection ID → base_name → lesson_id). Switching `collection` in config uploads to the new collection without losing previous tracking. Supports `--dry-run`.
- **Cover generation:** If `base_image` is configured in `## LingQ`, generates per-episode cover images by overlaying the uppercased episode title onto the base image via ImageMagick. Falls back to static `image` if generation fails or ImageMagick is not installed. Non-fatal.
- **Pronunciation dictionaries:** Optional `podcasts/<name>/pronunciation.pls` file with alias or IPA rules for mispronounced terms. Uploaded to ElevenLabs on first TTS run; cached in `pronunciation.yml` (re-uploads when PLS file changes). Alias rules work with all models; IPA phoneme rules only work with `eleven_flash_v2`/`eleven_turbo_v2`/`eleven_monolingual_v1`. Max 3 dictionaries per request. Non-fatal if upload fails. See `docs/pronunciation.md` for PLS format and IPA reference.
- **TTS trailing hallucination trimming:** TTSAgent uses `/with-timestamps` endpoint to get character-level alignment. Audio after the last character's end time + 0.5s threshold is replaced with silence (preserving segment duration/pacing). Logged per-chunk.
- **RSS feed:** `podgen rss <name>` generates feed with iTunes + Podcasting 2.0 namespaces. Copies cover image from `podcasts/<name>/` to output. Converts markdown transcripts and scripts to HTML and adds `<podcast:transcript>` tags. Episode titles pulled from `history.yml`. `base_url` from config ensures correct absolute enclosure URLs.
- **`--dry-run`:** Validates config, uses queue.yml topics, generates synthetic data, saves debug script, skips all API calls/TTS/assembly/history/LingQ upload.
- **Lockfile:** Prevents concurrent runs of the same podcast via `flock`.
- **Publish:** `podgen publish <name>` syncs public-facing files (MP3s, HTML transcripts, feed XML, cover) to Cloudflare R2 via `rclone`. Uses env-based rclone config (no `rclone config` needed). With `--lingq`, publishes to LingQ instead of R2 (bulk upload with tracking). Supports `--dry-run` and `-v`.

---

## Configuration

### guidelines.md sections
| Section | Required | Description |
|---------|----------|-------------|
| `## Podcast` | No | Key-value list: `name` (fallback: dir name), `type` (`news`/`language`, default: news), `author` (fallback: "Podcast Agent"), `description` (RSS feed description), `language` (sub-list: `- en`, `- it: <voice_id>`, default: `[en]`), `base_url` (for RSS enclosure URLs, e.g. `https://host.ts.net/podcast`), `image` (cover artwork filename, must be in `podcasts/<name>/`, copied to output on `podgen rss`) |
| `## Format` | Yes | Length, segment structure, pacing |
| `## Tone` | Yes | Voice and style directions |
| `## Topics` | Yes (news) | Default topic rotation |
| `## Sources` | No | `- exa`, `- hackernews`, `- rss:` (with URLs), `- claude_web`, `- bluesky`, `- x:`. Default: exa |
| `## Audio` | No | Key-value list: `engine` (sub-list: `- open`, `- elab`, `- groq`, default: `[open]`), `language` (ISO-639-1 code), `target_language` (human-readable name), `skip_intro` (seconds to cut) |
| `## LingQ` | No | LingQ upload config: `collection`, `level`, `tags`, `image`, `base_image`, `font`, `font_color`, `font_size`, `text_width`, `text_gravity`, `text_x_offset`, `text_y_offset`, `accent`, `status`. Requires `LINGQ_API_KEY` |
| `## Do not include` | No | Content restrictions |

### Environment variables
**Root `.env`:** `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID` (default: eleven_multilingual_v2), `ELEVENLABS_OUTPUT_FORMAT` (default: mp3_44100_128), `ELEVENLABS_SCRIBE_MODEL` (default: scribe_v2), `EXA_API_KEY`, `CLAUDE_MODEL` (default: claude-opus-4-6), `CLAUDE_WEB_MODEL` (default: claude-haiku-4-5-20251001), `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `SOCIALDATA_API_KEY`, `OPENAI_API_KEY` (language pipeline), `WHISPER_MODEL` (default: gpt-4o-mini-transcribe), `GROQ_API_KEY`, `GROQ_WHISPER_MODEL` (default: whisper-large-v3), `LINGQ_API_KEY` (language pipeline LingQ upload), `R2_ACCESS_KEY_ID` (publish command), `R2_SECRET_ACCESS_KEY` (publish command), `R2_ENDPOINT` (publish command, e.g. `https://<account_id>.r2.cloudflarestorage.com`), `R2_BUCKET` (publish command)

**Per-podcast `.env`** (optional): overrides any root `.env` variable. Loaded via `Dotenv.overload`.

---

## Coding Standards
- Single responsibility per class/method
- All API calls wrapped in retry with exponential backoff
- API keys only from ENV, never hardcoded
- File paths via `File.join` + `__dir__`-relative resolution; `require_relative` throughout
- Atomic file writes (temp + rename) for history and cache
- All shell commands via `Open3.capture3` — capture stdout, stderr, exit status
- Gems pinned to minor versions in Gemfile
- Research data normalized to symbol keys: `[{ topic:, findings: [{ title:, url:, summary: }] }]`
- ScriptAgent validates research data structure before API call
- TTS text splitting: paragraph → sentence → comma/semicolon → whitespace → UTF-8-safe char boundary
- ffprobe duration caching to avoid redundant calls

---

## CLI Reference
```
podgen [flags] <command> <args>
  generate <podcast>   # Full pipeline (--lingq to upload to LingQ during generation)
  translate <podcast>  # Translate episodes to new languages (--last N, --lang xx)
  scrap <podcast>      # Remove last episode + history entry
  rss <podcast>        # Generate RSS feed (--base-url URL to override config)
  publish <podcast>    # Publish to Cloudflare R2 (--lingq to publish to LingQ instead)
  stats <podcast>      # Show podcast statistics (--all for summary table)
  validate <podcast>   # Validate config and output (--all for all podcasts)
  list                 # List podcasts
  test <name>          # Run test (research|rss|hn|claude_web|bluesky|x|script|tts|assembly|translation|transcription|sources|cover|stats_validate|trim|lingq_upload|all)
  schedule <podcast>   # Install launchd scheduler

Flags: -v/--verbose  -q/--quiet  --dry-run  --lingq  -V/--version  -h/--help
```

---

## Serving RSS Externally (Tailscale Funnel)

Podcasts can be served externally via Tailscale Funnel, which provides a public HTTPS URL without port forwarding or domain setup.

### Setup steps
1. **Install Tailscale:** `brew install tailscale` — start with `sudo tailscaled` + `tailscale up`
2. **Enable HTTPS + Funnel in admin console:** [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns) — enable MagicDNS and HTTPS certificates. Then [Access Controls](https://login.tailscale.com/admin/acls/file) — add `"nodeAttrs": [{"target": ["*"], "attr": ["funnel"]}]`
3. **Provision HTTPS cert:** `tailscale cert <hostname>.ts.net` (generates `.crt` + `.key` files)
4. **Start local server:** `ruby scripts/serve.rb 8080` — serves `output/` with correct MIME types
5. **Start funnel:** `tailscale funnel 8080` — exposes port 8080 at `https://<hostname>.ts.net`
6. **Configure podcast:** Add `base_url: https://<hostname>.ts.net/<podcast>` to `## Podcast` section in guidelines.md
7. **Generate feed:** `podgen rss <podcast>` — feed URL: `https://<hostname>.ts.net/<podcast>/feed.xml`

### Notes
- Chrome may show `NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED` — works fine in Safari, Firefox, and podcast apps
- Tailscale Funnel requires the machine to be online and the server running
- `scripts/serve.rb` serves mp3 as `audio/mpeg`, xml as `application/rss+xml`, md as `text/markdown`

---

## Known Constraints
- ElevenLabs eleven_multilingual_v2: 10,000 char per-request limit (TTSAgent splits automatically)
- ffmpeg must be on `$PATH` — checked at startup with clear error message
- Stereo music + mono TTS: all inputs forced to mono 44100 Hz in filter graph
- macOS must be awake at scheduled time — recommend plugged-in + sleep disabled
- launchd plist requires absolute paths — `run.sh` resolves dynamically
- Cover generation requires `imagemagick` + `librsvg` (`brew install imagemagick librsvg`) and fonts via `fontconfig` (`brew install fontconfig`). Homebrew ImageMagick lacks Freetype, so text is rendered via SVG/rsvg-convert/pango instead

---

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date
