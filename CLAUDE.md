# Podcast Agent — Claude Code Instructions

## Project Overview
Fully autonomous podcast generation pipeline. Two pipeline types:

1. **News pipeline** (`type: news`): Researches topics, writes a script, generates multi-language audio via TTS, assembles final MP3s.
2. **Language pipeline** (`type: language`): Downloads episodes from RSS, strips intro/outro music, transcribes via OpenAI Whisper, assembles clean MP3 + transcript.

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
│   └── .env                      # Per-podcast overrides (optional, gitignored)
├── assets/                       # (deprecated — intro/outro now per-podcast)
├── lib/
│   ├── cli.rb                    # CLI dispatcher (OptionParser + command registry)
│   ├── cli/
│   │   ├── version.rb            # PodgenCLI::VERSION
│   │   ├── generate_command.rb   # Pipeline dispatcher: news or language (based on type in ## Podcast)
│   │   ├── language_pipeline.rb  # Language pipeline: RSS → download → trim → transcribe → assemble
│   │   ├── scrap_command.rb     # Remove last episode + history entry
│   │   ├── rss_command.rb        # RSS feed generation + cover copy + transcript conversion
│   │   ├── list_command.rb       # List available podcasts
│   │   ├── test_command.rb       # Delegates to scripts/test_*.rb
│   │   └── schedule_command.rb   # Installs launchd plist
│   ├── podcast_config.rb         # Resolves all paths, parses sources/languages from guidelines
│   ├── source_manager.rb         # Parallel multi-source research coordinator + cache integration
│   ├── research_cache.rb         # File-based research cache (SHA256 keys, 24h TTL, atomic writes)
│   ├── transcription/
│   │   ├── base_engine.rb        # Shared base class (retries, logging, validation)
│   │   ├── openai_engine.rb      # OpenAI Whisper/gpt-4o-transcribe (engine: "open")
│   │   ├── elevenlabs_engine.rb  # ElevenLabs Scribe v2 (engine: "elab")
│   │   ├── groq_engine.rb        # Groq hosted Whisper (engine: "groq")
│   │   ├── engine_manager.rb     # Orchestrator: single or parallel comparison mode
│   │   └── reconciler.rb         # Claude Opus reconciliation of multi-engine transcripts
│   ├── agents/
│   │   ├── topic_agent.rb        # Claude topic generation
│   │   ├── research_agent.rb     # Exa.ai search
│   │   ├── script_agent.rb       # Claude script generation (structured output)
│   │   ├── tts_agent.rb          # ElevenLabs TTS (chunking, UTF-8-safe splitting)
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
│   ├── audio_assembler.rb        # ffmpeg wrapper (crossfades, loudnorm, music detection/stripping)
│   ├── rss_generator.rb          # RSS 2.0 + iTunes + Podcasting 2.0 feed (cover, transcripts)
│   └── logger.rb                 # Structured run logging with phase timings
├── scripts/
│   ├── serve.rb                  # WEBrick static file server (correct MIME types for mp3/xml/md)
│   └── test_*.rb                 # Test scripts
├── output/<name>/
│   ├── episodes/                 # MP3s + scripts/transcripts: {name}-{date}[-lang].mp3
│   ├── research_cache/           # Cached research results (auto-managed)
│   ├── history.yml               # Episode history for deduplication
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
  2. Download source audio
  3. Trim music: bandpass intro detection + silence-based outro detection
  4. Transcribe via EngineManager → Claude Opus post-processing (reconcile multi-engine / cleanup single)
  5. Build transcript (gpt-4o: text direct; whisper-1: metadata + acoustic filtering)
  6. Assemble: intro.mp3 + trimmed audio + outro.mp3 → loudnorm
  7. Save transcript(s) — primary + per-engine files in comparison mode
  8. LingQ upload (if ## LingQ section + LINGQ_API_KEY present) — non-fatal
     - Cover generation: if `base_image` configured, overlays uppercased title via ImageMagick
  9. Record history → done
```

### Key behaviors
- **Multi-podcast:** Each podcast in `podcasts/<name>/` with own config. CLI: `podgen generate <name>`
- **Multi-language:** `language` list in `## Podcast` section. English script generated first, translated for other languages. Per-language voice IDs. Output: `name-date-lang.mp3`
- **Same-day suffix:** `name-2026-02-18.mp3`, then `name-2026-02-18a.mp3`, etc.
- **Episode dedup:** History records topics + URLs; TopicAgent avoids repeats, sources exclude used URLs. 7-day lookback window.
- **Scrap:** `podgen scrap <name>` removes last episode files (MP3 + scripts, all languages) and last history entry. Supports `--dry-run`.
- **Research sources:** Parallel execution via threads. Sources: `exa`, `hackernews`, `rss` (with feed URLs), `claude_web`, `bluesky`, `x`. Default: exa only. 24h file-based cache per source+topics.
- **Transcript post-processing:** Claude Opus processes all transcripts. Multi-engine (2+ engines): reconciles sentence-by-sentence, picks best rendering, removes hallucination artifacts. Single engine: cleans up grammar, punctuation, and STT artifacts. Result becomes primary transcript. Non-fatal if post-processing fails.
- **LingQ upload:** Language pipeline auto-uploads lessons if `## LingQ` section (with `collection`) and `LINGQ_API_KEY` are present. Uploads audio + transcript, triggers timestamp generation. Non-fatal on failure.
- **Cover generation:** If `base_image` is configured in `## LingQ`, generates per-episode cover images by overlaying the uppercased episode title onto the base image via ImageMagick. Falls back to static `image` if generation fails or ImageMagick is not installed. Non-fatal.
- **RSS feed:** `podgen rss <name>` generates feed with iTunes + Podcasting 2.0 namespaces. Copies cover image from `podcasts/<name>/` to output. Converts markdown transcripts to HTML and adds `<podcast:transcript>` tags. Episode titles pulled from `history.yml`. `base_url` from config ensures correct absolute enclosure URLs.
- **`--dry-run`:** Validates config, uses queue.yml topics, generates synthetic data, saves debug script, skips all API calls/TTS/assembly/history/LingQ upload.
- **Lockfile:** Prevents concurrent runs of the same podcast via `flock`.

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
**Root `.env`:** `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID` (default: eleven_multilingual_v2), `ELEVENLABS_OUTPUT_FORMAT` (default: mp3_44100_128), `ELEVENLABS_SCRIBE_MODEL` (default: scribe_v2), `EXA_API_KEY`, `CLAUDE_MODEL` (default: claude-opus-4-6), `CLAUDE_WEB_MODEL` (default: claude-haiku-4-5-20251001), `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `SOCIALDATA_API_KEY`, `OPENAI_API_KEY` (language pipeline), `WHISPER_MODEL` (default: gpt-4o-mini-transcribe), `GROQ_API_KEY`, `GROQ_WHISPER_MODEL` (default: whisper-large-v3), `LINGQ_API_KEY` (language pipeline LingQ upload)

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
  generate <podcast>   # Full pipeline
  scrap <podcast>      # Remove last episode + history entry
  rss <podcast>        # Generate RSS feed (--base-url URL to override config)
  list                 # List podcasts
  test <name>          # Run test (research|rss|hn|claude_web|bluesky|x|script|tts|assembly|translation|transcription|sources|cover)
  schedule <podcast>   # Install launchd scheduler

Flags: -v/--verbose  -q/--quiet  --dry-run  -V/--version  -h/--help
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
