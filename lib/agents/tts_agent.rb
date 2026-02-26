# frozen_string_literal: true

require "httparty"
require "json"
require "base64"
require "open3"
require "digest"
require "yaml"
require "fileutils"
require "tmpdir"

class TTSAgent
  BASE_URL = "https://api.elevenlabs.io/v1/text-to-speech"
  DICT_API_URL = "https://api.elevenlabs.io/v1/pronunciation-dictionaries"
  TRIM_THRESHOLD = 0.5 # seconds of trailing audio before we trim
  MAX_CHARS = 9_500 # Safety margin below eleven_multilingual_v2's 10,000 limit
  MAX_RETRIES = 3
  RETRIABLE_CODES = [429, 503].freeze

  def initialize(logger: nil, voice_id_override: nil, pronunciation_pls_path: nil)
    @logger = logger
    @api_key = ENV.fetch("ELEVENLABS_API_KEY") { raise "ELEVENLABS_API_KEY environment variable is not set" }
    @voice_id = voice_id_override || ENV.fetch("ELEVENLABS_VOICE_ID") { raise "ELEVENLABS_VOICE_ID environment variable is not set" }
    @model_id = ENV.fetch("ELEVENLABS_MODEL_ID", "eleven_multilingual_v2")
    @output_format = ENV.fetch("ELEVENLABS_OUTPUT_FORMAT", "mp3_44100_128")
    @pronunciation_locators = resolve_pronunciation_dictionary(pronunciation_pls_path)
  end

  # Input: array of { name:, text: } segment hashes
  # Output: ordered array of file paths to MP3 files
  def synthesize(segments)
    audio_paths = []
    previous_request_ids = []

    segments.each_with_index do |segment, idx|
      log("Synthesizing segment #{idx + 1}/#{segments.length}: #{segment[:name]} (#{segment[:text].length} chars)")
      start = Time.now

      chunks = split_text(segment[:text])

      chunks.each_with_index do |chunk, chunk_idx|
        log("  Chunk #{chunk_idx + 1}/#{chunks.length} (#{chunk.length} chars)") if chunks.length > 1

        path = File.join(Dir.tmpdir, "podgen_#{idx}_#{chunk_idx}_#{Process.pid}.mp3")
        request_id = synthesize_chunk(
          text: chunk,
          path: path,
          previous_request_ids: previous_request_ids.last(3)
        )

        audio_paths << path
        previous_request_ids << request_id if request_id

        log("  Saved #{File.size(path)} bytes → #{path}")
      end

      elapsed = (Time.now - start).round(2)
      log("  Done in #{elapsed}s")
    end

    audio_paths
  end

  private

  def synthesize_chunk(text:, path:, previous_request_ids: [])
    url = "#{BASE_URL}/#{@voice_id}/with-timestamps?output_format=#{@output_format}"

    body = {
      text: text,
      model_id: @model_id,
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.0,
        use_speaker_boost: true
      }
    }
    body[:previous_request_ids] = previous_request_ids unless previous_request_ids.empty?
    body[:pronunciation_dictionary_locators] = @pronunciation_locators unless @pronunciation_locators.empty?

    retries = 0
    begin
      retries += 1

      response = HTTParty.post(
        url,
        headers: {
          "xi-api-key" => @api_key,
          "Content-Type" => "application/json"
        },
        body: body.to_json,
        timeout: 120
      )

      case response.code
      when 200
        data = JSON.parse(response.body)
        audio_bytes = Base64.decode64(data["audio_base64"])
        File.open(path, "wb") { |f| f.write(audio_bytes) }

        alignment = data["alignment"]
        trim_trailing_audio(path, alignment) if alignment

        response.headers["request-id"]
      when *RETRIABLE_CODES
        raise RetriableError, "HTTP #{response.code}: #{parse_error(response)}"
      else
        raise "TTS failed: HTTP #{response.code}: #{parse_error(response)}"
      end

    rescue RetriableError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("  Retry #{retries}/#{MAX_RETRIES} in #{sleep_time}s: #{e.message}")
        sleep(sleep_time)
        retry
      else
        raise "TTS failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    end
  end

  def trim_trailing_audio(path, alignment)
    end_times = alignment["character_end_times_seconds"]
    return unless end_times&.any?

    speech_end = end_times.last
    audio_duration = probe_duration(path)
    trailing = audio_duration - speech_end

    log("  Trailing audio: #{trailing.round(2)}s (speech ends at #{speech_end.round(2)}s, audio is #{audio_duration.round(2)}s)")

    return unless trailing > TRIM_THRESHOLD

    silenced_path = "#{path}.silenced.mp3"
    af = "volume=enable='gt(t,#{speech_end})':volume=0"
    cmd = ["ffmpeg", "-y", "-i", path, "-af", af, "-c:a", "libmp3lame", "-b:a", "192k", silenced_path]
    _out, err, status = Open3.capture3(*cmd)

    unless status.success?
      log("  WARNING: ffmpeg silence failed, keeping original: #{err}")
      return
    end

    FileUtils.mv(silenced_path, path)
    log("  Silenced #{trailing.round(2)}s trailing audio (replaced with silence)")
  end

  def probe_duration(path)
    cmd = ["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", path]
    out, _err, status = Open3.capture3(*cmd)
    raise "ffprobe failed for #{path}" unless status.success?

    out.strip.to_f
  end

  def resolve_pronunciation_dictionary(pls_path)
    return [] unless pls_path && File.exist?(pls_path)

    file_sha = Digest::SHA256.file(pls_path).hexdigest
    cache_path = pls_path.sub(/\.pls$/, ".yml")
    cached = load_dict_cache(cache_path)

    if cached && cached[:file_sha256] == file_sha
      log("Using cached pronunciation dictionary #{cached[:dictionary_id]}")
      return [{ pronunciation_dictionary_id: cached[:dictionary_id], version_id: cached[:version_id] }]
    end

    log("Uploading pronunciation dictionary: #{File.basename(pls_path)}")
    dict = upload_pronunciation_dictionary(pls_path)
    save_dict_cache(cache_path, dict[:dictionary_id], dict[:version_id], file_sha)
    log("Pronunciation dictionary ready: #{dict[:dictionary_id]} (v#{dict[:version_id]})")

    [{ pronunciation_dictionary_id: dict[:dictionary_id], version_id: dict[:version_id] }]
  rescue => e
    log("WARNING: Pronunciation dictionary failed, continuing without: #{e.message}")
    []
  end

  def upload_pronunciation_dictionary(pls_path)
    name = "podgen_#{File.basename(pls_path, '.pls')}_#{Time.now.strftime('%Y%m%d%H%M%S')}"

    response = HTTParty.post(
      "#{DICT_API_URL}/add-from-file",
      headers: { "xi-api-key" => @api_key },
      multipart: true,
      body: {
        name: name,
        file: File.open(pls_path, "rb")
      },
      timeout: 30
    )

    unless response.code == 200
      raise "Upload failed: HTTP #{response.code}: #{parse_error(response)}"
    end

    data = JSON.parse(response.body)
    { dictionary_id: data["id"], version_id: data["version_id"] }
  end

  def load_dict_cache(path)
    return nil unless File.exist?(path)

    data = YAML.load_file(path)
    return nil unless data.is_a?(Hash) && data["dictionary_id"] && data["version_id"] && data["file_sha256"]

    { dictionary_id: data["dictionary_id"], version_id: data["version_id"], file_sha256: data["file_sha256"] }
  rescue => _e
    nil
  end

  def save_dict_cache(path, dictionary_id, version_id, file_sha)
    File.write(path, YAML.dump({
      "dictionary_id" => dictionary_id,
      "version_id" => version_id,
      "file_sha256" => file_sha
    }))
  end

  def split_text(text)
    return [text] if text.length <= MAX_CHARS

    chunks = []
    remaining = text.dup

    while remaining.length > MAX_CHARS
      split_at = remaining.rindex(/\n\n/, MAX_CHARS) ||
                 remaining.rindex(/(?<=[.!?])\s+/, MAX_CHARS) ||
                 remaining.rindex(/[,;:]\s+/, MAX_CHARS) ||
                 remaining.rindex(/\s+/, MAX_CHARS) ||
                 find_safe_split_point(remaining, MAX_CHARS)
      split_at = [split_at, 1].max

      chunks << remaining[0...split_at].strip
      remaining = remaining[split_at..].strip
    end

    chunks << remaining unless remaining.empty?
    chunks
  end

  # Walk backward from max_pos to find a safe split point that doesn't
  # break a multi-byte UTF-8 character or grapheme cluster.
  def find_safe_split_point(text, max_pos)
    pos = max_pos
    # Walk backward to find an ASCII char or whitespace boundary
    while pos > 0
      char = text[pos]
      break if char && (char.ascii_only? || char.match?(/\s/))
      pos -= 1
    end
    # If we walked all the way back, just use max_pos (degenerate case)
    pos > 0 ? pos : max_pos
  end

  def parse_error(response)
    parsed = JSON.parse(response.body)
    detail = parsed["detail"]
    detail.is_a?(Hash) ? "#{detail['code']}: #{detail['message']}" : detail.to_s
  rescue JSON::ParserError
    response.body[0..200]
  end

  def log(message)
    if @logger
      @logger.log("[TTSAgent] #{message}")
    else
      puts "[TTSAgent] #{message}"
    end
  end

  class RetriableError < StandardError; end
end
