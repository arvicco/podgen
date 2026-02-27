#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic script: tests reconciliation-based outro detection.
#
# Downloads one episode, skips intro, transcribes with all 3 engines
# (EngineManager), then uses reconciled text + Groq word timestamps
# to find the precise speech end point.
#
# Usage: ruby scripts/test_trim.rb [episode_url]
#   If no URL given, fetches the next unprocessed episode from RSS.
#
# Output (in output/trim_test/):
#   1_original.mp3         — raw download
#   2_after_skip.mp3       — after fixed skip cut
#   3_trimmed.mp3          — after reconciliation-based outro trim
#   3_tail.mp3             — the trimmed tail (should be pure music)

require "dotenv"
Dotenv.load

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "podcast_config"
require "audio_assembler"
require "episode_history"
require_relative "../lib/logger"
require_relative "../lib/transcription/engine_manager"
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
skip = config.skip
audio_path = original
if skip && skip > 0
  puts "\n=== Phase 2: Skip fixed intro (#{skip}s) ==="
  after_skip = File.join(OUTPUT_DIR, "2_after_skip.mp3")
  assembler.extract_segment(original, after_skip, skip, dur)
  dur2 = assembler.probe_duration(after_skip)
  puts "  Duration: #{dur.round(1)}s -> #{dur2.round(1)}s"
  puts "  Saved: #{after_skip}"
  audio_path = after_skip
else
  puts "\n=== Phase 2: No skip configured, skipping ==="
end

# --- Phase 3: Transcribe with all engines ---
puts "\n=== Phase 3: Transcribe with all engines ==="
language = config.transcription_language || "sl"
engine_codes = config.transcription_engines
puts "  Engines: #{engine_codes.join(', ')}"
puts "  Language: #{language}"

manager = Transcription::EngineManager.new(
  engine_codes: engine_codes,
  language: language,
  target_language: config.target_language,
  logger: logger
)
result = manager.transcribe(audio_path)

if engine_codes.length > 1
  reconciled_text = result[:reconciled]
  groq_words = result[:all]["groq"]&.dig(:words) || []
  all_results = result[:all]

  puts "\n  Per-engine results:"
  all_results.each do |code, r|
    puts "    #{code}: #{r[:text].length} chars"
  end
  puts "  Reconciled: #{reconciled_text&.length || 'FAILED'} chars"
  puts "  Groq words: #{groq_words.length}"
else
  puts "  Single engine mode — reconciliation-based trim requires 2+ engines"
  reconciled_text = result[:cleaned] || result[:text]
  groq_words = result[:words] || []
end

# --- Phase 4: Show Groq word timestamps ---
if groq_words.any?
  puts "\n=== Phase 4: Groq word timestamps (last 15) ==="
  groq_words.last(15).each do |w|
    puts "    #{w[:start].round(2)}s - #{w[:end].round(2)}s: \"#{w[:word]}\""
  end
end

# --- Phase 5: Show reconciled text ending ---
if reconciled_text
  puts "\n=== Phase 5: Reconciled text ending ==="
  words = reconciled_text.split(/\s+/).reject(&:empty?)
  puts "  Total words: #{words.length}"
  puts "  Last 10 words: #{words.last(10).join(' ')}"
end

# --- Phase 6: Match reconciled ending to Groq timestamps ---
if reconciled_text && groq_words.any?
  puts "\n=== Phase 6: Word matching ==="

  reconciled_words = reconciled_text.split(/\s+/).reject(&:empty?)
  normalize = ->(w) { w.downcase.gsub(/[^\p{L}\p{N}]/, "") }
  min_prefix = 3
  fuzzy_match = ->(a, b) {
    return true if a == b
    shorter, longer = [a, b].sort_by(&:length)
    return false if shorter.length < min_prefix
    longer.start_with?(shorter)
  }
  matched_end = nil
  matched_n = nil

  [5, 4, 3, 2, 1].each do |n|
    next if reconciled_words.length < n

    target = reconciled_words.last(n).map { |w| normalize.call(w) }
    next if target.any?(&:empty?)

    (groq_words.length - n).downto(0) do |i|
      candidate = groq_words[i, n].map { |w| normalize.call(w[:word]) }
      if target.zip(candidate).all? { |a, b| fuzzy_match.call(a, b) }
        matched_end = groq_words[i + n - 1][:end]
        matched_n = n
        break
      end
    end
    break if matched_end
  end

  if matched_end
    puts "  Matched last #{matched_n} words at #{matched_end.round(2)}s"
    puts "  Matched words: #{reconciled_words.last(matched_n).join(' ')}"

    audio_dur = assembler.probe_duration(audio_path)
    savings = audio_dur - matched_end
    trim_point = matched_end + 2

    puts "  Audio duration: #{audio_dur.round(1)}s"
    puts "  Speech end: #{matched_end.round(1)}s"
    puts "  Trim point: #{trim_point.round(1)}s (+2s padding)"
    puts "  Would save: #{savings.round(1)}s"

    if savings >= 5
      # Save trimmed version
      trimmed = File.join(OUTPUT_DIR, "3_trimmed.mp3")
      assembler.trim_to_duration(audio_path, trimmed, trim_point)
      puts "\n  Saved trimmed: #{trimmed}"

      # Save tail
      tail = File.join(OUTPUT_DIR, "3_tail.mp3")
      assembler.extract_segment(audio_path, tail, trim_point, audio_dur)
      puts "  Saved tail: #{tail} (#{(audio_dur - trim_point).round(1)}s — should be pure music)"
    else
      puts "  Savings < 5s — would not trim"
    end
  else
    puts "  No match found between reconciled text and Groq timestamps"
  end
else
  puts "\n  Skipping word matching (need reconciled text + groq words)"
end

# --- Summary ---
puts "\n=== Summary ==="
puts "  Original:    #{dur.round(1)}s"
puts "  After skip:  #{assembler.probe_duration(audio_path).round(1)}s" if skip && skip > 0
if matched_end
  puts "  Speech end:  #{matched_end.round(1)}s"
  puts "  Trim point:  #{(matched_end + 2).round(1)}s"
end
puts ""
puts "Listen to files in: #{OUTPUT_DIR}"
