# frozen_string_literal: true

root = File.expand_path("../..", __dir__)

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "rss_generator")

module PodgenCLI
  class RssCommand
    def initialize(args, options)
      @podcast_name = args.shift
      @options = options
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

      generator = RssGenerator.new(
        episodes_dir: config.episodes_dir,
        feed_path: config.feed_path,
        title: config.title,
        author: config.author
      )
      feed_path = generator.generate

      unless @options[:verbosity] == :quiet
        puts "Feed: #{feed_path}"
        puts
        puts "To serve locally:"
        puts "  cd #{File.dirname(feed_path)} && ruby -run -e httpd . -p 8080"
        puts "  Feed URL: http://localhost:8080/feed.xml"
      end

      0
    end
  end
end
