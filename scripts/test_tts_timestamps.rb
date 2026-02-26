#!/usr/bin/env ruby
# frozen_string_literal: true

# Experimental: TTS with timestamps endpoint
# Reproduces the exact last segment from fulgur_news 2026-02-26 generation
# to inspect character-level timestamps and detect trailing hallucination.

require "httparty"
require "json"
require "base64"
require "dotenv"
require "fileutils"

Dotenv.load(File.join(__dir__, "..", ".env"))

VOICE_ID = ENV.fetch("ELEVENLABS_VOICE_ID")
API_KEY = ENV.fetch("ELEVENLABS_API_KEY")
MODEL_ID = ENV.fetch("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")
OUTPUT_FORMAT = ENV.fetch("ELEVENLABS_OUTPUT_FORMAT", "mp3_44100_128")

# Exact text from fulgur_news-2026-02-26 segment 6/6 "Closing Thought" (472 chars)
TEXT = <<~SCRIPT.strip
  Here's the thought to sit with today. The most important developments in bitcoin and AI right now are infrastructure stories, not price stories. Lightning crossing a billion in monthly volume, Composio open-sourcing production-grade agent orchestration, the SEC and CFTC finally building a coherent regulatory framework — none of these generate the same dopamine hit as a price pump, but they're the foundation everything else gets built on. Pay attention to the plumbing.
SCRIPT

OUTPUT_DIR = File.join(__dir__, "..", "output", "fulgur_news", "tts_timestamp_test")
FileUtils.mkdir_p(OUTPUT_DIR)

timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
audio_path = File.join(OUTPUT_DIR, "closing_thought_#{timestamp}.mp3")
log_path = File.join(OUTPUT_DIR, "closing_thought_#{timestamp}.json")

puts "=== TTS With Timestamps Experiment ==="
puts "Voice: #{VOICE_ID}"
puts "Model: #{MODEL_ID}"
puts "Format: #{OUTPUT_FORMAT}"
puts "Text length: #{TEXT.length} chars"
puts

url = "https://api.elevenlabs.io/v1/text-to-speech/#{VOICE_ID}/with-timestamps?output_format=#{OUTPUT_FORMAT}"

body = {
  text: TEXT,
  model_id: MODEL_ID,
  voice_settings: {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true
  }
}

puts "Calling /with-timestamps endpoint..."
start = Time.now

response = HTTParty.post(
  url,
  headers: {
    "xi-api-key" => API_KEY,
    "Content-Type" => "application/json"
  },
  body: body.to_json,
  timeout: 120
)

elapsed = (Time.now - start).round(2)

unless response.code == 200
  puts "ERROR: HTTP #{response.code}"
  puts response.body[0..500]
  exit 1
end

data = JSON.parse(response.body)
request_id = response.headers["request-id"]

puts "Request ID: #{request_id}"
puts "Response received in #{elapsed}s"
puts

# Decode and save audio
audio_bytes = Base64.decode64(data["audio_base64"])
File.open(audio_path, "wb") { |f| f.write(audio_bytes) }
puts "Audio saved: #{audio_path} (#{audio_bytes.length} bytes)"

# Probe actual audio duration
audio_duration = `ffprobe -v quiet -show_entries format=duration -of csv=p=0 "#{audio_path}"`.strip.to_f
puts "Audio duration: #{audio_duration.round(3)}s"
puts

# Analyze alignment
alignment = data["alignment"]
normalized = data["normalized_alignment"]

if alignment
  chars = alignment["characters"]
  starts = alignment["character_start_times_seconds"]
  ends = alignment["character_end_times_seconds"]

  last_char_end = ends.last
  puts "=== Alignment ==="
  puts "Characters: #{chars.length}"
  puts "First char: '#{chars.first}' starts at #{starts.first}s"
  puts "Last char: '#{chars.last}' ends at #{last_char_end}s"
  puts

  # Trailing audio analysis
  trailing = audio_duration - last_char_end
  puts "=== Trailing Audio Analysis ==="
  puts "Last character ends at: #{last_char_end.round(3)}s"
  puts "Audio file duration:    #{audio_duration.round(3)}s"
  puts "Trailing audio:         #{trailing.round(3)}s"
  puts

  if trailing > 1.0
    puts "WARNING: #{trailing.round(1)}s of audio after last character — potential hallucination zone"
  else
    puts "OK: Trailing audio is minimal (#{trailing.round(3)}s)"
  end
  puts

  # Show last 20 characters with timestamps
  puts "=== Last 20 Characters ==="
  start_idx = [chars.length - 20, 0].max
  (start_idx...chars.length).each do |i|
    c = chars[i] == " " ? "SPC" : chars[i]
    printf "  [%3d] '%s'  %.3f – %.3fs\n", i, c, starts[i], ends[i]
  end
  puts
end

if normalized
  norm_chars = normalized["characters"]
  norm_ends = normalized["character_end_times_seconds"]
  norm_last = norm_ends.last

  puts "=== Normalized Alignment ==="
  puts "Characters: #{norm_chars.length}"
  puts "Last char: '#{norm_chars.last}' ends at #{norm_last}s"
  trailing_norm = audio_duration - norm_last
  puts "Trailing audio (normalized): #{trailing_norm.round(3)}s"
  puts
end

# Save full log
log_data = {
  timestamp: timestamp,
  request_id: request_id,
  elapsed_seconds: elapsed,
  text: TEXT,
  text_length: TEXT.length,
  audio_path: audio_path,
  audio_bytes: audio_bytes.length,
  audio_duration: audio_duration,
  alignment: alignment ? {
    char_count: alignment["characters"].length,
    first_char_start: alignment["character_start_times_seconds"].first,
    last_char_end: alignment["character_end_times_seconds"].last,
    trailing_audio: audio_duration - alignment["character_end_times_seconds"].last
  } : nil,
  normalized_alignment: normalized ? {
    char_count: normalized["characters"].length,
    last_char_end: normalized["character_end_times_seconds"].last,
    trailing_audio: audio_duration - normalized["character_end_times_seconds"].last
  } : nil,
  raw_alignment: alignment,
  raw_normalized_alignment: normalized
}

File.write(log_path, JSON.pretty_generate(log_data))
puts "Full log saved: #{log_path}"
puts
puts "=== Listen & Compare ==="
puts "  Original segment 6: check output/fulgur_news/episodes/ (temp files deleted, but full episode has it at ~12:40)"
puts "  This test segment:  #{audio_path}"
