# frozen_string_literal: true

require "optparse"
require "yaml"
require "date"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  class StatsCommand
    def initialize(args, options)
      @options = options
      @all = false
      OptionParser.new do |opts|
        opts.on("--all", "Show stats for all podcasts") { @all = true }
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
        $stderr.puts "Usage: podgen stats <podcast_name>"
        $stderr.puts "       podgen stats --all"
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

      rows = podcasts.map { |name| gather_stats(name) }

      # Header
      fmt = "%-16s %-9s %8s %9s %9s %5s %5s %3s"
      puts format(fmt, "Podcast", "Type", "Episodes", "Duration", "Size", "Feed", "Cover", "URL")
      rows.each do |r|
        puts format(fmt,
          truncate(r[:name], 16),
          r[:type],
          r[:episode_count],
          r[:duration],
          r[:size],
          r[:feed_count] || "-",
          r[:has_cover] ? "yes" : "no",
          r[:has_url] ? "yes" : "no"
        )
      end
      0
    end

    def run_single(name)
      config = PodcastConfig.new(name)
      config.load_env!

      stats = gather_stats(name)
      verbose = @options[:verbosity] == :verbose

      puts "#{name} — #{config.title}"
      puts "  Type:       #{config.type}"
      puts "  Episodes:   #{stats[:episode_count]}#{stats[:date_range]}"
      puts "  Duration:   #{stats[:duration]}"
      puts "  Size:       #{stats[:size]}"
      puts "  Languages:  #{config.languages.map { |l| l['code'] }.join(', ')}"
      puts "  Sources:    #{format_sources(config.sources)}"

      if stats[:feed_count]
        feed_mtime = File.mtime(config.feed_path).strftime("%b %d") rescue nil
        feed_info = "feed.xml (#{stats[:feed_count]} episodes"
        feed_info += ", built #{feed_mtime}" if feed_mtime
        feed_info += ")"
        puts "  Feed:       #{feed_info}"
      else
        puts "  Feed:       not generated"
      end

      if stats[:cover_path]
        cover_size = format_size(File.size(stats[:cover_path]))
        puts "  Cover:      #{File.basename(stats[:cover_path])} (#{cover_size})"
      else
        puts "  Cover:      none"
      end

      if config.base_url
        puts "  Base URL:   #{config.base_url}"
      end

      if verbose
        puts
        puts "  Episodes:"
        stats[:episodes].each do |ep|
          puts "    #{ep[:filename]}  #{ep[:size_str]}  #{ep[:duration_str]}"
        end

        # Research cache
        cache_dir = File.join(File.dirname(config.episodes_dir), "research_cache")
        if Dir.exist?(cache_dir)
          cache_files = Dir.glob(File.join(cache_dir, "*"))
          cache_size = cache_files.sum { |f| File.size(f) rescue 0 }
          puts
          puts "  Research cache: #{cache_files.length} files (#{format_size(cache_size)})"
        end

        # Tails directory (language pipeline)
        tails_dir = File.join(File.dirname(config.episodes_dir), "tails")
        if Dir.exist?(tails_dir)
          tail_files = Dir.glob(File.join(tails_dir, "*.mp3"))
          tail_size = tail_files.sum { |f| File.size(f) rescue 0 }
          puts "  Tails:          #{tail_files.length} files (#{format_size(tail_size)})"
        end

        # History stats
        if File.exist?(config.history_path)
          entries = YAML.load_file(config.history_path) rescue nil
          if entries.is_a?(Array)
            topics = entries.flat_map { |e| e["topics"] || [] }.uniq
            puts
            puts "  History:    #{entries.length} entries, #{topics.length} unique topics"
          end
        end
      end

      0
    end

    def gather_stats(name)
      config = PodcastConfig.new(name)
      config.load_env!

      episodes_dir = config.episodes_dir
      mp3s = if Dir.exist?(episodes_dir)
        Dir.glob(File.join(episodes_dir, "*.mp3"))
          .reject { |f| File.basename(f).include?("_concat") }
          .sort
      else
        []
      end

      total_size = mp3s.sum { |f| File.size(f) rescue 0 }
      total_seconds = total_size / (192_000.0 / 8)

      # Date range from filenames
      dates = mp3s.filter_map { |f|
        m = File.basename(f).match(/(\d{4}-\d{2}-\d{2})/)
        Date.parse(m[1]) rescue nil if m
      }.uniq.sort

      date_range = if dates.length >= 2
        " (#{dates.first.strftime('%b %d')} – #{dates.last.strftime('%b %d, %Y')})"
      elsif dates.length == 1
        " (#{dates.first.strftime('%b %d, %Y')})"
      else
        ""
      end

      # Feed episode count
      feed_count = nil
      if File.exist?(config.feed_path)
        require "rexml/document"
        begin
          doc = REXML::Document.new(File.read(config.feed_path))
          feed_count = doc.elements.to_a("//item").length
        rescue
          feed_count = nil
        end
      end

      # Cover
      output_dir = File.dirname(config.episodes_dir)
      cover_path = nil
      if config.image
        candidate = File.join(output_dir, config.image)
        cover_path = candidate if File.exist?(candidate)
        unless cover_path
          candidate = File.join(config.podcast_dir, config.image)
          cover_path = candidate if File.exist?(candidate)
        end
      end

      # Per-episode details (for verbose)
      episode_details = mp3s.map do |path|
        size = File.size(path) rescue 0
        secs = size / (192_000.0 / 8)
        {
          filename: File.basename(path),
          size_str: format_size(size),
          duration_str: format_duration_short(secs)
        }
      end

      {
        name: name,
        type: config.type,
        episode_count: mp3s.length,
        duration: format_duration(total_seconds),
        size: format_size(total_size),
        date_range: date_range,
        feed_count: feed_count,
        has_cover: !cover_path.nil?,
        cover_path: cover_path,
        has_url: !config.base_url.nil?,
        episodes: episode_details
      }
    end

    def format_sources(sources)
      sources.map do |key, value|
        if value.is_a?(Array)
          "#{key} (#{value.length} #{value.length == 1 ? 'feed' : 'feeds'})"
        else
          key
        end
      end.join(", ")
    end

    def format_duration(seconds)
      hours = (seconds / 3600).to_i
      mins = ((seconds % 3600) / 60).to_i
      if hours > 0
        "#{hours}h #{mins}m"
      else
        "#{mins}m"
      end
    end

    def format_duration_short(seconds)
      mins = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      format("%d:%02d", mins, secs)
    end

    def format_size(bytes)
      if bytes >= 1_000_000_000
        format("%.1f GB", bytes / 1_000_000_000.0)
      elsif bytes >= 1_000_000
        format("%d MB", (bytes / 1_000_000.0).round)
      elsif bytes >= 1_000
        format("%d KB", (bytes / 1_000.0).round)
      else
        "#{bytes} B"
      end
    end

    def truncate(str, max)
      str.length > max ? str[0...max - 1] + "…" : str
    end
  end
end
