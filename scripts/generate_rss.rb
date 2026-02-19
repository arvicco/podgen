#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate podcast RSS 2.0 feed for a specific podcast.
# Usage: ruby scripts/generate_rss.rb <podcast_name>

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "rss_generator")

podcast_name = ARGV[0]

unless podcast_name
  available = PodcastConfig.available
  puts "Usage: ruby scripts/generate_rss.rb <podcast_name>"
  puts
  if available.any?
    puts "Available podcasts:"
    available.each { |name| puts "  - #{name}" }
  end
  exit 1
end

config = PodcastConfig.new(podcast_name)
config.load_env!

puts "=== RSS Feed Generator (#{podcast_name}) ==="
puts

generator = RssGenerator.new(
  episodes_dir: config.episodes_dir,
  feed_path: config.feed_path,
  title: config.title,
  author: config.author
)
feed_path = generator.generate

puts
puts "Feed: #{feed_path}"
puts
puts "To serve locally:"
puts "  cd #{File.dirname(feed_path)} && ruby -run -e httpd . -p 8080"
puts "  Feed URL: http://localhost:8080/feed.xml"
puts
puts File.read(feed_path)
