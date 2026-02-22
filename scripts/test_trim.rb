#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic script: downloads one episode and saves each trim stage
# as a separate file so you can listen to what's being cut.
#
# Usage: ruby scripts/test_trim.rb [episode_url]
#   If no URL given, fetches the next unprocessed episode from RSS.
#
# Output (in output/trim_test/):
#   1_original.mp3        — raw download
#   2_after_skip_intro.mp3 — after fixed skip_intro cut
#   3_after_bandpass.mp3   — after bandpass music detection trim
#
# Listen to each file to identify where the over-trimming happens.

require "dotenv"
Dotenv.load

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "podcast_config"
require "audio_assembler"
require "episode_history"
require_relative "../lib/logger"
require "fileutils"
require "open-uri"
require "rss"

PODCAST = "lahko_noc"
OUTPUT_DIR = File.join(PodcastConfig.root, "output", "trim_test")
FileUtils.mkdir_p(OUTPUT_DIR)

config = PodcastConfig.new(PODCAST)
config.load_env!
logger = PodcastAgent::Logger.new(verbosity: :verbose)
assembler = AudioAssembler.new(logger: logger)

# --- Get episode URL ---
url = ARGV[0]
unless url
  puts "Fetching next episode from RSS..."
  history = EpisodeHistory.new(config.history_path)
  used_urls = history.recent_urls

  feed_urls = config.sources["rss"] || []
  feed_url = feed_urls.first
  abort "No RSS feed configured" unless feed_url

  rss_content = URI.open(feed_url).read
  feed = RSS::Parser.parse(rss_content, false)

  episode = feed.items.find do |item|
    enc = item.enclosure
    enc && !used_urls.include?(enc.url)
  end

  abort "No new episodes found" unless episode
  url = episode.enclosure.url
  puts "Episode: #{episode.title}"
end
puts "URL: #{url}"

# --- Phase 1: Download ---
puts "\n=== Phase 1: Download ==="
original = File.join(OUTPUT_DIR, "1_original.mp3")
unless File.exist?(original)
  data = URI.open(url).read
  File.binwrite(original, data)
end
dur = assembler.probe_duration(original)
puts "  Duration: #{dur.round(1)}s"
puts "  Saved: #{original}"

# --- Phase 2: Skip intro ---
skip = config.skip_intro
if skip && skip > 0
  puts "\n=== Phase 2: Skip fixed intro (#{skip}s) ==="
  after_skip = File.join(OUTPUT_DIR, "2_after_skip_intro.mp3")
  assembler.extract_segment(original, after_skip, skip, dur)
  dur2 = assembler.probe_duration(after_skip)
  puts "  Duration: #{dur.round(1)}s → #{dur2.round(1)}s"
  puts "  Saved: #{after_skip}"
  trim_input = after_skip
else
  puts "\n=== Phase 2: No skip_intro configured, skipping ==="
  trim_input = original
end

# --- Phase 3: Bandpass detection ---
puts "\n=== Phase 3: Bandpass speech boundary detection ==="
bp_start, bp_end = assembler.estimate_speech_boundaries(trim_input)
trim_input_dur = assembler.probe_duration(trim_input)

# Show what the pipeline does: skip intro detection if skip_intro is set
if skip && skip > 0
  puts "  (skip_intro is set → skipping bandpass intro detection, only trimming outro)"
  effective_start = 0
else
  effective_start = [bp_start - 3, 0].max
end
puts "  Raw bandpass: #{bp_start.round(1)}s → #{bp_end.round(1)}s"
puts "  After -3s padding: #{effective_start.round(1)}s → #{bp_end.round(1)}s"
puts "  Cutting: #{effective_start.round(1)}s from start, #{(trim_input_dur - bp_end).round(1)}s from end"

after_bp = File.join(OUTPUT_DIR, "3_after_bandpass.mp3")
assembler.extract_segment(trim_input, after_bp, effective_start, bp_end)
dur3 = assembler.probe_duration(after_bp)
puts "  Duration: #{trim_input_dur.round(1)}s → #{dur3.round(1)}s"
puts "  Saved: #{after_bp}"

# --- Summary ---
puts "\n=== Summary ==="
puts "  Original:         #{dur.round(1)}s"
puts "  After skip_intro: #{(dur - (skip || 0)).round(1)}s  (cut #{skip || 0}s)"
bp_cut = effective_start
puts "  After bandpass:   #{dur3.round(1)}s  (cut #{bp_cut.round(1)}s more from start)"
puts ""
puts "  Total cut from start: #{((skip || 0) + bp_cut).round(1)}s"
puts ""
puts "Listen to files in: #{OUTPUT_DIR}"
puts "  1_original.mp3         — full download"
puts "  2_after_skip_intro.mp3 — after #{skip}s fixed cut" if skip && skip > 0
puts "  3_after_bandpass.mp3   — after bandpass trim (final)"
