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
require_relative File.join(root, "lib", "agents", "description_agent")
require_relative File.join(root, "lib", "youtube_downloader")

module PodgenCLI
  class LanguagePipeline
    MAX_DOWNLOAD_RETRIES = 3
    MAX_DOWNLOAD_SIZE = 200 * 1024 * 1024 # 200 MB
    MIN_OUTRO_SAVINGS = 5 # minimum seconds saved to bother trimming outro

    def initialize(config:, options:, logger:, history:, today:)
      @config = config
      @options = options
      @dry_run = options[:dry_run] || false
      @local_file = options[:file]
      @youtube_url = options[:url]
      @file_title = options[:title]
      @logger = logger
      @history = history
      @today = today
      @temp_files = []
      @youtube_captions = nil
    end

    def run
      pipeline_start = Time.now
      logger.log("Language pipeline started#{@dry_run ? ' (DRY RUN)' : ''}")

      if @options[:image] == "thumb" && !@youtube_url
        $stderr.puts "Error: --image thumb is only valid with --url (YouTube)"
        return 1
      end

      # --- Phase 1 + 2: Get episode and source audio ---
      if @local_file
        logger.phase_start("Local File")
        episode = build_local_episode(@local_file, @file_title)
        logger.log("Local file: \"#{episode[:title]}\" (#{@local_file})")
        logger.phase_end("Local File")

        return 1 if already_processed?(episode)

        if @dry_run
          logger.log("[dry-run] Skipping transcription, assembly, and history")
          total_time = (Time.now - pipeline_start).round(2)
          summary = "[dry-run] Config validated, local file \"#{episode[:title]}\" — no API calls"
          logger.log("Total pipeline time: #{total_time}s")
          logger.log(summary)
          puts summary unless @options[:verbosity] == :quiet
          return 0
        end

        source_audio_path = File.expand_path(@local_file)
      elsif @youtube_url
        if @dry_run
          logger.log("[dry-run] YouTube URL: #{@youtube_url}")
          logger.log("[dry-run] Skipping download, transcription, assembly, and history")
          total_time = (Time.now - pipeline_start).round(2)
          summary = "[dry-run] Config validated, YouTube URL provided — no API calls"
          logger.log("Total pipeline time: #{total_time}s")
          logger.log(summary)
          puts summary unless @options[:verbosity] == :quiet
          return 0
        end

        logger.phase_start("YouTube")
        downloader = YouTubeDownloader.new(logger: logger)
        metadata = downloader.fetch_metadata(@youtube_url)
        episode = build_youtube_episode(metadata)
        logger.log("YouTube video: \"#{episode[:title]}\" (#{metadata[:duration]}s)")
        logger.phase_end("YouTube")

        return 1 if already_processed?(episode)

        logger.phase_start("Download Audio")
        source_audio_path = downloader.download_audio(@youtube_url)
        @temp_files << source_audio_path
        logger.log("Downloaded YouTube audio: #{(File.size(source_audio_path) / (1024.0 * 1024)).round(2)} MB")
        logger.phase_end("Download Audio")

        # Download thumbnail (always — used as fallback or via --image thumb)
        thumb_path = downloader.download_thumbnail(@youtube_url)
        if thumb_path
          @temp_files << thumb_path
          @youtube_thumbnail = thumb_path
        end

        # Fetch captions in target language (non-fatal)
        caption_lang = @config.transcription_language
        if caption_lang
          @youtube_captions = downloader.fetch_captions(@youtube_url, language: caption_lang)
        end
      else
        logger.phase_start("Fetch Episode")
        episode = fetch_next_episode(force: @options[:force])
        unless episode
          logger.error("No new episodes found in RSS feeds")
          return 1
        end
        episode[:title] = @file_title if @file_title
        logger.log("Selected episode: \"#{episode[:title]}\" (#{episode[:audio_url]})")
        # Stash per-feed image config for resolve_episode_cover
        @current_episode_feed_base_image = episode.delete(:base_image)
        feed_image = episode.delete(:image)
        @current_episode_image_none = (feed_image == "none")
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

        logger.phase_start("Download Audio")
        source_audio_path = download_audio(episode[:audio_url])
        logger.log("Downloaded source audio: #{(File.size(source_audio_path) / (1024.0 * 1024)).round(2)} MB")
        logger.phase_end("Download Audio")
      end

      # --- Phase 2b: Skip intro (CLI flag → per-feed config → ## Audio config) ---
      skip = @options[:skip] || episode[:skip] || @config.skip
      if skip && skip > 0
        assembler = AudioAssembler.new(logger: logger)
        total = assembler.probe_duration(source_audio_path)
        skipped_path = File.join(Dir.tmpdir, "podgen_skipped_#{Process.pid}.mp3")
        @temp_files << skipped_path
        assembler.extract_segment(source_audio_path, skipped_path, skip, total)
        logger.log("Skipped intro: #{skip}s (#{total.round(1)}s → #{(total - skip).round(1)}s)")
        source_audio_path = skipped_path
      end

      # --- Phase 2c: Cut outro (CLI flag → per-feed config → ## Audio config) ---
      cut = @options[:cut] || episode[:cut] || @config.cut
      if cut && cut > 0
        assembler ||= AudioAssembler.new(logger: logger)
        total = assembler.probe_duration(source_audio_path)
        keep = total - cut
        if keep > 0
          cut_path = File.join(Dir.tmpdir, "podgen_cut_#{Process.pid}.mp3")
          @temp_files << cut_path
          assembler.trim_to_duration(source_audio_path, cut_path, keep)
          logger.log("Cut outro: #{cut}s (#{total.round(1)}s → #{keep.round(1)}s)")
          source_audio_path = cut_path
        else
          logger.log("Warning: cut #{cut}s exceeds audio duration #{total.round(1)}s — skipping")
        end
      end

      # --- Phase 3: Transcribe full audio ---
      logger.phase_start("Transcription")
      assembler ||= AudioAssembler.new(logger: logger)
      base_name = @config.episode_basename(@today)
      result = transcribe_audio(source_audio_path, captions: @youtube_captions)
      logger.phase_end("Transcription")

      # --- Phase 3b: Clean or generate episode description ---
      clean_or_generate_description(episode, @reconciled_text || result[:text])

      # --- Phase 4: Trim outro via reconciled text + Groq word timestamps ---
      autotrim = @options[:autotrim] || episode[:autotrim] || @config.autotrim
      if autotrim && @reconciled_text && @groq_words&.any?
        logger.phase_start("Trim Outro")
        source_audio_path = trim_outro(assembler, source_audio_path, base_name)
        logger.phase_end("Trim Outro")
      elsif autotrim
        logger.log("Skipping outro trim (requires 2+ engines with groq)")
      else
        logger.log("Skipping outro trim (autotrim not enabled)")
      end

      # --- Phase 5: Build transcript ---
      transcript = @reconciled_text || result[:text]

      # --- Phase 6: Assemble (trimmed audio as single piece) ---
      logger.phase_start("Assembly")
      output_path = File.join(@config.episodes_dir, "#{base_name}.mp3")

      intro_music_path = File.join(@config.podcast_dir, "intro.mp3")
      outro_music_path = File.join(@config.podcast_dir, "outro.mp3")

      assembler.assemble([source_audio_path], output_path, intro_path: intro_music_path, outro_path: outro_music_path,
        metadata: { title: episode[:title], artist: @config.author })
      logger.phase_end("Assembly")

      # --- Save transcript ---
      save_transcript(episode, transcript, base_name)

      # --- Save episode cover ---
      @current_episode_description = episode[:description]
      cover_source = resolve_episode_cover(episode[:title])
      if cover_source
        ext = File.extname(cover_source)
        cover_dest = File.join(@config.episodes_dir, "#{base_name}_cover#{ext}")
        FileUtils.cp(cover_source, cover_dest)
        logger.log("Episode cover saved: #{cover_dest}")
      end

      # --- Phase 7: LingQ Upload (if enabled via --lingq flag) ---
      upload_to_lingq(episode, @reconciled_text || transcript, output_path, base_name) if @options[:lingq]

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

    def build_local_episode(path, title)
      expanded = File.expand_path(path)
      raise "File not found: #{expanded}" unless File.exist?(expanded)
      raise "File is empty: #{expanded}" unless File.size(expanded) > 0

      title ||= File.basename(path, File.extname(path))
        .gsub(/[_-]/, " ")
        .gsub(/\b\w/) { |m| m.upcase }

      # Use filename:size as the dedup key so moving the file doesn't break history
      file_id = "file://#{File.basename(path)}:#{File.size(expanded)}"

      {
        title: title,
        description: "",
        audio_url: file_id,
        source_path: expanded,
        pub_date: Time.now,
        link: nil
      }
    end

    def build_youtube_episode(metadata)
      title = @file_title || metadata[:title]

      {
        title: title,
        description: metadata[:description].to_s,
        audio_url: metadata[:url],
        source_path: nil,
        pub_date: Time.now,
        link: metadata[:url]
      }
    end

    def already_processed?(episode)
      return false if @options[:force] || @dry_run
      return false unless @history.recent_urls.include?(episode[:audio_url])

      logger.log("Warning: Already processed within lookback window: #{episode[:audio_url]}")
      $stderr.puts "Already processed: \"#{episode[:title]}\" — use --force to re-process"
      true
    end

    def fetch_next_episode(force: false)
      rss_feeds = @config.sources["rss"]
      unless rss_feeds.is_a?(Array) && rss_feeds.any?
        raise "Language pipeline requires RSS sources in guidelines.md (## Sources → - rss:)"
      end

      source = RSSSource.new(feeds: rss_feeds, logger: logger)
      exclude = force ? Set.new : @history.recent_urls
      episodes = source.fetch_episodes(exclude_urls: exclude)

      if episodes.empty?
        logger.log("No episodes with audio enclosures found")
        return nil
      end

      logger.log("Found #{episodes.length} episodes with audio enclosures")
      episodes.first
    end

    def transcribe_audio(audio_path, captions: nil)
      language = @config.transcription_language
      raise "Language pipeline requires ## Transcription Language in guidelines.md" unless language

      engine_codes = @config.transcription_engines
      manager = Transcription::EngineManager.new(
        engine_codes: engine_codes,
        language: language,
        target_language: @config.target_language,
        logger: logger
      )
      result = manager.transcribe(audio_path, captions: captions)

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

    def clean_or_generate_description(episode, transcript)
      agent = DescriptionAgent.new(logger: logger)

      # Clean title (all sources)
      episode[:title] = agent.clean_title(title: episode[:title])

      # Clean or generate description
      if episode[:description].to_s.strip.empty?
        episode[:description] = agent.generate(title: episode[:title], transcript: transcript)
      else
        episode[:description] = agent.clean(title: episode[:title], description: episode[:description])
      end
    rescue => e
      logger.log("Warning: Description processing failed: #{e.message} (non-fatal, keeping original)")
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

    def upload_to_lingq(episode, transcript, audio_path, base_name)
      return unless @config.lingq_enabled?

      if @dry_run
        logger.log("[dry-run] Skipping LingQ upload")
        return
      end

      logger.phase_start("LingQ Upload")
      lc = @config.lingq_config
      language = @config.transcription_language

      image_path = resolve_episode_cover(episode[:title])

      agent = LingQAgent.new(logger: logger)
      lesson_id = agent.upload(
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
        original_url: episode[:link]
      )

      # Record in tracking so publish --lingq doesn't re-upload
      record_lingq_upload(lc[:collection], base_name, lesson_id)

      logger.phase_end("LingQ Upload")
    rescue => e
      logger.log("Warning: LingQ upload failed: #{e.message} (non-fatal, continuing)")
      logger.log(e.backtrace.first(3).join("\n"))
    end

    # Records a LingQ upload in the tracking file (same format as publish command)
    # so that publish --lingq won't re-upload episodes already uploaded during generate.
    def record_lingq_upload(collection, base_name, lesson_id)
      tracking_path = File.join(File.dirname(@config.episodes_dir), "lingq_uploads.yml")
      tracking = if File.exist?(tracking_path)
                   data = YAML.load_file(tracking_path)
                   data.is_a?(Hash) ? data.transform_keys(&:to_s) : {}
                 else
                   {}
                 end

      collection_key = collection.to_s
      tracking[collection_key] ||= {}
      tracking[collection_key][base_name] = lesson_id

      dir = File.dirname(tracking_path)
      FileUtils.mkdir_p(dir)
      tmp = File.join(dir, ".lingq_uploads.yml.tmp.#{Process.pid}")
      begin
        File.write(tmp, tracking.to_yaml)
        File.rename(tmp, tracking_path)
      rescue => e
        File.delete(tmp) if File.exist?(tmp)
        raise e
      end

      logger.log("Recorded LingQ upload: #{base_name} → lesson #{lesson_id}")
    end

    # Resolves the episode cover image path using the priority chain:
    # 1. --image PATH → static file
    # 2. --image thumb → YouTube thumbnail
    # 3. Per-feed image: none → YouTube thumbnail fallback
    # 4. --base-image PATH → title overlay on file
    # 5. Per-feed base_image: PATH → title overlay on file
    # 6. ## Image base_image: PATH → title overlay on file (via cover_generation_enabled?)
    # 7. YouTube thumbnail → fallback
    # 8. nil → no cover
    def resolve_episode_cover(title)
      if @options[:image]
        if @options[:image] == "thumb"
          @youtube_thumbnail
        else
          File.expand_path(@options[:image])
        end
      elsif @current_episode_image_none
        @youtube_thumbnail
      elsif @options[:base_image]
        generate_cover_image(title, File.expand_path(@options[:base_image])) || @youtube_thumbnail
      elsif @current_episode_feed_base_image
        generate_cover_image(title, @current_episode_feed_base_image) || @youtube_thumbnail
      elsif @config.cover_generation_enabled?
        generate_cover_image(title) || @youtube_thumbnail
      else
        @youtube_thumbnail
      end
    end

    # Generates a per-episode cover image with the title overlaid on the base image.
    # Returns the generated image path, or nil on failure.
    def generate_cover_image(title, base_image = nil)
      base_image ||= @config.cover_base_image
      return nil unless base_image && File.exist?(base_image)

      cover_path = File.join(Dir.tmpdir, "podgen_cover_#{Process.pid}.jpg")
      @temp_files << cover_path

      agent = CoverAgent.new(logger: logger)
      agent.generate(
        title: title,
        base_image: base_image,
        output_path: cover_path,
        options: @config.cover_options
      )

      cover_path
    rescue => e
      logger.log("Warning: Cover generation failed: #{e.message} (falling back)")
      nil
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
