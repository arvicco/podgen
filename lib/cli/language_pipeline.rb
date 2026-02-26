# frozen_string_literal: true

require "net/http"
require "uri"
require "tmpdir"
require "fileutils"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "sources", "rss_source")
require_relative File.join(root, "lib", "transcription", "engine_manager")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "agents", "lingq_agent")
require_relative File.join(root, "lib", "agents", "cover_agent")

module PodgenCLI
  class LanguagePipeline
    MAX_DOWNLOAD_RETRIES = 3
    MAX_DOWNLOAD_SIZE = 200 * 1024 * 1024 # 200 MB
    MIN_OUTRO_SAVINGS = 5 # minimum seconds saved to bother trimming outro

    def initialize(config:, options:, logger:, history:, today:)
      @config = config
      @options = options
      @dry_run = options[:dry_run] || false
      @logger = logger
      @history = history
      @today = today
      @temp_files = []
    end

    def run
      pipeline_start = Time.now
      logger.log("Language pipeline started#{@dry_run ? ' (DRY RUN)' : ''}")

      # --- Phase 1: Fetch next episode from RSS ---
      logger.phase_start("Fetch Episode")
      episode = fetch_next_episode
      unless episode
        logger.error("No new episodes found in RSS feeds")
        return 1
      end
      logger.log("Selected episode: \"#{episode[:title]}\" (#{episode[:audio_url]})")
      logger.phase_end("Fetch Episode")

      if @dry_run
        logger.log("[dry-run] Skipping download, transcription, assembly, and history")
        total_time = (Time.now - pipeline_start).round(2)
        summary = "[dry-run] Config validated, episode \"#{episode[:title]}\" — no API calls"
        logger.log("Total pipeline time: #{total_time}s")
        logger.log(summary)
        puts summary unless @options[:verbosity] == :quiet
        return 0
      end

      # --- Phase 2: Download source audio ---
      logger.phase_start("Download Audio")
      source_audio_path = download_audio(episode[:audio_url])
      logger.log("Downloaded source audio: #{(File.size(source_audio_path) / (1024.0 * 1024)).round(2)} MB")
      logger.phase_end("Download Audio")

      # --- Phase 2b: Skip fixed intro if configured ---
      if @config.skip_intro && @config.skip_intro > 0
        assembler = AudioAssembler.new(logger: logger)
        total = assembler.probe_duration(source_audio_path)
        skip = @config.skip_intro
        skipped_path = File.join(Dir.tmpdir, "podgen_skipped_#{Process.pid}.mp3")
        @temp_files << skipped_path
        assembler.extract_segment(source_audio_path, skipped_path, skip, total)
        logger.log("Skipped fixed intro: #{skip}s (#{total.round(1)}s → #{(total - skip).round(1)}s)")
        source_audio_path = skipped_path
      end

      # --- Phase 3: Transcribe full audio ---
      logger.phase_start("Transcription")
      assembler ||= AudioAssembler.new(logger: logger)
      base_name = @config.episode_basename(@today)
      result = transcribe_audio(source_audio_path)
      logger.phase_end("Transcription")

      # --- Phase 4: Trim outro via reconciled text + Groq word timestamps ---
      if @reconciled_text && @groq_words&.any?
        logger.phase_start("Trim Outro")
        source_audio_path = trim_outro(assembler, source_audio_path, base_name)
        logger.phase_end("Trim Outro")
      else
        logger.log("Skipping outro trim (requires 2+ engines with groq)")
      end

      # --- Phase 5: Build transcript ---
      transcript = @reconciled_text || result[:text]

      # --- Phase 6: Assemble (trimmed audio as single piece) ---
      logger.phase_start("Assembly")
      output_path = File.join(@config.episodes_dir, "#{base_name}.mp3")

      intro_music_path = File.join(@config.podcast_dir, "intro.mp3")
      outro_music_path = File.join(@config.podcast_dir, "outro.mp3")

      assembler.assemble([source_audio_path], output_path, intro_path: intro_music_path, outro_path: outro_music_path)
      logger.phase_end("Assembly")

      # --- Save transcript ---
      save_transcript(episode, transcript, base_name)

      # --- Phase 7: LingQ Upload (if enabled via --lingq flag) ---
      upload_to_lingq(episode, @reconciled_text || transcript, output_path) if @options[:lingq]

      # --- Phase 8: Record history ---
      @history.record!(
        date: @today,
        title: episode[:title],
        topics: [episode[:title]],
        urls: [episode[:audio_url]]
      )
      logger.log("Episode recorded in history: #{@config.history_path}")

      # --- Done ---
      total_time = (Time.now - pipeline_start).round(2)
      logger.log("Total pipeline time: #{total_time}s")
      logger.log("\u2713 Episode ready: #{output_path}")
      puts "\u2713 Episode ready: #{output_path}" unless @options[:verbosity] == :quiet

      0
    rescue => e
      logger.error("#{e.class}: #{e.message}")
      logger.error(e.backtrace.first(5).join("\n"))
      $stderr.puts "\n\u2717 Language pipeline failed: #{e.message}" unless @options[:verbosity] == :quiet
      1
    ensure
      cleanup_temp_files
    end

    private

    attr_reader :logger

    def fetch_next_episode
      rss_feeds = @config.sources["rss"]
      unless rss_feeds.is_a?(Array) && rss_feeds.any?
        raise "Language pipeline requires RSS sources in guidelines.md (## Sources → - rss:)"
      end

      source = RSSSource.new(feeds: rss_feeds, logger: logger)
      episodes = source.fetch_episodes(exclude_urls: @history.recent_urls)

      if episodes.empty?
        logger.log("No episodes with audio enclosures found")
        return nil
      end

      logger.log("Found #{episodes.length} episodes with audio enclosures")
      episodes.first
    end

    def transcribe_audio(audio_path)
      language = @config.transcription_language
      raise "Language pipeline requires ## Transcription Language in guidelines.md" unless language

      engine_codes = @config.transcription_engines
      manager = Transcription::EngineManager.new(
        engine_codes: engine_codes,
        language: language,
        target_language: @config.target_language,
        logger: logger
      )
      result = manager.transcribe(audio_path)

      if engine_codes.length > 1
        # Comparison mode — stash per-engine results for save_transcript and outro trim
        @comparison_results = result[:all]
        @comparison_errors = result[:errors]
        @reconciled_text = result[:reconciled]
        @groq_words = result[:all]["groq"]&.dig(:words)
        result[:primary]
      else
        # Single engine — use cleaned text if available
        @reconciled_text = result[:cleaned]
        result
      end
    end

    # Trims outro music by mapping the end of reconciled text back to Groq word timestamps.
    # Returns trimmed audio path, or original path if no trim needed.
    def trim_outro(assembler, audio_path, base_name)
      speech_end = find_speech_end_timestamp(@reconciled_text, @groq_words)

      unless speech_end
        logger.log("Could not match reconciled text ending to Groq timestamps — skipping trim")
        return audio_path
      end

      total_duration = assembler.probe_duration(audio_path)
      savings = total_duration - speech_end
      trim_point = speech_end + 2 # 2s padding after last word

      if savings < MIN_OUTRO_SAVINGS
        logger.log("Outro trim would only save #{savings.round(1)}s (< #{MIN_OUTRO_SAVINGS}s) — skipping")
        return audio_path
      end

      logger.log("Speech ends at #{speech_end.round(1)}s, trimming at #{trim_point.round(1)}s " \
        "(saving #{savings.round(1)}s of #{total_duration.round(1)}s)")

      # Save tail for review
      tails_dir = File.join(File.dirname(@config.episodes_dir), "tails")
      FileUtils.mkdir_p(tails_dir)
      tail_path = File.join(tails_dir, "#{base_name}_tail.mp3")
      assembler.extract_segment(audio_path, tail_path, trim_point, total_duration)
      logger.log("Saved tail for review: #{tail_path}")

      # Trim audio
      trimmed_path = File.join(Dir.tmpdir, "podgen_trimmed_#{Process.pid}.mp3")
      @temp_files << trimmed_path
      assembler.trim_to_duration(audio_path, trimmed_path, trim_point)
      trimmed_path
    end

    # Maps the last words of reconciled text back to Groq's word-level timestamps.
    # Tries matching last 5 words, then 4, 3, 2, 1.
    # Returns the end timestamp of the matched word, or nil if no match.
    def find_speech_end_timestamp(reconciled_text, groq_words)
      reconciled_words = reconciled_text.split(/\s+/).reject(&:empty?)
      return nil if reconciled_words.empty?

      # Try matching last N words (5 down to 1), using fuzzy prefix matching
      # to handle inflection differences (e.g. "sanjam" vs "sanja", "noč" vs "noči")
      [5, 4, 3, 2, 1].each do |n|
        next if reconciled_words.length < n

        target = reconciled_words.last(n).map { |w| normalize_word(w) }
        next if target.any?(&:empty?)

        # Search backwards through Groq words for matching sequence
        (groq_words.length - n).downto(0) do |i|
          candidate = groq_words[i, n].map { |w| normalize_word(w[:word]) }
          if words_match?(target, candidate)
            matched_end = groq_words[i + n - 1][:end]
            logger.log("Matched last #{n} words at Groq timestamp #{matched_end.round(1)}s: #{candidate.join(' ')} ~ #{target.join(' ')}")
            return matched_end
          end
        end
      end

      logger.log("No word sequence match found between reconciled text and Groq timestamps")
      nil
    end

    def normalize_word(word)
      word.downcase.gsub(/[^\p{L}\p{N}]/, "")
    end

    # Fuzzy sequence match: all word pairs must match.
    def words_match?(target, candidate)
      target.zip(candidate).all? { |a, b| word_match?(a, b) }
    end

    # Two normalized words match if they share a common prefix of 3+ chars.
    # Handles inflection differences (e.g. "sanjam"/"sanja", "noč"/"noči").
    MIN_PREFIX = 3

    def word_match?(a, b)
      return true if a == b

      shorter, longer = [a, b].sort_by(&:length)
      return false if shorter.length < MIN_PREFIX

      longer.start_with?(shorter)
    end

    def download_audio(url)
      logger.log("Downloading audio: #{url}")
      path = File.join(Dir.tmpdir, "podgen_source_#{Process.pid}.mp3")
      @temp_files << path

      retries = 0
      begin
        retries += 1
        uri = URI.parse(url)
        download_with_redirects(uri, path)
      rescue => e
        if retries <= MAX_DOWNLOAD_RETRIES
          sleep_time = 2**retries
          logger.log("Download error: #{e.message}, retry #{retries}/#{MAX_DOWNLOAD_RETRIES} in #{sleep_time}s")
          sleep(sleep_time)
          retry
        end
        raise "Failed to download audio after #{MAX_DOWNLOAD_RETRIES} retries: #{e.message}"
      end

      raise "Downloaded file is empty: #{url}" unless File.size(path) > 0

      path
    end

    def download_with_redirects(uri, path, redirects_left = 3)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 120) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "PodcastAgent/1.0"

        http.request(request) do |response|
          case response
          when Net::HTTPSuccess
            bytes = 0
            File.open(path, "wb") do |f|
              response.read_body do |chunk|
                bytes += chunk.bytesize
                raise "Download exceeds #{MAX_DOWNLOAD_SIZE / (1024 * 1024)} MB limit" if bytes > MAX_DOWNLOAD_SIZE
                f.write(chunk)
              end
            end
          when Net::HTTPRedirection
            raise "Too many redirects" if redirects_left <= 0
            location = response["location"]
            location = URI.join(uri.to_s, location).to_s unless location.start_with?("http")
            logger.log("Following redirect → #{location}")
            download_with_redirects(URI.parse(location), path, redirects_left - 1)
          else
            raise "HTTP #{response.code} downloading #{uri}"
          end
        end
      end
    end

    def save_transcript(episode, transcript, base_name)
      # Use reconciled text as primary if available (multi-engine mode)
      primary_text = @reconciled_text || transcript
      transcript_path = File.join(@config.episodes_dir, "#{base_name}_transcript.md")
      write_transcript_file(transcript_path, episode, primary_text)
      if @reconciled_text
        logger.log("Reconciled transcript saved to #{transcript_path}")
      else
        logger.log("Transcript saved to #{transcript_path}")
      end

      # Save per-engine transcripts only in verbose mode (for comparison/debugging)
      return unless @comparison_results&.any? && @options[:verbosity] == :verbose

      @comparison_results.each do |code, result|
        engine_path = File.join(@config.episodes_dir, "#{base_name}_transcript_#{code}.md")
        write_transcript_file(engine_path, episode, result[:text])
        logger.log("Comparison transcript (#{code}) saved to #{engine_path}")
      end

      if @comparison_errors&.any?
        @comparison_errors.each do |code, error|
          logger.log("Comparison engine '#{code}' failed: #{error}")
        end
      end
    end

    def write_transcript_file(path, episode, transcript)
      FileUtils.mkdir_p(File.dirname(path))

      File.open(path, "w") do |f|
        f.puts "# #{episode[:title]}"
        f.puts
        f.puts "#{episode[:description]}" unless episode[:description].to_s.empty?
        f.puts
        f.puts "## Transcript"
        f.puts
        f.puts transcript.strip
      end
    end

    def upload_to_lingq(episode, transcript, audio_path)
      return unless @config.lingq_enabled?

      if @dry_run
        logger.log("[dry-run] Skipping LingQ upload")
        return
      end

      logger.phase_start("LingQ Upload")
      lc = @config.lingq_config
      language = @config.transcription_language

      image_path = generate_cover_image(episode[:title], lc)

      agent = LingQAgent.new(logger: logger)
      agent.upload(
        title: episode[:title],
        text: transcript,
        audio_path: audio_path,
        language: language,
        collection: lc[:collection],
        level: lc[:level],
        tags: lc[:tags],
        image_path: image_path,
        accent: lc[:accent],
        status: lc[:status],
        description: episode[:description],
        original_url: episode[:audio_url]
      )
      logger.phase_end("LingQ Upload")
    rescue => e
      logger.log("Warning: LingQ upload failed: #{e.message} (non-fatal, continuing)")
      logger.log(e.backtrace.first(3).join("\n"))
    end

    # Generates a per-episode cover image with the title overlaid on the base image.
    # Returns the generated image path, or falls back to the static image path.
    def generate_cover_image(title, lingq_config)
      return lingq_config[:image] unless @config.cover_generation_enabled?

      cover_path = File.join(Dir.tmpdir, "podgen_cover_#{Process.pid}.jpg")
      @temp_files << cover_path

      options = {}
      options[:font] = lingq_config[:font] if lingq_config[:font]
      options[:font_color] = lingq_config[:font_color] if lingq_config[:font_color]
      options[:font_size] = lingq_config[:font_size] if lingq_config[:font_size]
      options[:text_width] = lingq_config[:text_width] if lingq_config[:text_width]
      options[:gravity] = lingq_config[:text_gravity] if lingq_config[:text_gravity]
      options[:x_offset] = lingq_config[:text_x_offset] if lingq_config[:text_x_offset]
      options[:y_offset] = lingq_config[:text_y_offset] if lingq_config[:text_y_offset]

      agent = CoverAgent.new(logger: logger)
      agent.generate(
        title: title,
        base_image: lingq_config[:base_image],
        output_path: cover_path,
        options: options
      )

      cover_path
    rescue => e
      logger.log("Warning: Cover generation failed: #{e.message} (falling back to static image)")
      lingq_config[:image]
    end

    def cleanup_temp_files
      @temp_files.each do |path|
        File.delete(path) if File.exist?(path)
      rescue => e
        logger.log("Warning: failed to cleanup #{path}: #{e.message}")
      end
    end
  end
end
