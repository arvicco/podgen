# frozen_string_literal: true

require "open3"
require "yaml"
require "fileutils"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  class PublishCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

    def initialize(args, options)
      @options = options
      @options[:lingq] = true if args.delete("--lingq")
      @options[:dry_run] = true if args.delete("--dry-run")
      @podcast_name = args.shift
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen publish <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      @config = PodcastConfig.new(@podcast_name)
      @config.load_env!

      if @options[:lingq]
        publish_to_lingq
      else
        publish_to_r2
      end
    end

    private

    def publish_to_r2
      unless rclone_available?
        $stderr.puts "rclone is not installed. Install with: brew install rclone"
        return 2
      end

      missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
      unless missing.empty?
        $stderr.puts "Missing required environment variables: #{missing.join(', ')}"
        $stderr.puts "Set them in .env or podcasts/#{@podcast_name}/.env"
        return 2
      end

      source_dir = File.dirname(@config.episodes_dir) # output/<podcast>/
      bucket = ENV["R2_BUCKET"]
      dest = "r2:#{bucket}/#{@config.name}/"

      # Only sync public-facing files (mp3, html transcripts, feed xml, cover)
      includes = [
        "episodes/*.mp3",
        "episodes/*.html",
        "feed.xml",
        "feed-*.xml"
      ]
      includes << @config.image if @config.image

      args = ["rclone", "sync", source_dir, dest]
      includes.each { |f| args.push("--include", f) }
      args.push("--dry-run") if @options[:dry_run]
      args.push("-v") if @options[:verbosity] == :verbose
      args.push("--progress") unless @options[:verbosity] == :quiet

      rclone_env = {
        "RCLONE_CONFIG_R2_TYPE" => "s3",
        "RCLONE_CONFIG_R2_PROVIDER" => "Cloudflare",
        "RCLONE_CONFIG_R2_ACCESS_KEY_ID" => ENV["R2_ACCESS_KEY_ID"],
        "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY" => ENV["R2_SECRET_ACCESS_KEY"],
        "RCLONE_CONFIG_R2_ENDPOINT" => ENV["R2_ENDPOINT"],
        "RCLONE_CONFIG_R2_ACL" => "private"
      }

      puts "Syncing #{source_dir} → #{dest}" unless @options[:verbosity] == :quiet
      puts "(dry run)" if @options[:dry_run] && @options[:verbosity] != :quiet

      success = system(rclone_env, *args)

      unless success
        $stderr.puts "rclone failed."
        return 1
      end

      unless @options[:verbosity] == :quiet
        if @config.base_url
          puts "Feed URL: #{@config.base_url}/feed.xml"
        else
          puts "Done. Set base_url in guidelines.md to see feed URL."
        end
      end

      0
    end

    def publish_to_lingq
      unless @config.lingq_enabled?
        $stderr.puts "LingQ not configured. Add ## LingQ section with collection to guidelines.md and set LINGQ_API_KEY."
        return 2
      end

      unless @config.transcription_language
        $stderr.puts "Transcription language not configured. Add language to ## Audio section in guidelines.md."
        return 2
      end

      lc = @config.lingq_config
      collection = lc[:collection]
      episodes = scan_episodes
      tracking = load_tracking
      uploaded = tracking[collection.to_s] || {}

      pending = episodes.reject { |ep| uploaded.key?(ep[:base_name]) }

      if pending.empty?
        puts "All episodes already uploaded to LingQ collection #{collection}." unless @options[:verbosity] == :quiet
        return 0
      end

      puts "#{pending.length} episode(s) to upload to LingQ collection #{collection}" unless @options[:verbosity] == :quiet

      if @options[:dry_run]
        pending.each { |ep| puts "  would upload: #{ep[:base_name]}" } unless @options[:verbosity] == :quiet
        puts "(dry run)" unless @options[:verbosity] == :quiet
        return 0
      end

      require_relative File.join(File.expand_path("../..", __dir__), "lib", "agents", "lingq_agent")
      require_relative File.join(File.expand_path("../..", __dir__), "lib", "agents", "cover_agent")

      agent = LingQAgent.new
      language = @config.transcription_language

      pending.each do |ep|
        title, description, transcript = parse_transcript(ep[:transcript_path])
        image_path = generate_cover_image(title, lc)

        puts "  uploading: #{ep[:base_name]} — \"#{title}\"" unless @options[:verbosity] == :quiet

        lesson_id = agent.upload(
          title: title,
          text: transcript,
          audio_path: ep[:mp3_path],
          language: language,
          collection: collection,
          level: lc[:level],
          tags: lc[:tags],
          image_path: image_path,
          accent: lc[:accent],
          status: lc[:status],
          description: description
        )

        uploaded[ep[:base_name]] = lesson_id
        tracking[collection.to_s] = uploaded
        save_tracking(tracking)

        puts "  ✓ #{ep[:base_name]} → lesson #{lesson_id}" unless @options[:verbosity] == :quiet
      rescue => e
        $stderr.puts "  ✗ #{ep[:base_name]} failed: #{e.message}"
        # Continue with remaining episodes
      ensure
        cleanup_cover(image_path)
      end

      0
    end

    # Scans episodes dir for mp3 files that have matching transcripts.
    # Returns array of { base_name:, mp3_path:, transcript_path: } sorted chronologically.
    def scan_episodes
      episodes_dir = @config.episodes_dir
      return [] unless Dir.exist?(episodes_dir)

      Dir.glob(File.join(episodes_dir, "*.mp3"))
        .sort
        .filter_map do |mp3_path|
          base_name = File.basename(mp3_path, ".mp3")
          transcript_path = File.join(episodes_dir, "#{base_name}_transcript.md")
          next unless File.exist?(transcript_path)

          { base_name: base_name, mp3_path: mp3_path, transcript_path: transcript_path }
        end
    end

    # Parses a transcript markdown file.
    # Returns [title, description, transcript_text]
    def parse_transcript(path)
      content = File.read(path)
      lines = content.lines

      # Title from first line: "# Title"
      title = lines.first&.strip&.sub(/^#\s+/, "") || "Untitled"

      # Find ## Transcript heading
      transcript_idx = lines.index { |l| l.strip.match?(/^## Transcript/) }

      if transcript_idx
        # Description is between title and ## Transcript (skip blank lines)
        desc_lines = lines[1...transcript_idx].map(&:strip).reject(&:empty?)
        description = desc_lines.join("\n")
        description = nil if description.empty?

        # Transcript text is everything after ## Transcript
        transcript = lines[(transcript_idx + 1)..].join.strip
      else
        description = nil
        transcript = lines[1..].join.strip
      end

      [title, description, transcript]
    end

    def generate_cover_image(title, lingq_config)
      return lingq_config[:image] unless @config.cover_generation_enabled?

      cover_path = File.join(Dir.tmpdir, "podgen_cover_publish_#{Process.pid}.jpg")

      options = {}
      options[:font] = lingq_config[:font] if lingq_config[:font]
      options[:font_color] = lingq_config[:font_color] if lingq_config[:font_color]
      options[:font_size] = lingq_config[:font_size] if lingq_config[:font_size]
      options[:text_width] = lingq_config[:text_width] if lingq_config[:text_width]
      options[:gravity] = lingq_config[:text_gravity] if lingq_config[:text_gravity]
      options[:x_offset] = lingq_config[:text_x_offset] if lingq_config[:text_x_offset]
      options[:y_offset] = lingq_config[:text_y_offset] if lingq_config[:text_y_offset]

      agent = CoverAgent.new
      agent.generate(
        title: title,
        base_image: lingq_config[:base_image],
        output_path: cover_path,
        options: options
      )

      cover_path
    rescue => e
      $stderr.puts "  Warning: cover generation failed: #{e.message} (using static image)" if @options[:verbosity] == :verbose
      lingq_config[:image]
    end

    def cleanup_cover(image_path)
      return unless image_path
      return unless image_path.start_with?(Dir.tmpdir)

      File.delete(image_path) if File.exist?(image_path)
    rescue # rubocop:disable Lint/SuppressedException
    end

    def tracking_path
      @tracking_path ||= File.join(File.dirname(@config.episodes_dir), "lingq_uploads.yml")
    end

    def load_tracking
      return {} unless File.exist?(tracking_path)

      data = YAML.load_file(tracking_path)
      return {} unless data.is_a?(Hash)

      # Normalize keys to strings
      data.transform_keys(&:to_s).transform_values { |v| v.is_a?(Hash) ? v.transform_keys(&:to_s) : v }
    end

    # Atomic write: temp + rename
    def save_tracking(tracking)
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
    end

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
