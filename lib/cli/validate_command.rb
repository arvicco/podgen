# frozen_string_literal: true

require "optparse"
require "yaml"
require "date"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  class ValidateCommand
    KNOWN_SOURCES = %w[exa hackernews rss claude_web bluesky x].freeze

    def initialize(args, options)
      @options = options
      @all = false
      OptionParser.new do |opts|
        opts.on("--all", "Validate all podcasts") { @all = true }
      end.parse!(args)
      @podcast_name = args.shift
    end

    def run
      if @all
        run_all
      elsif @podcast_name
        run_single(@podcast_name)
      else
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen validate <podcast_name>"
        $stderr.puts "       podgen validate --all"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end
    end

    private

    def run_all
      podcasts = PodcastConfig.available
      if podcasts.empty?
        puts "No podcasts found."
        return 0
      end

      worst = 0
      podcasts.each_with_index do |name, idx|
        puts if idx > 0
        code = run_single(name)
        worst = code if code > worst
      end
      worst
    end

    def run_single(name)
      config = PodcastConfig.new(name)
      config.load_env!

      verbose = @options[:verbosity] == :verbose
      quiet = @options[:verbosity] == :quiet

      puts "Validating #{name}..." unless quiet

      errors = []
      warnings = []
      passes = []

      # --- Guidelines ---
      check_guidelines(config, passes, warnings, errors)

      # --- Episodes ---
      check_episodes(config, passes, warnings, errors)

      # --- Transcripts ---
      check_transcripts(config, passes, warnings, errors)

      # --- Feed ---
      check_feed(config, passes, warnings, errors)

      # --- Cover ---
      check_cover(config, passes, warnings, errors)

      # --- Base URL ---
      check_base_url(config, passes, warnings, errors)

      # --- History ---
      check_history(config, passes, warnings, errors)

      # --- Pipeline-specific ---
      if config.type == "language"
        check_language_pipeline(config, passes, warnings, errors)
      else
        check_news_pipeline(config, passes, warnings, errors)
      end

      # --- Orphans ---
      check_orphans(config, passes, warnings, errors)

      # Print results
      unless quiet
        if verbose
          passes.each { |msg| puts "  ✓ #{msg}" }
        end
        warnings.each { |msg| puts "  ⚠ #{msg}" }
        errors.each { |msg| puts "  ✗ #{msg}" }
        puts
        puts "#{passes.length} passed, #{warnings.length} warning#{'s' unless warnings.length == 1}, #{errors.length} error#{'s' unless errors.length == 1}"
      end

      if !errors.empty?
        2
      elsif !warnings.empty?
        1
      else
        0
      end
    end

    # --- Check methods ---

    def check_guidelines(config, passes, warnings, errors)
      unless File.exist?(config.guidelines_path)
        errors << "Guidelines: guidelines.md not found"
        return
      end

      text = config.guidelines

      required = %w[Format Tone]
      required << "Topics" if config.type == "news"

      missing = required.select { |s| !text.match?(/^## #{Regexp.escape(s)}\b/m) }
      if missing.empty?
        passes << "Guidelines: all required sections present"
      else
        errors << "Guidelines: missing required sections: #{missing.join(', ')}"
      end

      # Check for unrecognized sources
      config.sources.each_key do |key|
        unless KNOWN_SOURCES.include?(key)
          warnings << "Guidelines: unrecognized source '#{key}'"
        end
      end

      # Check queue.yml for news podcasts
      if config.type == "news"
        if File.exist?(config.queue_path)
          begin
            data = YAML.load_file(config.queue_path)
            unless data.is_a?(Hash) && data["topics"].is_a?(Array)
              warnings << "Guidelines: queue.yml has unexpected format"
            end
          rescue => e
            warnings << "Guidelines: queue.yml parse error: #{e.message}"
          end
        end
      end
    end

    def check_episodes(config, passes, warnings, errors)
      episodes_dir = config.episodes_dir
      unless Dir.exist?(episodes_dir)
        warnings << "Episodes: directory not found (no episodes generated yet?)"
        return
      end

      mp3s = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .reject { |f| File.basename(f).include?("_concat") }

      if mp3s.empty?
        warnings << "Episodes: no MP3 files found"
        return
      end

      zero_byte = mp3s.select { |f| File.size(f) == 0 }
      unless zero_byte.empty?
        errors << "Episodes: #{zero_byte.length} zero-byte MP3 file#{'s' unless zero_byte.length == 1}"
      end

      # Check filename pattern
      name_pattern = /^#{Regexp.escape(config.name)}-\d{4}-\d{2}-\d{2}[a-z]?(-[a-z]{2})?\.mp3$/
      bad_names = mp3s.reject { |f| File.basename(f).match?(name_pattern) }
      unless bad_names.empty?
        warnings << "Episodes: #{bad_names.length} file#{'s' unless bad_names.length == 1} with unexpected naming"
      end

      total_size = mp3s.sum { |f| File.size(f) rescue 0 }
      avg_size = total_size / mp3s.length
      passes << "Episodes: #{mp3s.length} MP3 files (#{format_size(avg_size)} avg)"
    end

    def check_transcripts(config, passes, warnings, errors)
      episodes_dir = config.episodes_dir
      return unless Dir.exist?(episodes_dir)

      mp3s = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .reject { |f| File.basename(f).include?("_concat") }
      return if mp3s.empty?

      missing_md = 0
      missing_html = 0

      mp3s.each do |mp3|
        base = File.basename(mp3, ".mp3")
        has_md = File.exist?(File.join(episodes_dir, "#{base}_script.md")) ||
                 File.exist?(File.join(episodes_dir, "#{base}_transcript.md"))
        has_html = File.exist?(File.join(episodes_dir, "#{base}_script.html")) ||
                   File.exist?(File.join(episodes_dir, "#{base}_transcript.html"))
        missing_md += 1 unless has_md
        missing_html += 1 unless has_html
      end

      if missing_md == 0
        passes << "Transcripts: #{mp3s.length}/#{mp3s.length} episodes have transcripts"
      else
        warnings << "Transcripts: #{missing_md}/#{mp3s.length} episodes missing transcript/script"
      end

      if missing_html > 0
        warnings << "Transcripts: #{missing_html} episodes missing HTML version (run podgen rss)"
      end
    end

    def check_feed(config, passes, warnings, errors)
      unless File.exist?(config.feed_path)
        warnings << "Feed: feed.xml not found (run podgen rss)"
        return
      end

      require "rexml/document"
      begin
        doc = REXML::Document.new(File.read(config.feed_path))
        items = doc.elements.to_a("//item")

        # Count MP3s for comparison
        mp3_count = if Dir.exist?(config.episodes_dir)
          # Count only English/primary episodes for feed comparison
          Dir.glob(File.join(config.episodes_dir, "*.mp3"))
            .reject { |f| File.basename(f).include?("_concat") }
            .reject { |f| File.basename(f, ".mp3").match?(/-[a-z]{2}$/) }
            .length
        else
          0
        end

        if items.length == mp3_count
          passes << "Feed: well-formed XML, #{items.length} episodes"
        elsif items.length > 0
          warnings << "Feed: #{items.length} episodes in feed vs #{mp3_count} MP3s (stale feed?)"
        else
          warnings << "Feed: well-formed XML but no episodes"
        end
      rescue REXML::ParseException => e
        errors << "Feed: XML parse error: #{e.message.lines.first&.strip}"
      end

      # Check per-language feeds for multi-language podcasts
      if config.languages.length > 1
        config.languages.each do |lang|
          code = lang["code"]
          next if code == "en"
          lang_feed = config.feed_path.sub(/\.xml$/, "-#{code}.xml")
          unless File.exist?(lang_feed)
            warnings << "Feed: missing feed-#{code}.xml for language '#{code}'"
          end
        end
      end
    end

    def check_cover(config, passes, warnings, errors)
      unless config.image
        warnings << "Cover: no image configured in guidelines"
        return
      end

      output_dir = File.dirname(config.episodes_dir)
      output_cover = File.join(output_dir, config.image)
      source_cover = File.join(config.podcast_dir, config.image)

      if File.exist?(output_cover)
        size = File.size(output_cover)
        if size < 10_000
          warnings << "Cover: #{config.image} is very small (#{format_size(size)})"
        elsif size > 5_000_000
          warnings << "Cover: #{config.image} is very large (#{format_size(size)})"
        else
          passes << "Cover: #{config.image} (#{format_size(size)})"
        end
      elsif File.exist?(source_cover)
        warnings << "Cover: #{config.image} only in podcasts/ dir (run podgen rss to copy)"
      else
        errors << "Cover: #{config.image} not found"
      end
    end

    def check_base_url(config, passes, warnings, errors)
      unless config.base_url
        warnings << "Base URL: not configured"
        return
      end

      if config.base_url.match?(%r{^https?://})
        passes << "Base URL: #{config.base_url}"
      else
        errors << "Base URL: '#{config.base_url}' does not start with http:// or https://"
      end
    end

    def check_history(config, passes, warnings, errors)
      unless File.exist?(config.history_path)
        warnings << "History: history.yml not found"
        return
      end

      begin
        entries = YAML.load_file(config.history_path)
        unless entries.is_a?(Array)
          errors << "History: unexpected format (expected array)"
          return
        end

        # Validate entry structure
        bad_entries = entries.reject { |e|
          e.is_a?(Hash) && e["date"] && e["title"] && e["topics"]
        }
        unless bad_entries.empty?
          warnings << "History: #{bad_entries.length} entries missing date/title/topics"
        end

        # Compare with episode count (rough — only English/primary MP3s)
        if Dir.exist?(config.episodes_dir)
          mp3_count = Dir.glob(File.join(config.episodes_dir, "*.mp3"))
            .reject { |f| File.basename(f).include?("_concat") }
            .reject { |f| File.basename(f, ".mp3").match?(/-[a-z]{2}$/) }
            .length

          if entries.length == mp3_count
            passes << "History: #{entries.length} entries"
          else
            warnings << "History: entry count (#{entries.length}) differs from episode count (#{mp3_count})"
          end
        else
          passes << "History: #{entries.length} entries"
        end
      rescue => e
        errors << "History: parse error: #{e.message}"
      end
    end

    def check_language_pipeline(config, passes, warnings, errors)
      engines = config.transcription_engines
      if engines.empty?
        warnings << "Language: no transcription engines configured"
      else
        passes << "Language: engines #{engines.join(', ')}"
      end

      if engines.length >= 2 && engines.include?("groq")
        tails_dir = File.join(File.dirname(config.episodes_dir), "tails")
        unless Dir.exist?(tails_dir)
          warnings << "Language: tails/ directory missing (expected for multi-engine+groq)"
        end
      end

      # LingQ image check
      if config.lingq_config
        lc = config.lingq_config
        if lc[:image] && !File.exist?(lc[:image])
          warnings << "LingQ: image file not found: #{lc[:image]}"
        end
        if lc[:base_image] && !File.exist?(lc[:base_image])
          warnings << "LingQ: base_image file not found: #{lc[:base_image]}"
        end
      end
    end

    def check_news_pipeline(config, passes, warnings, errors)
      if File.exist?(config.queue_path)
        passes << "News: queue.yml present"
      else
        warnings << "News: queue.yml not found (no fallback topics)"
      end
    end

    def check_orphans(config, passes, warnings, errors)
      episodes_dir = config.episodes_dir
      return unless Dir.exist?(episodes_dir)

      mp3_bases = Dir.glob(File.join(episodes_dir, "*.mp3"))
        .reject { |f| File.basename(f).include?("_concat") }
        .map { |f| File.basename(f, ".mp3") }
        .to_set

      # Transcripts/scripts without matching MP3
      orphan_texts = Dir.glob(File.join(episodes_dir, "*_{transcript,script}.{md,html}"))
        .select { |f|
          base = File.basename(f).sub(/_(transcript|script)\.(md|html)$/, "")
          !mp3_bases.include?(base)
        }

      unless orphan_texts.empty?
        warnings << "Orphans: #{orphan_texts.length} transcript/script file#{'s' unless orphan_texts.length == 1} without matching MP3"
      end

      # Stale concat files
      concat_files = Dir.glob(File.join(episodes_dir, "*_concat*"))
      unless concat_files.empty?
        warnings << "Orphans: #{concat_files.length} stale _concat file#{'s' unless concat_files.length == 1}"
      end
    end

    def format_size(bytes)
      if bytes >= 1_000_000_000
        format("%.1f GB", bytes / 1_000_000_000.0)
      elsif bytes >= 1_000_000
        format("%.1f MB", bytes / 1_000_000.0)
      elsif bytes >= 1_000
        format("%d KB", (bytes / 1_000.0).round)
      else
        "#{bytes} B"
      end
    end
  end
end
