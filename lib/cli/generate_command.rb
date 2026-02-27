# frozen_string_literal: true

require "yaml"
require "date"
require "fileutils"
require "optparse"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "logger")
require_relative File.join(root, "lib", "agents", "topic_agent")
require_relative File.join(root, "lib", "source_manager")
require_relative File.join(root, "lib", "agents", "script_agent")
require_relative File.join(root, "lib", "agents", "tts_agent")
require_relative File.join(root, "lib", "agents", "translation_agent")
require_relative File.join(root, "lib", "audio_assembler")
require_relative File.join(root, "lib", "episode_history")
require_relative File.join(root, "lib", "cli", "language_pipeline")

module PodgenCLI
  class GenerateCommand
    def initialize(args, options)
      @options = options

      OptionParser.new do |opts|
        opts.on("--file PATH", "Local audio file (language pipeline)") { |f| @options[:file] = f }
        opts.on("--url URL", "YouTube video URL (language pipeline)") { |u| @options[:url] = u }
        opts.on("--title TEXT", "Episode title (with --file or --url)") { |t| @options[:title] = t }
        opts.on("--skip-intro N", "--skip N", Float, "Seconds to skip from start") { |n| @options[:skip] = n }
        opts.on("--cut-outro N", "--cut N", Float, "Seconds to cut from end") { |n| @options[:cut] = n }
        opts.on("--autotrim", "Enable outro auto-detection via word timestamps") { @options[:autotrim] = true }
        opts.on("--force", "Process even if already in history (skip dedup check)") { @options[:force] = true }
        opts.on("--image PATH", "Static cover image (with --file or --url)") { |p| @options[:image] = p }
        opts.on("--base-image PATH", "Base image for cover generation (with --file or --url)") { |p| @options[:base_image] = p }
        opts.on("--lingq", "Enable LingQ upload during generation") { @options[:lingq] = true }
        opts.on("--dry-run", "Validate config, skip API calls") { @options[:dry_run] = true }
      end.parse!(args)

      @dry_run = @options[:dry_run] || false

      @podcast_name = args.shift
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen generate <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        else
          $stderr.puts "No podcasts found. Create a directory under podcasts/ with guidelines.md and queue.yml."
        end
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      config.load_env!
      config.ensure_directories!

      # --- Lockfile: prevent concurrent runs of the same podcast ---
      lock_path = File.join(File.dirname(config.episodes_dir), "run.lock")
      lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
      unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        $stderr.puts "Another instance is already running for '#{@podcast_name}' (lockfile: #{lock_path})"
        lock_file.close
        return 1
      end

      today = Date.today
      logger = PodcastAgent::Logger.new(log_path: config.log_path(today), verbosity: @options[:verbosity])
      history = EpisodeHistory.new(config.history_path)

      begin
        logger.log("Podcast Agent started for '#{@podcast_name}'#{@dry_run ? ' (DRY RUN)' : ''}")
        pipeline_start = Time.now

        # --- Verify prerequisites ---
        unless File.exist?(config.guidelines_path)
          logger.error("Missing guidelines: #{config.guidelines_path}")
          return 1
        end

        # --- Check ffmpeg availability (skip in dry-run) ---
        unless @dry_run
          verify_ffmpeg!(logger)
        end

        # --- Load config ---
        guidelines = config.guidelines
        logger.log("Loaded guidelines (#{guidelines.length} chars)")

        # --- Validate --file and --url flags ---
        if @options[:file] && config.type != "language"
          $stderr.puts "Error: --file is only supported for language pipeline podcasts (type: language)"
          return 1
        end

        if @options[:url] && config.type != "language"
          $stderr.puts "Error: --url is only supported for language pipeline podcasts (type: language)"
          return 1
        end

        if @options[:file] && @options[:url]
          $stderr.puts "Error: --file and --url are mutually exclusive"
          return 1
        end

        # --- Branch on pipeline type ---
        if config.type == "language"
          logger.log("Pipeline type: language")
          pipeline = LanguagePipeline.new(config: config, options: @options, logger: logger, history: history, today: today)
          return pipeline.run
        end

        logger.log("Pipeline type: news")

        # --- Phase 0: Topic generation ---
        logger.phase_start("Topics")
        if @dry_run
          topics = config.queue_topics
          logger.log("[dry-run] Using queue.yml topics: #{topics.join(', ')}")
        else
          begin
            topic_agent = TopicAgent.new(guidelines: guidelines, recent_topics: history.recent_topics_summary, logger: logger)
            topics = topic_agent.generate
            logger.log("Generated #{topics.length} topics from guidelines")
          rescue => e
            logger.log("Topic generation failed (#{e.message}), falling back to queue.yml")
            topics = config.queue_topics
            logger.log("Loaded #{topics.length} fallback topics: #{topics.join(', ')}")
          end
        end
        logger.phase_end("Topics")

        # --- Phase 1: Research (multi-source) ---
        logger.phase_start("Research")
        if @dry_run
          research_data = topics.map do |topic|
            {
              topic: topic,
              findings: [
                { title: "Example article about #{topic}", url: "https://example.com/#{topic.downcase.gsub(/\s+/, '-')}", summary: "This is a stub finding for dry-run testing of '#{topic}'." }
              ]
            }
          end
          logger.log("[dry-run] Generated #{research_data.length} synthetic research topics")
        else
          cache_dir = File.join(File.dirname(config.episodes_dir), "research_cache")
          source_manager = SourceManager.new(
            source_config: config.sources,
            exclude_urls: history.recent_urls,
            logger: logger,
            cache_dir: cache_dir
          )
          research_data = source_manager.research(topics)
        end
        total_findings = research_data.sum { |r| r[:findings].length }
        logger.log("Research complete: #{total_findings} findings across #{research_data.length} topics")
        logger.phase_end("Research")

        # --- Phase 2: Script generation ---
        logger.phase_start("Script")
        if @dry_run
          script = {
            title: "Dry Run Episode — #{today}",
            segments: [
              { name: "Opening", text: "Welcome to this dry-run episode. Today we explore #{topics.first}." },
              { name: topics.first.to_s, text: "Here is segment one covering #{topics.first} in detail with synthetic content for testing purposes." },
              { name: topics.last.to_s, text: "Here is segment two covering #{topics.last} with more synthetic content." },
              { name: "Wrap-Up", text: "Thanks for listening to this dry-run episode. Until next time." }
            ]
          }
          logger.log("[dry-run] Synthetic script generated: \"#{script[:title]}\"")
        else
          script_agent = ScriptAgent.new(
            guidelines: guidelines,
            script_path: config.script_path(today),
            logger: logger
          )
          script = script_agent.generate(research_data)
        end
        logger.log("Script generated: \"#{script[:title]}\" (#{script[:segments].length} segments)")
        logger.phase_end("Script")

        # --- Phase 3: Per-language TTS + Assembly ---
        languages = config.languages
        logger.log("Target languages: #{languages.map { |l| l['code'] }.join(', ')}")

        if @dry_run
          languages.each do |lang|
            logger.log("[dry-run] Would synthesize + assemble for language: #{lang['code']}")
          end
          logger.log("[dry-run] Skipping history.record!")

          total_time = (Time.now - pipeline_start).round(2)
          logger.log("Total pipeline time: #{total_time}s")
          summary = "[dry-run] Config validated, #{topics.length} topics, #{total_findings} stub findings, #{script[:segments].length} segments, #{languages.length} language(s) — no API calls made"
          logger.log(summary)
          puts summary unless @options[:verbosity] == :quiet
        else
          # Compute basename ONCE before the loop — otherwise, after the English MP3
          # is written to disk, episode_basename would see it and increment the suffix,
          # causing non-English variants to get names like "name-2026-02-19a-it" instead
          # of "name-2026-02-19-it".
          base_name = config.episode_basename(today)

          intro_path = File.join(config.podcast_dir, "intro.mp3")
          outro_path = File.join(config.podcast_dir, "outro.mp3")
          output_paths = []

          languages.each do |lang|
            lang_code = lang["code"]
            voice_id = lang["voice_id"]
            lang_basename = lang_code == "en" ? base_name : "#{base_name}-#{lang_code}"

            begin
              # --- Translation (skip for English) ---
              if lang_code == "en"
                lang_script = script
              else
                logger.phase_start("Translation (#{lang_code})")
                translator = TranslationAgent.new(target_language: lang_code, logger: logger)
                lang_script = translator.translate(script)
                logger.phase_end("Translation (#{lang_code})")
              end

              # --- Save translated script for debugging ---
              lang_script_path = File.join(config.episodes_dir, "#{lang_basename}_script.md")
              save_script_debug(lang_script, lang_script_path, logger)

              # --- TTS ---
              logger.phase_start("TTS (#{lang_code})")
              tts_agent = TTSAgent.new(logger: logger, voice_id_override: voice_id, pronunciation_pls_path: config.pronunciation_pls_path)
              audio_paths = tts_agent.synthesize(lang_script[:segments])
              logger.log("TTS complete (#{lang_code}): #{audio_paths.length} audio files")
              logger.phase_end("TTS (#{lang_code})")

              # --- Assembly ---
              logger.phase_start("Assembly (#{lang_code})")
              output_path = File.join(config.episodes_dir, "#{lang_basename}.mp3")

              assembler = AudioAssembler.new(logger: logger)
              assembler.assemble(audio_paths, output_path, intro_path: intro_path, outro_path: outro_path,
                metadata: { title: lang_script[:title], artist: config.author })
              logger.phase_end("Assembly (#{lang_code})")

              # --- Cleanup TTS temp files ---
              audio_paths.each { |p| File.delete(p) if File.exist?(p) }

              output_paths << output_path
              logger.log("\u2713 Episode ready (#{lang_code}): #{output_path}")
              puts "\u2713 Episode ready (#{lang_code}): #{output_path}" unless @options[:verbosity] == :quiet

            rescue => e
              logger.error("Language #{lang_code} failed: #{e.class}: #{e.message}")
              logger.error(e.backtrace.first(5).join("\n"))
              $stderr.puts "\u2717 Language #{lang_code} failed: #{e.message}" unless @options[:verbosity] == :quiet
            end
          end

          if output_paths.empty?
            raise "All languages failed — no episodes produced"
          end

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
          logger.log("\u2713 #{output_paths.length} episode(s) produced")
        end

        0
      rescue => e
        logger.error("#{e.class}: #{e.message}")
        logger.error(e.backtrace.first(5).join("\n"))
        $stderr.puts "\n\u2717 Pipeline failed: #{e.message}" unless @options[:verbosity] == :quiet
        1
      ensure
        lock_file.flock(File::LOCK_UN)
        lock_file.close
      end
    end

    private

    def verify_ffmpeg!(logger)
      require "open3"
      _out, _err, status = Open3.capture3("ffmpeg", "-version")
      unless status.success?
        logger.error("ffmpeg is not working correctly. Install with: brew install ffmpeg")
        raise "ffmpeg is not working correctly"
      end
    rescue Errno::ENOENT
      logger.error("ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg")
      raise "ffmpeg is not installed or not on $PATH. Install with: brew install ffmpeg"
    end

    def save_script_debug(script, path, logger)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "w") do |f|
        f.puts "# #{script[:title]}"
        f.puts
        script[:segments].each do |seg|
          f.puts "## #{seg[:name]}"
          f.puts
          f.puts seg[:text]
          f.puts
        end
      end
      logger.log("Script saved to #{path}")
    end
  end
end
