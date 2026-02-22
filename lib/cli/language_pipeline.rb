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

    # Whisper segment quality thresholds (only used with whisper-1).
    NO_SPEECH_PROB_THRESHOLD = 0.6
    COMPRESSION_RATIO_THRESHOLD = 2.4
    AVG_LOGPROB_THRESHOLD = -1.0

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

      # --- Phase 3: Bandpass trim (remove intro/outro music) ---
      # When skip_intro is set, it already handled the intro jingle — only detect outro.
      logger.phase_start("Trim Music")
      assembler ||= AudioAssembler.new(logger: logger)
      bp_start, bp_end = assembler.estimate_speech_boundaries(source_audio_path)
      if @config.skip_intro && @config.skip_intro > 0
        bp_start = 0
      else
        bp_start = [bp_start - 3, 0].max # extra padding — greeting sits at music boundary
      end

      trimmed_path = File.join(Dir.tmpdir, "podgen_trimmed_#{Process.pid}.mp3")
      @temp_files << trimmed_path
      assembler.extract_segment(source_audio_path, trimmed_path, bp_start, bp_end)
      logger.log("Trimmed to #{bp_start.round(1)}s → #{bp_end.round(1)}s")

      # Refine: if bandpass left trailing music, detect it and re-trim
      trimmed_path = refine_tail_trim(assembler, trimmed_path)
      logger.phase_end("Trim Music")

      # --- Phase 4: Transcribe trimmed audio ---
      logger.phase_start("Transcription")
      result = transcribe_audio(trimmed_path)
      logger.phase_end("Transcription")

      # --- Phase 5: Build transcript ---
      # gpt-4o-transcribe: use text directly (no segments to filter)
      # whisper-1: filter segments by metadata + acoustic music detection
      logger.phase_start("Build Transcript")
      transcript = if result[:segments].empty?
                     logger.log("Using transcript text directly (no segments)")
                     result[:text]
                   else
                     filter_transcript(assembler, trimmed_path, result[:segments])
                   end
      logger.phase_end("Build Transcript")

      # --- Phase 6: Assemble (trimmed audio as single piece) ---
      logger.phase_start("Assembly")
      base_name = @config.episode_basename(@today)
      output_path = File.join(@config.episodes_dir, "#{base_name}.mp3")

      intro_music_path = File.join(@config.podcast_dir, "intro.mp3")
      outro_music_path = File.join(@config.podcast_dir, "outro.mp3")

      assembler.assemble([trimmed_path], output_path, intro_path: intro_music_path, outro_path: outro_music_path)
      logger.phase_end("Assembly")

      # --- Save transcript ---
      save_transcript(episode, transcript, base_name)

      # --- Phase 7: LingQ Upload (if enabled) ---
      upload_to_lingq(episode, @reconciled_text || transcript, output_path)

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

    # Bandpass outro detection misses music with speech-band energy.
    # Use raw silence detection: the last silence gap followed by 15+ seconds
    # of continuous audio marks where the narrator stops and music begins.
    MIN_OUTRO_MUSIC = 15 # seconds of continuous audio to count as outro music

    def refine_tail_trim(assembler, trimmed_path)
      total_duration = assembler.probe_duration(trimmed_path)
      silences = assembler.detect_silences(trimmed_path)

      # Find the last silence gap where the remaining audio is all continuous (outro music)
      speech_end = nil
      silences.reverse_each do |s|
        remaining = total_duration - s[:end]
        if remaining >= MIN_OUTRO_MUSIC
          speech_end = s[:start]
          break
        end
      end

      return trimmed_path unless speech_end

      # Only re-trim if we'd actually cut something meaningful (> 10s)
      savings = total_duration - speech_end
      return trimmed_path if savings < 10

      logger.log("Refining tail: speech ends at #{speech_end.round(1)}s, " \
        "cutting #{savings.round(1)}s of trailing music (total was #{total_duration.round(1)}s)")

      refined_path = File.join(Dir.tmpdir, "podgen_refined_#{Process.pid}.mp3")
      @temp_files << refined_path
      assembler.trim_to_duration(trimmed_path, refined_path, speech_end + 1.5)
      refined_path
    end

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
        # Comparison mode — stash per-engine results for save_transcript
        @comparison_results = result[:all]
        @comparison_errors = result[:errors]
        @reconciled_text = result[:reconciled]
        result[:primary]
      else
        # Single engine — use cleaned text if available
        @reconciled_text = result[:cleaned]
        result
      end
    end

    # Whisper-1 fallback: filter segments by metadata + acoustic music regions.
    # Returns transcript string.
    def filter_transcript(assembler, trimmed_path, segments)
      logger.log("Filtering #{segments.length} Whisper segments")

      # 1. Metadata filter (2+ flags)
      kept = filter_speech_segments(segments)

      # 2. Acoustic music region filter
      music_regions = assembler.detect_music_regions(trimmed_path)
      kept = exclude_music_segments(kept, music_regions)

      kept.map { |s| s[:text] }.join(" ").strip
    end

    # Filters Whisper segments using the model's own confidence signals.
    # Require 2+ signals to agree before dropping.
    def filter_speech_segments(segments)
      return segments if segments.empty?

      kept = []
      dropped = 0

      segments.each do |seg|
        flags = []

        if seg[:no_speech_prob] > NO_SPEECH_PROB_THRESHOLD
          flags << "no_speech=#{seg[:no_speech_prob].round(2)}"
        end

        if seg[:compression_ratio] > COMPRESSION_RATIO_THRESHOLD
          flags << "compression=#{seg[:compression_ratio].round(2)}"
        end

        if seg[:avg_logprob] < AVG_LOGPROB_THRESHOLD
          flags << "logprob=#{seg[:avg_logprob].round(2)}"
        end

        if flags.length >= 2
          dropped += 1
          logger.log("  Drop #{seg[:start].round(1)}s→#{seg[:end].round(1)}s " \
            "(#{flags.join(', ')}): \"#{seg[:text].strip[0, 50]}\"")
        else
          kept << seg
        end
      end

      if dropped > 0
        logger.log("Metadata filter: kept #{kept.length}/#{segments.length} (dropped #{dropped})")
      end

      kept
    end

    # Excludes Whisper segments that fall within acoustically-detected music regions.
    def exclude_music_segments(segments, music_regions)
      return segments if music_regions.empty?

      before = segments.length
      kept = segments.reject do |seg|
        region = music_regions.find { |r| seg[:start] >= r[:start] && seg[:start] < r[:end] }
        if region
          logger.log("  Excluding #{seg[:start].round(1)}s→#{seg[:end].round(1)}s " \
            "(in music #{region[:start].round(1)}→#{region[:end].round(1)}): " \
            "\"#{seg[:text].strip[0, 50]}\"")
          true
        end
      end

      dropped = before - kept.length
      if dropped > 0
        logger.log("Music filter: excluded #{dropped} segments in #{music_regions.length} region(s)")
      end

      kept
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
      formatted = transcript.gsub(/([.!?])(\s+)/, "\\1\n").strip

      File.open(path, "w") do |f|
        f.puts "# #{episode[:title]}"
        f.puts
        f.puts "#{episode[:description]}" unless episode[:description].to_s.empty?
        f.puts
        f.puts "## Transcript"
        f.puts
        f.puts formatted
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
