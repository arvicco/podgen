# Podcast Agent (podgen)

Fully autonomous podcast generation pipeline. Researches topics, writes a script, generates audio via TTS, and assembles a final MP3 — all on a daily schedule with zero human involvement.

## Prerequisites

- **Ruby 3.2+** (tested with Ruby 4.0)
- **Homebrew** (macOS)
- **ffmpeg**: `brew install ffmpeg`
- **API accounts**:
  - [Anthropic](https://console.anthropic.com/) — Claude API for script generation
  - [Exa.ai](https://exa.ai/) — research/news search
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

## First Run

```bash
ruby scripts/orchestrator.rb
```

This will:
1. Research your configured topics via Exa.ai (~23s)
2. Generate a podcast script via Claude (~48s)
3. Synthesize speech via ElevenLabs (~90s)
4. Assemble and normalize the final MP3 (~22s)

Output: `output/episodes/YYYY-MM-DD.mp3` (~10 min episode, ~12 MB)

## Customizing

### Podcast Guidelines

Edit `config/guidelines.md` to change format, tone, length, and content rules. The script agent follows these strictly.

### Topics

Edit `topics/queue.yml`:

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

## Scheduling (launchd)

Run the installer to set up daily generation at 6:00 AM:

```bash
bash scripts/install_scheduler.sh
```

Verify it's loaded:

```bash
launchctl list | grep podcastagent
```

To uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.podcastagent.plist
rm ~/Library/LaunchAgents/com.podcastagent.plist
```

**Note:** macOS must be awake at the scheduled time. Keep the machine plugged in and disable sleep, or use `caffeinate`.

## RSS Feed

Generate a podcast RSS feed from your episodes:

```bash
ruby scripts/generate_rss.rb
```

Serve locally:

```bash
cd output && ruby -run -e httpd . -p 8080
```

Then add `http://localhost:8080/feed.xml` to your podcast app. For remote access, host the `output/` directory on any static file server (nginx, S3, Cloudflare Pages, etc.) and update the enclosure URLs in the feed accordingly.

## Project Structure

```
podgen/
├── config/guidelines.md      # Podcast format & style rules
├── topics/queue.yml          # Topic queue
├── assets/                   # Intro/outro music (optional)
├── lib/
│   ├── agents/
│   │   ├── research_agent.rb # Exa.ai search
│   │   ├── script_agent.rb   # Claude script generation
│   │   └── tts_agent.rb      # ElevenLabs TTS
│   ├── audio_assembler.rb    # ffmpeg wrapper
│   ├── rss_generator.rb      # RSS 2.0 feed
│   └── logger.rb             # Structured logging
├── scripts/
│   ├── orchestrator.rb       # Main pipeline entry point
│   ├── run.sh                # launchd wrapper
│   └── generate_rss.rb       # RSS generator runner
├── output/episodes/          # Final MP3s
└── logs/runs/                # Run logs
```

## Testing Individual Components

```bash
ruby scripts/test_research.rb    # Phase 2: Exa.ai search
ruby scripts/test_script.rb      # Phase 3: Claude script generation
ruby scripts/test_tts.rb         # Phase 4: ElevenLabs TTS
ruby scripts/test_assembly.rb    # Phase 5: ffmpeg assembly
```

## Cost Estimate

Per daily episode (~10 min):
- Exa.ai: ~$0.03 (3 searches + summaries)
- Claude Opus 4.6: ~$0.15 (script generation)
- ElevenLabs: varies by plan ($22-99/month for daily use)
