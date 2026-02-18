# Podcast Agent — Claude Code Instructions
## Project Vision
Build a fully autonomous podcast generation pipeline that runs on a schedule with zero human involvement. The system reads user-defined guidelines, researches topics, writes a script, generates audio via TTS, assembles a final MP3, and optionally publishes to a private RSS feed. The only human touchpoint is editing the guidelines and topic queue files.
---
## Tech Stack
- Language: Ruby 3.x
- Platform: macOS (launchd for scheduling)
- Key APIs: Anthropic Claude (orchestration + scripting), Exa.ai (research/news), ElevenLabs (TTS)
- Audio processing: ffmpeg (via Homebrew, called via shell)
- Config format: YAML and Markdown
- HTTP: httparty gem
- Dependencies managed via: Bundler Gemfile)
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
├── config/
│ └── guidelines.md # User-editable podcast format & style rules
│
├── topics/
│ └── queue.yml # User-editable topic queue
│
├── assets/
│ ├── intro.mp3 # Intro music (user-supplied)
│ └── outro.mp3 # Outro music (user-supplied)
│
├── lib/
│ ├── agents/
│ │ ├── research_agent.rb # Calls Exa.ai, returns structured research
│ │ ├── script_agent.rb # Calls Claude API, returns structured script
│ │ └── tts_agent.rb # Calls ElevenLabs, returns audio file paths
│ ├── audio_assembler.rb # ffmpeg wrapper: stitches parts + adds music
│ ├── rss_generator.rb # Generates RSS XML from output folder
│ └── logger.rb # Structured run logging
│
├── scripts/
│ └── orchestrator.rb # Main entry point — runs the full pipeline
│
├── output/
│ └── episodes/ # Final MP3s land here, named by date
│
├── logs/
│ └── runs/ # One log file per run
│
└── com.podcastagent.plist # macOS launchd plist for scheduling
```
---
## Build Order
Build in this exact sequence. Complete and test each phase before moving to the next.
### Phase 1 — Project Scaffold
- Initialize Ruby project with Bundler
- Create all directories and placeholder files
- Set up .env loading via dotenv gem
- Write .env.example with all required key names
- Write .gitignore (ignore .env, output/, logs/)
- Verify scaffold runs without errors: ruby scripts/orchestrator.rb
### Phase 2 — Research Agent
- Implement ResearchAgent using the Exa.ai API
- Input: array of topic strings from topics/queue.yml
- For each topic: search for the 5 most recent, relevant results
- Output: structured Ruby hash { topic: String, findings: [{ title, url, summary }] }
- Include error handling and retry logic (max 3 attempts per topic)
- Write a standalone test script scripts/test_research.rb
### Phase 3 — Script Agent
- Implement ScriptAgent using the Anthropic Claude API claude-opus-4-6)
- Input: research hash + full contents of config/guidelines.md
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
- The system prompt must enforce guidelines strictly — tone, length, format
- Save raw script to output/episodes/YYYY-MM-DD_script.md for debugging
- Write a standalone test script scripts/test_script.rb
### Phase 4 — TTS Agent
- Implement TTSAgent using the ElevenLabs API
- Input: array of segment objects from script
- For each segment: POST text to ElevenLabs, save returned audio to a temp file
- Voice ID and model should be configurable via .env
- Output: ordered array of file paths to segment audio files
- Write a standalone test script scripts/test_tts.rb
### Phase 5 — Audio Assembly
- Implement AudioAssembler as a wrapper around ffmpeg shell commands
- Input: segment audio paths, intro.mp3, outro.mp3, output path
- Assembly order: intro → segments (in order) → outro
- Normalize final output to -16 LUFS (podcast standard) using ffmpeg's loudnorm filter
- Output: single MP3 at output/episodes/YYYY-MM-DD.mp3
- Handle missing intro/outro gracefully (skip if files don't exist)
- Write a standalone test: scripts/test_assembly.rb
### Phase 6 — Orchestrator
- Wire all agents together in scripts/orchestrator.rb
- Flow: load guidelines → load topics → research → script → TTS → assemble
- Write a structured run log to logs/runs/YYYY-MM-DD.log including timings per phase
- On any unrecoverable error: log the failure and exit cleanly (don't crash loudly)
- Successful run should print: ✓ Episode ready: output/episodes/YYYY-MM-DD.mp3
### Phase 7 — RSS Feed (optional, build last)
- Implement RssGenerator that scans output/episodes/ for MP3s
- Generates a valid podcast RSS 2.0 XML file at output/feed.xml
- Each episode entry uses filename date as title and pubDate
- Add a scripts/generate_rss.rb runner
- Document how to serve this locally or via a static host
### Phase 8 — Scheduler
- Write com.podcastagent.plist for macOS launchd
- Default schedule: 6:00 AM daily
- Point it to a wrapper shell script scripts/run.sh that sets the working directory and runs the orchestrator
- Include setup instructions in README.md for launchctl load
---
## Coding Standards
- Every class and method has a single, clear responsibility
- All API calls are wrapped in retry logic with exponential backoff
- API keys are only read from environment variables, never hardcoded
- All file paths use File.join and __dir__-relative resolution — no hardcoded absolute paths
- Use require_relative throughout, not require with load path hacks
- Log meaningfully at each step: what's happening, how long it took, any warnings
- Prefer plain Ruby stdlib over gems where reasonable; add gems only when they save significant complexity
- All external shell commands (ffmpeg) use system() with explicit error checking
---
## Configuration Files (user-facing)
### config/guidelines.md — seed with this default content:
```markdown
# Podcast Guidelines
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
- Anything technically interesting from Hacker News in the past week
## Do not include
- Sponsor messages or calls to action
- Recaps of what was just said
- Phrases like "in today's episode" or "stay tuned"
```
### topics/queue.yml — seed with this default:
```yaml
topics:
- AI developer tools and agent frameworks
- Ruby on Rails ecosystem updates
- Interesting open source releases this week
```
---
## Environment Variables
Document these in .env.example:
```
ANTHROPIC_API_KEY=
ELEVENLABS_API_KEY=
ELEVENLABS_VOICE_ID=
ELEVENLABS_MODEL_ID=eleven_turbo_v2
EXA_API_KEY=
PODCAST_TITLE=My Daily Brief
PODCAST_AUTHOR=
```
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
2. Installation bundle install, copying .env.example to .env)
3. First run ruby scripts/orchestrator.rb)
4. How to customize guidelines and topics
5. Setting up the launchd scheduler
6. Optional RSS setup
---
## Known Constraints & Watch-outs
- ElevenLabs has per-request character limits; split long segments if needed
- ffmpeg must be on $PATH — check at startup and fail with a helpful message if missing
- Exa.ai returns varying result quality; the script agent should be resilient to thin research
- The launchd plist requires absolute paths — the run.sh script should resolve these dynamically
- macOS may sleep before the scheduled time — document that "Prevent sleep" or a plugged-in machine is recommended