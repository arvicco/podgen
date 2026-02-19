# Podcast Agent — Claude Code Instructions

## Project Overview
Fully autonomous podcast generation pipeline. Reads guidelines, researches topics, writes a script, generates multi-language audio via TTS, assembles final MP3s, and optionally publishes to RSS. Zero human involvement beyond editing config files.

**Status:** Production-ready. All phases complete.

---

## Tech Stack
- **Language:** Ruby 3.2+ — **Gems:** anthropic, exa-ai, httparty, dotenv, rexml, rss (all pinned `~> x.y` in Gemfile)
- **APIs:** Anthropic Claude (topics, scripting, translation, web search), Exa.ai (research), ElevenLabs (TTS)
- **Audio:** ffmpeg via `Open3.capture3` — concat filter, two-pass loudnorm, 44100 Hz mono, 192 kbps MP3
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
│   │   ├── generate_command.rb   # Full pipeline: topics → research → script → TTS → assembly
│   │   ├── scrap_command.rb     # Remove last episode + history entry
│   │   ├── rss_command.rb        # RSS feed generation
│   │   ├── list_command.rb       # List available podcasts
│   │   ├── test_command.rb       # Delegates to scripts/test_*.rb
│   │   └── schedule_command.rb   # Installs launchd plist
│   ├── podcast_config.rb         # Resolves all paths, parses sources/languages from guidelines
│   ├── source_manager.rb         # Parallel multi-source research coordinator + cache integration
│   ├── research_cache.rb         # File-based research cache (SHA256 keys, 24h TTL, atomic writes)
│   ├── agents/
│   │   ├── topic_agent.rb        # Claude topic generation
│   │   ├── research_agent.rb     # Exa.ai search
│   │   ├── script_agent.rb       # Claude script generation (structured output)
│   │   ├── tts_agent.rb          # ElevenLabs TTS (chunking, UTF-8-safe splitting)
│   │   └── translation_agent.rb  # Claude script translation
│   ├── sources/
│   │   ├── rss_source.rb         # RSS/Atom feeds (keyword-based topic matching)
│   │   ├── hn_source.rb          # Hacker News Algolia API
│   │   ├── claude_web_source.rb  # Claude + web_search tool (configurable model/max_results)
│   │   ├── bluesky_source.rb    # Bluesky AT Protocol authenticated post search
│   │   └── x_source.rb          # X (Twitter) via SocialData.tools API
│   ├── episode_history.rb        # Episode dedup (atomic YAML writes, 7-day lookback)
│   ├── audio_assembler.rb        # ffmpeg wrapper (duration caching, crossfades, loudnorm)
│   ├── rss_generator.rb          # RSS 2.0 XML feed
│   └── logger.rb                 # Structured run logging with phase timings
├── scripts/                      # Legacy entry points + test scripts
├── output/<name>/
│   ├── episodes/                 # MP3s + debug scripts: {name}-{date}[-lang].mp3
│   ├── research_cache/           # Cached research results (auto-managed)
│   ├── history.yml               # Episode history for deduplication
│   └── feed.xml                  # RSS feed
└── logs/<name>/                  # Per-podcast run logs
```

---

## Pipeline Flow
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

### Key behaviors
- **Multi-podcast:** Each podcast in `podcasts/<name>/` with own config. CLI: `podgen generate <name>`
- **Multi-language:** `## Language` section in guidelines.md. English script generated first, translated for other languages. Per-language voice IDs. Output: `name-date-lang.mp3`
- **Same-day suffix:** `name-2026-02-18.mp3`, then `name-2026-02-18a.mp3`, etc.
- **Episode dedup:** History records topics + URLs; TopicAgent avoids repeats, sources exclude used URLs. 7-day lookback window.
- **Scrap:** `podgen scrap <name>` removes last episode files (MP3 + scripts, all languages) and last history entry. Supports `--dry-run`.
- **Research sources:** Parallel execution via threads. Sources: `exa`, `hackernews`, `rss` (with feed URLs), `claude_web`, `bluesky`, `x`. Default: exa only. 24h file-based cache per source+topics.
- **`--dry-run`:** Validates config, uses queue.yml topics, generates synthetic data, saves debug script, skips all API calls/TTS/assembly/history.
- **Lockfile:** Prevents concurrent runs of the same podcast via `flock`.

---

## Configuration

### guidelines.md sections
| Section | Required | Description |
|---------|----------|-------------|
| `## Name` | No | Podcast title (fallback: directory name) |
| `## Author` | No | Author name (fallback: "Podcast Agent") |
| `## Format` | Yes | Length, segment structure, pacing |
| `## Tone` | Yes | Voice and style directions |
| `## Topics` | Yes | Default topic rotation |
| `## Language` | No | `- en`, `- it: <voice_id>`. Default: `[en]` |
| `## Sources` | No | `- exa`, `- hackernews`, `- rss:` (with URLs), `- claude_web`. Default: exa |
| `## Do not include` | No | Content restrictions |

### Environment variables
**Root `.env`:** `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID` (default: eleven_multilingual_v2), `ELEVENLABS_OUTPUT_FORMAT` (default: mp3_44100_128), `EXA_API_KEY`, `CLAUDE_MODEL` (default: claude-opus-4-6), `CLAUDE_WEB_MODEL` (default: claude-haiku-4-5-20251001), `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `SOCIALDATA_API_KEY`

**Per-podcast `.env`** (optional): overrides for `ELEVENLABS_VOICE_ID`, `ELEVENLABS_MODEL_ID`, `CLAUDE_MODEL`. Loaded via `Dotenv.overload`.

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
  rss <podcast>        # Generate RSS feed
  list                 # List podcasts
  test <name>          # Run test (research|rss|hn|claude_web|bluesky|x|script|tts|assembly|translation|sources)
  schedule <podcast>   # Install launchd scheduler

Flags: -v/--verbose  -q/--quiet  --dry-run  -V/--version  -h/--help
```

---

## Known Constraints
- ElevenLabs eleven_multilingual_v2: 10,000 char per-request limit (TTSAgent splits automatically)
- ffmpeg must be on `$PATH` — checked at startup with clear error message
- Stereo music + mono TTS: all inputs forced to mono 44100 Hz in filter graph
- macOS must be awake at scheduled time — recommend plugged-in + sleep disabled
- launchd plist requires absolute paths — `run.sh` resolves dynamically

---

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date
