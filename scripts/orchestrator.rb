#!/usr/bin/env ruby
# frozen_string_literal: true

# Podcast Agent — Main Orchestrator
# Phase 1: Scaffold verification
# Phases 2–6 will wire in each agent sequentially.

require "bundler/setup"
require "dotenv/load"
require "yaml"

root = File.expand_path("..", __dir__)

require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "research_agent")
require_relative File.join(root, "lib", "agents", "script_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "rss_generator")

logger = PodcastAgent::Logger.new
logger.log("Podcast Agent started")

# Verify required directories exist
%w[config topics assets lib/agents scripts output/episodes logs/runs].each do |dir|
  path = File.join(root, dir)
  unless Dir.exist?(path)
    logger.error("Missing directory: #{dir}")
    exit 1
  end
end

# Verify key config files exist
%w[config/guidelines.md topics/queue.yml].each do |file|
  path = File.join(root, file)
  unless File.exist?(path)
    logger.error("Missing config file: #{file}")
    exit 1
  end
end

# Load guidelines
guidelines = File.read(File.join(root, "config", "guidelines.md"))
logger.log("Loaded guidelines (#{guidelines.length} chars)")

# Load topics
topics = YAML.load_file(File.join(root, "topics", "queue.yml"))
logger.log("Loaded #{topics['topics'].length} topics: #{topics['topics'].join(', ')}")

# TODO: Phase 2 — Research
# TODO: Phase 3 — Script generation
# TODO: Phase 4 — TTS
# TODO: Phase 5 — Audio assembly

logger.log("Scaffold verification complete — all systems ready")
