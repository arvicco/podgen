# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")

module PodgenCLI
  class PublishCommand
    REQUIRED_ENV = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

    def initialize(args, options)
      @options = options
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

      unless rclone_available?
        $stderr.puts "rclone is not installed. Install with: brew install rclone"
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      config.load_env!

      missing = REQUIRED_ENV.select { |var| ENV[var].nil? || ENV[var].empty? }
      unless missing.empty?
        $stderr.puts "Missing required environment variables: #{missing.join(', ')}"
        $stderr.puts "Set them in .env or podcasts/#{@podcast_name}/.env"
        return 2
      end

      source_dir = File.dirname(config.episodes_dir) # output/<podcast>/
      bucket = ENV["R2_BUCKET"]
      dest = "r2:#{bucket}/#{config.name}/"

      # Only sync public-facing files (mp3, html transcripts, feed xml, cover)
      includes = [
        "episodes/*.mp3",
        "episodes/*.html",
        "feed.xml",
        "feed-*.xml"
      ]
      includes << config.image if config.image

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
        if config.base_url
          puts "Feed URL: #{config.base_url}/feed.xml"
        else
          puts "Done. Set base_url in guidelines.md to see feed URL."
        end
      end

      0
    end

    private

    def rclone_available?
      _out, _err, status = Open3.capture3("rclone", "--version")
      status.success?
    rescue Errno::ENOENT
      false
    end
  end
end
