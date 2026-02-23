# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require "optparse"
require "fileutils"
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "rss_generator")

module PodgenCLI
  class RssCommand
    def initialize(args, options)
      @options = options
      OptionParser.new do |opts|
        opts.on("--base-url URL", "Base URL for enclosures (e.g. https://host.ts.net/podcast)") do |u|
          @options[:base_url] = u
        end
      end.parse!(args)
      @podcast_name = args.shift
    end

    def run
      unless @podcast_name
        available = PodcastConfig.available
        $stderr.puts "Usage: podgen rss <podcast_name>"
        $stderr.puts
        if available.any?
          $stderr.puts "Available podcasts:"
          available.each { |name| $stderr.puts "  - #{name}" }
        end
        return 2
      end

      config = PodcastConfig.new(@podcast_name)
      config.load_env!

      base_url = @options[:base_url] || config.base_url

      # Copy cover image from podcast config dir to output dir
      if config.image
        src = File.join(config.podcast_dir, config.image)
        if File.exist?(src)
          dest = File.join(File.dirname(config.feed_path), config.image)
          FileUtils.cp(src, dest)
        else
          $stderr.puts "Warning: image '#{config.image}' not found in #{config.podcast_dir}"
        end
      end

      # Convert markdown transcripts to HTML for podcast apps
      convert_transcripts(config.episodes_dir)

      feed_paths = []

      config.languages.each do |lang|
        lang_code = lang["code"]

        feed_path = if lang_code == "en"
          config.feed_path
        else
          config.feed_path.sub(/\.xml$/, "-#{lang_code}.xml")
        end

        generator = RssGenerator.new(
          episodes_dir: config.episodes_dir,
          feed_path: feed_path,
          title: config.title,
          description: config.description,
          author: config.author,
          language: lang_code,
          base_url: base_url,
          image: config.image,
          history_path: config.history_path
        )
        generator.generate
        feed_paths << feed_path
      end

      unless @options[:verbosity] == :quiet
        feed_paths.each { |fp| puts "Feed: #{fp}" }
        if base_url
          puts "Feed URL: #{base_url}/feed.xml"
        else
          puts
          puts "To serve locally:"
          puts "  cd #{File.dirname(config.feed_path)} && ruby -run -e httpd . -p 8080"
          puts "  Feed URL: http://localhost:8080/feed.xml"
        end
      end

      0
    end

    private

    def convert_transcripts(episodes_dir)
      Dir.glob(File.join(episodes_dir, "*_transcript.md")).each do |md_path|
        html_path = md_path.sub(/\.md$/, ".html")
        next if File.exist?(html_path) && File.mtime(html_path) >= File.mtime(md_path)

        text = File.read(md_path)
        # Skip YAML front matter or header lines, start from ## Transcript or body
        body = if text.include?("## Transcript")
          text.split("## Transcript", 2).last
        else
          text.sub(/\A#[^\n]*\n+([^\n]*\n+)?/, "") # skip title + description line
        end

        paragraphs = body.strip.split(/\n{2,}/).map { |p| "<p>#{p.strip}</p>" }
        html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head>\n<body>\n#{paragraphs.join("\n")}\n</body></html>\n"
        File.write(html_path, html)
      end
    end
  end
end
