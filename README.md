# Podcast Agent (podgen)

Fully autonomous podcast generation pipeline. Researches topics, writes a script, generates audio via TTS, and assembles a final MP3 — all on a daily schedule with zero human involvement.

## Prerequisites

- **Ruby 3.2+** (tested with Ruby 4.0)
- **Homebrew** (macOS)
- **ffmpeg**: `brew install ffmpeg`
- **API accounts**:
  - [Anthropic](https://console.anthropic.com/) — Claude API for script generation (also powers Claude Web Search source)
  - [Exa.ai](https://exa.ai/) — research/news search (default source)
  - [ElevenLabs](https://elevenlabs.io/) — text-to-speech

## Installation

### Via Homebrew (macOS)

```bash
brew tap arvicco/podgen
brew install podgen
```

This installs the `podgen` command and creates a project skeleton at `~/.podgen`. Edit `~/.podgen/.env` to add your API keys.

### From source

```bash
git clone https://github.com/arvicco/homebrew-podgen.git podgen && cd podgen
bundle install
cp .env.example .env
```

Edit `.env` and fill in your API keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...       # See: https://elevenlabs.io/app/voice-library
EXA_API_KEY=...
BLUESKY_HANDLE=...            # Optional: your-handle.bsky.social
BLUESKY_APP_PASSWORD=...      # Optional: https://bsky.app/settings/app-passwords
SOCIALDATA_API_KEY=...        # Optional: https://socialdata.tools
```

### Project root resolution

podgen looks for its project directory (`podcasts/`, `.env`, `output/`) in this order:

1. **Current directory** — if CWD contains a `podcasts/` folder
2. **`$PODGEN_HOME`** — if the environment variable is set
3. **`~/.podgen`** — default for Homebrew installs
4. **Code location** — fallback for git clone usage

## Usage

```bash
podgen <command> [options]
```

Or run directly with Ruby:

```bash
ruby bin/podgen <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `podgen generate <podcast>` | Run the full pipeline: research → script → TTS → assembly |
| `podgen scrap <podcast>` | Remove last episode and its history entry |
| `podgen rss <podcast>` | Generate RSS feed from existing episodes |
| `podgen list` | List available podcasts with titles |
| `podgen test <name>` | Run a standalone test (research, hn, rss, tts, etc.) |
| `podgen schedule <podcast>` | Install a daily launchd scheduler |

### Global flags

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Verbose output |
| `-q, --quiet` | Suppress terminal output (errors still shown, log file gets full detail) |
| `--dry-run` | Run pipeline without API calls or file output — validates config and shows what would happen |
| `-V, --version` | Print version |
| `-h, --help` | Show help |

### Examples

```bash
# Generate an episode
podgen generate ruby_world

# Dry run — validate config, no API calls
podgen --dry-run generate ruby_world

# Generate silently (for cron/launchd)
podgen --quiet generate ruby_world

# Scrap last episode (delete files + remove from history)
podgen scrap ruby_world

# Preview what scrap would remove (no changes)
podgen --dry-run scrap ruby_world

# List all configured podcasts
podgen list

# Generate RSS feed
podgen rss ruby_world

# Run a component test
podgen test hn
```

## First Run

```bash
podgen generate <podcast_name>
```

This will:
1. Research your configured topics via enabled sources (~23s with Exa only, longer with multiple)
2. Generate a podcast script via Claude (~48s)
3. Synthesize speech via ElevenLabs (~90s)
4. Assemble and normalize the final MP3 (~22s)

Output: `output/<podcast>/episodes/<name>-YYYY-MM-DD.mp3` (~10 min episode, ~12 MB)

## Creating a Podcast

1. Create a directory under `podcasts/`:

```bash
mkdir -p podcasts/my_podcast
```

2. Add `podcasts/my_podcast/guidelines.md` with your format, tone, and topic preferences (see `podcasts/ruby_world/guidelines.md` for an example).

3. Add `podcasts/my_podcast/queue.yml` with fallback topics:

```yaml
topics:
  - AI developer tools and agent frameworks
  - Ruby on Rails ecosystem updates
```

4. Optionally add per-podcast voice/model overrides in `podcasts/my_podcast/.env`.

## Customizing

### Podcast Guidelines

Edit `podcasts/<name>/guidelines.md` to change format, tone, length, and content rules. The script agent follows these strictly.

### Topics

Edit `podcasts/<name>/queue.yml`:

```yaml
topics:
  - AI developer tools and agent frameworks
  - Ruby on Rails ecosystem updates
  - Interesting open source releases this week
```

### Voice & Model

Configure in `.env`:

```
ELEVENLABS_MODEL_ID=eleven_multilingual_v2    # Multilingual, best quality
ELEVENLABS_VOICE_ID=cjVigY5qzO86Huf0OWal     # Eric - Smooth, Trustworthy
CLAUDE_MODEL=claude-opus-4-6                   # Script generation model
```

### Intro/Outro Music

Drop MP3 files into:
- `assets/intro.mp3` — played before the first segment (3s fade-out)
- `assets/outro.mp3` — played after the last segment (2s fade-in)

Both are optional. The pipeline skips them if the files don't exist.

### Research Sources

Research is modular — each podcast can enable different sources via a `## Sources` section in its `guidelines.md`. If the section is omitted, only Exa.ai is used (backward compatible).

Available sources:

| Source | Key | API needed | Cost per run | Description |
|--------|-----|-----------|--------------|-------------|
| Exa.ai | `exa` | EXA_API_KEY | ~$0.03 | AI-powered news search (default) |
| Hacker News | `hackernews` | None (free) | $0 | HN Algolia API, top stories per topic |
| RSS feeds | `rss` | None | $0 | Fetch any RSS/Atom feed |
| Claude Web Search | `claude_web` | ANTHROPIC_API_KEY | ~$0.02/topic | Claude with web_search tool (Haiku) |
| Bluesky | `bluesky` | BLUESKY_HANDLE + BLUESKY_APP_PASSWORD | $0 | AT Protocol post search (great for tech topics) |
| X (Twitter) | `x` | SOCIALDATA_API_KEY | ~$0.01 | Twitter/X search via SocialData.tools |

Add the section to `podcasts/<name>/guidelines.md`:

```markdown
## Sources
- exa
- hackernews
- bluesky
- x: @dhaboruby, @rails, @maboroshi_llm
- rss:
  - https://www.coindesk.com/arc/outboundfeeds/rss/
  - https://cointelegraph.com/rss
- claude_web
```

- Plain items (`- exa`) are boolean toggles
- Items with sub-lists (`- rss:` with feed URLs) or inline values (`- x: @user1, @user2`) carry parameters
- `- x` (no handles) does general search only; `- x: @handle, ...` searches those accounts first, then fills with general results
- Sources not listed are disabled
- Results from all sources are merged and deduplicated before script generation

### Multi-Language Episodes

Podgen can produce the same episode in multiple languages. The English script is generated first, then translated via Claude and synthesized with a per-language ElevenLabs voice.

Add a `## Language` section to `podcasts/<name>/guidelines.md`:

```markdown
## Language
- en
- it: CITWdMEsnRduEUkNWXQv
- ja: rrBxvYLJSqEU0KHpFpRp
```

- Each line is a 2-letter language code (ISO 639-1)
- Optionally append `: <voice_id>` to use a different ElevenLabs voice for that language
- If `## Language` is omitted, only English (`en`) is produced
- English is never re-translated — the original script is used directly
- Output files are suffixed by language: `ruby_world-2026-02-19.mp3` (English), `ruby_world-2026-02-19-it.mp3` (Italian), etc.

Supported languages (matching ElevenLabs `eleven_multilingual_v2`): Arabic, Chinese, Czech, Danish, Dutch, Finnish, French, German, Greek, Hebrew, Hindi, Hungarian, Indonesian, Italian, Japanese, Korean, Malay, Norwegian, Polish, Portuguese, Romanian, Russian, Spanish, Swedish, Thai, Turkish, Ukrainian, Vietnamese.

## Scheduling (launchd)

Run the installer to set up daily generation at 6:00 AM:

```bash
podgen schedule ruby_world
```

Verify it's loaded:

```bash
launchctl list | grep podcastagent
```

To uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.podcastagent.<podcast_name>.plist
rm ~/Library/LaunchAgents/com.podcastagent.<podcast_name>.plist
```

**Note:** macOS must be awake at the scheduled time. Keep the machine plugged in and disable sleep, or use `caffeinate`.

## RSS Feed

Generate a podcast RSS feed from your episodes:

```bash
podgen rss ruby_world
```

Serve locally:

```bash
cd output/ruby_world && ruby -run -e httpd . -p 8080
```

Then add `http://localhost:8080/feed.xml` to your podcast app. For remote access, host the `output/` directory on any static file server (nginx, S3, Cloudflare Pages, etc.) and update the enclosure URLs in the feed accordingly.

## Project Structure

```
podgen/
├── bin/
│   └── podgen               # CLI executable
├── podcasts/<name>/
│   ├── guidelines.md         # Podcast format, style, & sources config
│   └── queue.yml             # Fallback topic queue
├── assets/                   # Intro/outro music (optional)
├── lib/
│   ├── cli.rb                # CLI dispatcher (OptionParser)
│   ├── cli/
│   │   ├── version.rb        # PodgenCLI::VERSION
│   │   ├── generate_command.rb # Full pipeline command
│   │   ├── rss_command.rb    # RSS feed generation
│   │   ├── list_command.rb   # List available podcasts
│   │   ├── test_command.rb   # Run test scripts
│   │   └── schedule_command.rb # Install launchd scheduler
│   ├── source_manager.rb     # Multi-source research coordinator
│   ├── agents/
│   │   ├── topic_agent.rb    # Claude topic generation
│   │   ├── research_agent.rb # Exa.ai search
│   │   ├── script_agent.rb   # Claude script generation
│   │   ├── tts_agent.rb      # ElevenLabs TTS
│   │   └── translation_agent.rb # Claude script translation
│   ├── sources/
│   │   ├── rss_source.rb     # RSS/Atom feed fetcher
│   │   ├── hn_source.rb      # Hacker News Algolia API
│   │   └── claude_web_source.rb # Claude + web_search tool
│   ├── audio_assembler.rb    # ffmpeg wrapper
│   ├── research_cache.rb     # File-based research cache (24h TTL)
│   ├── rss_generator.rb      # RSS 2.0 feed
│   └── logger.rb             # Structured logging
├── scripts/
│   ├── orchestrator.rb       # Legacy pipeline entry point
│   ├── run.sh                # launchd wrapper
│   └── generate_rss.rb       # Legacy RSS generator
├── output/<name>/episodes/   # Final MP3s per podcast
└── logs/<name>/              # Run logs per podcast
```

## Testing Individual Components

```bash
podgen test research       # Exa.ai search
podgen test rss            # RSS feed fetching
podgen test hn             # Hacker News search
podgen test claude_web     # Claude web search
podgen test bluesky        # Bluesky post search
podgen test x              # X (Twitter) search via SocialData
podgen test script         # Claude script generation
podgen test tts            # ElevenLabs TTS
podgen test assembly       # ffmpeg assembly
podgen test translation    # Claude script translation
```

## Cost Estimate

Per daily episode (~10 min), with all sources enabled:
- Exa.ai: ~$0.03 (4 searches + summaries)
- Claude Opus 4.6: ~$0.15 (script generation)
- Claude Opus 4.6: ~$0.10 per extra language (translation)
- Claude Haiku (web search): ~$0.08 (4 topics × web_search)
- Hacker News: free (Algolia API)
- Bluesky: free (AT Protocol, requires account)
- X (Twitter): ~$0.01 (SocialData.tools, $0.0002/tweet)
- RSS feeds: free
- ElevenLabs: varies by plan ($22-99/month for daily use)

With Exa only (default), English only: ~$0.18 + ElevenLabs per episode.
Each additional language adds ~$0.10 (translation) + ElevenLabs TTS cost.
