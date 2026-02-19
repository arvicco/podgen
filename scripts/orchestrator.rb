#!/usr/bin/env ruby
# frozen_string_literal: true

# Podcast Agent — Main Orchestrator
# Runs the full pipeline: research → script → TTS → audio assembly
# Usage: ruby scripts/orchestrator.rb <podcast_name>

require "bundler/setup"
require "dotenv/load"
require "yaml"
require "date"

root = File.expand_path("..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "topic_agent")
require_relative File.join(root, "lib", "source_manager")
require_relative File.join(root, "lib", "agents", "script_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "episode_history")

# --- Parse podcast name argument ---
podcast_name = ARGV[0]

unless podcast_name
  available = PodcastConfig.available
  puts "Usage: ruby scripts/orchestrator.rb <podcast_name>"
  puts
  if available.any?
    puts "Available podcasts:"
    available.each { |name| puts "  - #{name}" }
  else
    puts "No podcasts found. Create a directory under podcasts/ with guidelines.md and queue.yml."
  end
  exit 1
end

config = PodcastConfig.new(podcast_name)
config.load_env!
config.ensure_directories!

today = Date.today
logger = PodcastAgent::Logger.new(log_path: config.log_path(today))
history = EpisodeHistory.new(config.history_path)

begin
  logger.log("Podcast Agent started for '#{podcast_name}'")
  pipeline_start = Time.now

  # --- Verify prerequisites ---
  unless File.exist?(config.guidelines_path)
    logger.error("Missing guidelines: #{config.guidelines_path}")
    exit 1
  end

  # --- Load config ---
  guidelines = config.guidelines
  logger.log("Loaded guidelines (#{guidelines.length} chars)")

  # --- Phase 0: Topic generation ---
  logger.phase_start("Topics")
  begin
    topic_agent = TopicAgent.new(guidelines: guidelines, recent_topics: history.recent_topics_summary, logger: logger)
    topics = topic_agent.generate
    logger.log("Generated #{topics.length} topics from guidelines")
  rescue => e
    logger.log("Topic generation failed (#{e.message}), falling back to queue.yml")
    topics = config.queue_topics
    logger.log("Loaded #{topics.length} fallback topics: #{topics.join(', ')}")
  end
  logger.phase_end("Topics")

  # --- Phase 1: Research (multi-source) ---
  logger.phase_start("Research")
  source_manager = SourceManager.new(
    source_config: config.sources,
    exclude_urls: history.recent_urls,
    logger: logger
  )
  research_data = source_manager.research(topics)
  total_findings = research_data.sum { |r| r[:findings].length }
  logger.log("Research complete: #{total_findings} findings across #{research_data.length} topics")
  logger.phase_end("Research")

  # --- Phase 2: Script generation ---
  logger.phase_start("Script")
  script_agent = ScriptAgent.new(
    guidelines: guidelines,
    script_path: config.script_path(today),
    logger: logger
  )
  script = script_agent.generate(research_data)
  logger.log("Script generated: \"#{script[:title]}\" (#{script[:segments].length} segments)")
  logger.phase_end("Script")

  # --- Phase 3: TTS ---
  logger.phase_start("TTS")
  tts_agent = TTSAgent.new(logger: logger)
  audio_paths = tts_agent.synthesize(script[:segments])
  logger.log("TTS complete: #{audio_paths.length} audio files")
  logger.phase_end("TTS")

  # --- Phase 4: Audio assembly ---
  logger.phase_start("Assembly")
  output_path = config.episode_path(today)
  intro_path = File.join(config.podcast_dir, "intro.mp3")
  outro_path = File.join(config.podcast_dir, "outro.mp3")

  assembler = AudioAssembler.new(logger: logger)
  assembler.assemble(audio_paths, output_path, intro_path: intro_path, outro_path: outro_path)
  logger.phase_end("Assembly")

  # --- Cleanup TTS temp files ---
  audio_paths.each { |p| File.delete(p) if File.exist?(p) }

  # --- Record episode history for deduplication ---
  history.record!(
    date: today,
    title: script[:title],
    topics: research_data.map { |r| r[:topic] },
    urls: research_data.flat_map { |r| r[:findings].map { |f| f[:url] } }
  )
  logger.log("Episode recorded in history: #{config.history_path}")

  # --- Done ---
  total_time = (Time.now - pipeline_start).round(2)
  logger.log("Total pipeline time: #{total_time}s")
  logger.log("✓ Episode ready: #{output_path}")

  puts "\n✓ Episode ready: #{output_path}"

rescue => e
  logger.error("#{e.class}: #{e.message}")
  logger.error(e.backtrace.first(5).join("\n"))
  puts "\n✗ Pipeline failed: #{e.message}"
  exit 1
end
