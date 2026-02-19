# Podcast Agent — Claude Code Instructions
## Project Vision
Build a fully autonomous podcast generation pipeline that runs on a schedule with zero human involvement. The system reads user-defined guidelines, researches topics, writes a script, generates audio via TTS, assembles a final MP3, and optionally publishes to a private RSS feed. The only human touchpoint is editing the guidelines and topic queue files.
---
## Tech Stack
- Language: Ruby 3.2+ (required by Anthropic SDK)
- Platform: macOS (launchd for scheduling)
- Key APIs: Anthropic Claude (orchestration + scripting), Exa.ai (research/news), ElevenLabs (TTS)
- Audio processing: ffmpeg (via Homebrew, called via Open3.capture3)
- Config format: YAML and Markdown
- Gems: anthropic (official SDK), exa-ai (official SDK), httparty (ElevenLabs), dotenv
- Dependencies managed via: Bundler (Gemfile)
---
## Project Structure
```
podcast_agent/
├── CLAUDE.md # This file
├── Gemfile
├── Gemfile.lock
├── .env # API keys (never commit)
├── .env.example # Committed template with blank values
├── .gitignore
│
├── podcasts/ # One subfolder per podcast
│ └── ruby_world/ # Example podcast
│   ├── guidelines.md # Podcast format, style & sources config
│   └── queue.yml # Fallback topic queue
│
├── assets/
│ ├── intro.mp3 # Intro music (user-supplied, shared)
│ └── outro.mp3 # Outro music (user-supplied, shared)
│
├── lib/
│ ├── podcast_config.rb # PodcastConfig — resolves all paths + parses sources config
│ ├── source_manager.rb # Coordinates multiple research sources per podcast
│ ├── agents/
│ │ ├── topic_agent.rb # Calls Claude API, generates timely search queries
│ │ ├── research_agent.rb # Calls Exa.ai, returns structured research
│ │ ├── script_agent.rb # Calls Claude API, returns structured script
│ │ └── tts_agent.rb # Calls ElevenLabs, returns audio file paths
│ ├── sources/
│ │ ├── rss_source.rb # Fetches RSS/Atom feeds (stdlib net/http + rss)
│ │ ├── hn_source.rb # Searches Hacker News via Algolia API (httparty)
│ │ └── claude_web_source.rb # Claude API with web_search tool (anthropic gem)
│ ├── episode_history.rb # Reads/writes per-podcast episode history for dedup
│ ├── audio_assembler.rb # ffmpeg wrapper: stitches parts + adds music
│ ├── rss_generator.rb # Generates RSS XML from episode folder
│ └── logger.rb # Structured run logging
│
├── scripts/
│ ├── orchestrator.rb # Main entry point — accepts podcast name argument
│ ├── run.sh # launchd wrapper — passes podcast name through
│ ├── generate_rss.rb # RSS generator — accepts podcast name argument
│ └── install_scheduler.sh # Installs per-podcast launchd plist
│
├── output/
│ └── <podcast_name>/ # Per-podcast output
│   ├── episodes/ # MP3s + debug scripts, named {name}-{date}[suffix]
│   ├── history.yml # Episode history for deduplication (auto-managed)
│   └── feed.xml # RSS feed
│
├── logs/
│ └── <podcast_name>/ # Per-podcast logs, named {name}-{date}[suffix].log
│
└── com.podcastagent.plist # Template launchd plist (install_scheduler.sh fills it in)
```
### Multi-podcast support
- Each podcast lives in `podcasts/<name>/` with its own `guidelines.md` and `queue.yml`
- The orchestrator requires a podcast name argument: `ruby scripts/orchestrator.rb ruby_world`
- `PodcastConfig` resolves all paths (episodes, logs, feed) for a given podcast name
- Same-day runs get suffixed: `name-2026-02-18.mp3`, then `name-2026-02-18a.mp3`, etc.
- Scheduling is per-podcast via `scripts/install_scheduler.sh <podcast_name>`
---
## Build Order
Build in this exact sequence. Complete and test each phase before moving to the next.
### Phase 1 — Project Scaffold
- Initialize Ruby project with Bundler
- Create all directories and placeholder files
- Set up .env loading via dotenv gem
- Write .env.example with all required key names
- Write .gitignore (ignore .env, output/, logs/)
- Verify scaffold runs without errors: ruby scripts/orchestrator.rb <podcast_name>
### Phase 2 — Research (multi-source)
- Research is modular: each source lives in lib/sources/ and implements `research(topics, exclude_urls:)`
- SourceManager (lib/source_manager.rb) coordinates enabled sources per podcast
- Sources are configured via an optional `## Sources` section in guidelines.md
- Available sources: exa (Exa.ai), hackernews (HN Algolia API), rss (RSS/Atom feeds), claude_web (Claude + web_search)
- Default (if ## Sources omitted): exa only (backward compatible)
- ResearchAgent (Exa.ai) remains in lib/agents/ as the original source
- All sources return the same format: [{ topic:, findings: [{ title:, url:, summary: }] }]
- SourceManager merges results, deduplicates URLs across sources
- Write standalone test scripts: test_research.rb, test_rss.rb, test_hn.rb, test_claude_web.rb
### Phase 3 — Script Agent
- Implement ScriptAgent using the official anthropic Ruby gem (claude-opus-4-6)
- Use Structured Outputs (output_config with JSON schema) for guaranteed valid output
- Use prompt caching for the system prompt (guidelines are identical each run)
- Input: research hash + guidelines string (passed from orchestrator)
- Output: structured script object with named segments, e.g.:
```ruby
{
title: String,
segments: [
{ name: "intro", text: String },
{ name: "segment_1", text: String },
{ name: "segment_2", text: String },
{ name: "outro", text: String }
]
}
```
- Generate the full script in a single API call (not segment-by-segment) for narrative coherence
- The system prompt must enforce guidelines strictly — tone, length, format
- Save raw script to output/<podcast>/episodes/<name>-YYYY-MM-DD_script.md for debugging
- Write a standalone test script scripts/test_script.rb
### Phase 4 — TTS Agent
- Implement TTSAgent using the ElevenLabs API (httparty, no official Ruby SDK)
- Input: array of segment objects from script
- For each segment: POST text to ElevenLabs, save returned audio to a temp file
- Request mp3_44100_128 output format explicitly for consistent sample rate
- Voice ID and model should be configurable via .env (default: eleven_multilingual_v2)
- Note: eleven_multilingual_v2 has a 10,000 char per-request limit; split longer segments
- Output: ordered array of file paths to segment audio files
- Write a standalone test script scripts/test_tts.rb
### Phase 5 — Audio Assembly
- Implement AudioAssembler as a wrapper around ffmpeg via Open3.capture3 (not system())
- Input: segment audio paths, intro.mp3, outro.mp3, output path
- Assembly order: intro → segments (in order) → outro
- Use filter_complex with concat filter (not concat demuxer) to handle mixed formats
- Explicitly resample all inputs to 44100 Hz mono via aresample+aformat in the filter graph
- Apply crossfades: 3s fade-out on intro into first segment, 2s fade-in on outro
- Use ffprobe to get input durations for fade timing calculations
- Two-pass loudnorm with linear=true at -16 LUFS (podcast standard):
  - Pass 1: analyze audio, capture JSON measurements from stderr
  - Pass 2: normalize with measured values, preserving natural speech dynamics
- Final output: MP3 at 192 kbps, 44100 Hz, mono → output/<podcast>/episodes/<name>-YYYY-MM-DD.mp3
- Handle missing intro/outro gracefully (skip if files don't exist)
- Write a standalone test: scripts/test_assembly.rb
### Phase 6 — Orchestrator
- Wire all agents together in scripts/orchestrator.rb
- Accepts podcast name as ARGV[0] (required); lists available podcasts if missing
- Uses PodcastConfig to resolve all paths for the given podcast
- Flow: load guidelines → generate topics (with queue.yml fallback) → research → script → TTS → assemble
- Episode deduplication via EpisodeHistory (lib/episode_history.rb):
  - After each successful run, record topics and URLs to output/<podcast>/history.yml
  - On startup, pass recent topic summaries to TopicAgent so Claude generates different queries
  - Pass recent URLs to ResearchAgent to filter already-used Exa results
  - History is auto-pruned to a 7-day lookback window (matches Exa search range)
- Write a structured run log to logs/<podcast>/<name>-YYYY-MM-DD.log including timings per phase
- On any unrecoverable error: log the failure and exit cleanly (don't crash loudly)
- Successful run should print: ✓ Episode ready: output/<podcast>/episodes/<name>-YYYY-MM-DD.mp3
### Phase 7 — RSS Feed (optional, build last)
- Implement RssGenerator that scans output/<podcast>/episodes/ for MP3s
- Generates a valid podcast RSS 2.0 XML file at output/<podcast>/feed.xml
- Each episode entry uses filename date as title and pubDate
- scripts/generate_rss.rb accepts podcast name as ARGV[0]
- Document how to serve this locally or via a static host
### Phase 8 — Scheduler
- com.podcastagent.plist is a template — install_scheduler.sh fills in paths and podcast name
- One launchd job per podcast: `scripts/install_scheduler.sh <podcast_name>`
- Unique label per podcast: com.podcastagent.<podcast_name>
- Default schedule: 6:00 AM daily
- scripts/run.sh passes podcast name through to orchestrator
---
## Coding Standards
- Every class and method has a single, clear responsibility
- All API calls are wrapped in retry logic with exponential backoff
- API keys are only read from environment variables, never hardcoded
- All file paths use File.join and __dir__-relative resolution — no hardcoded absolute paths
- Use require_relative throughout, not require with load path hacks
- Log meaningfully at each step: what's happening, how long it took, any warnings
- Prefer plain Ruby stdlib over gems where reasonable; add gems only when they save significant complexity
- All external shell commands (ffmpeg) use Open3.capture3 to capture stdout, stderr, and exit status
- ffmpeg writes diagnostics to stderr — always capture and log it
---
## Configuration Files (user-facing)
Each podcast lives in `podcasts/<name>/` with these files:
### podcasts/<name>/.env — per-podcast overrides (optional, gitignored):
```
# Override voice/model for this podcast:
# ELEVENLABS_VOICE_ID=
# ELEVENLABS_MODEL_ID=
# CLAUDE_MODEL=
```
### podcasts/<name>/guidelines.md — example:
```markdown
# Podcast Guidelines
## Name
My Podcast Name
## Author
Author Name
## Format
- Target length: 10–12 minutes
- Open with a 60-second news brief covering the most interesting recent development
- Two main segments of 4–5 minutes each, one per topic
- Close with a single practical takeaway or thought to sit with
## Tone
Conversational and direct. Speak like a smart, slightly opinionated friend,
not a journalist or content creator. No filler phrases. No forced enthusiasm.
## Topics (default rotation — override with queue.yml)
- AI and software development news
- Ruby ecosystem updates
## Sources
- exa
- hackernews
- rss:
  - https://www.coindesk.com/arc/outboundfeeds/rss/
  - https://cointelegraph.com/rss
- claude_web

## Do not include
- Sponsor messages or calls to action
- Recaps of what was just said
- Phrases like "in today's episode" or "stay tuned"
```
The `## Sources` section is optional. If omitted, defaults to exa only.
Available sources: `exa`, `hackernews`, `rss` (with sub-list of feed URLs), `claude_web`.
### podcasts/<name>/queue.yml — example:
```yaml
topics:
- AI developer tools and agent frameworks
- Ruby on Rails ecosystem updates
```
---
## Environment Variables
### Root .env — API keys and global defaults:
```
ANTHROPIC_API_KEY=
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=
ELEVENLABS_MODEL_ID=eleven_multilingual_v2
ELEVENLABS_OUTPUT_FORMAT=mp3_44100_128
EXA_API_KEY=
CLAUDE_MODEL=claude-opus-4-6
```
### Per-podcast .env — podcasts/<name>/.env overrides (all optional):
```
ELEVENLABS_VOICE_ID=    # use a different voice
ELEVENLABS_MODEL_ID=    # use a different TTS model
CLAUDE_MODEL=           # use a different Claude model
```
Podcast title and author are defined in `guidelines.md` via `## Name` and `## Author` headings.
Per-podcast `.env` is loaded via `Dotenv.overload` after the root `.env`, so any
key set there takes precedence for that podcast's pipeline run.
---
## Testing Approach
- Each agent has its own scripts/test_*.rb runner that can be executed in isolation
- Tests use real API calls (this is not a unit-tested library; it's a pipeline script)
- Keep API costs low during testing: use short topic inputs and limit research results to 2 per topic
- After Phase 6, a full end-to-end test run should cost under $0.50
---
## README.md
Generate a README that covers:
1. Prerequisites (Ruby version, Homebrew, ffmpeg, API accounts)
2. Installation (bundle install, copying .env.example to .env)
3. Creating a podcast (adding a folder under podcasts/ with guidelines.md and queue.yml)
4. First run: `ruby scripts/orchestrator.rb <podcast_name>`
5. How to customize guidelines and topics
6. Setting up the launchd scheduler per podcast
7. Optional RSS setup
---
## Known Constraints & Watch-outs
- ElevenLabs eleven_multilingual_v2 has a 10,000 char per-request limit; split long segments if needed
- ffmpeg must be on $PATH — check at startup and fail with a helpful message if missing
- Exa.ai returns varying result quality; the script agent should be resilient to thin research
- The launchd plist requires absolute paths — the run.sh script should resolve these dynamically
- macOS may sleep before the scheduled time — document that "Prevent sleep" or a plugged-in machine is recommended
- Stereo music + mono TTS will cause concat failures — always force all inputs to mono 44100 Hz in filter graph
- Request mp3_44100_128 explicitly from ElevenLabs to guarantee a known sample rate
---
## Workflow Notes
- When the user mentions screenshots or pics, check ~/Desktop for the most recent .png files sorted by date