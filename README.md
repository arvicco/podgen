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

```bash
git clone <repo-url> && cd podgen
bundle install
cp .env.example .env
```

Edit `.env` and fill in your API keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...       # See: https://elevenlabs.io/app/voice-library
EXA_API_KEY=...
```

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
| `podgen rss <podcast>` | Generate RSS feed from existing episodes |
| `podgen list` | List available podcasts with titles |
| `podgen test <name>` | Run a standalone test (research, hn, rss, tts, etc.) |
| `podgen schedule <podcast>` | Install a daily launchd scheduler |

### Global flags

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Verbose output |
| `-q, --quiet` | Suppress terminal output (errors still shown, log file gets full detail) |
| `-V, --version` | Print version |
| `-h, --help` | Show help |

### Examples

```bash
# Generate an episode
podgen generate ruby_world

# Generate silently (for cron/launchd)
podgen --quiet generate ruby_world

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

Add the section to `podcasts/<name>/guidelines.md`:

```markdown
## Sources
- exa
- hackernews
- rss:
  - https://www.coindesk.com/arc/outboundfeeds/rss/
  - https://cointelegraph.com/rss
- claude_web
```

- Plain items (`- exa`) are boolean toggles
- Items with sub-lists (`- rss:` with indented URLs) carry parameters
- Sources not listed are disabled
- Results from all sources are merged and deduplicated before script generation

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
│   │   └── tts_agent.rb      # ElevenLabs TTS
│   ├── sources/
│   │   ├── rss_source.rb     # RSS/Atom feed fetcher
│   │   ├── hn_source.rb      # Hacker News Algolia API
│   │   └── claude_web_source.rb # Claude + web_search tool
│   ├── audio_assembler.rb    # ffmpeg wrapper
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
podgen test script         # Claude script generation
podgen test tts            # ElevenLabs TTS
podgen test assembly       # ffmpeg assembly
```

## Cost Estimate

Per daily episode (~10 min), with all sources enabled:
- Exa.ai: ~$0.03 (4 searches + summaries)
- Claude Opus 4.6: ~$0.15 (script generation)
- Claude Haiku (web search): ~$0.08 (4 topics × web_search)
- Hacker News: free (Algolia API)
- RSS feeds: free
- ElevenLabs: varies by plan ($22-99/month for daily use)

With Exa only (default): ~$0.18 + ElevenLabs per episode.
