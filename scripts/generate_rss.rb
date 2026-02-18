#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 7: Generate podcast RSS 2.0 feed from output/episodes/ MP3s

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "rss_generator")

puts "=== RSS Feed Generator ==="
puts

generator = RssGenerator.new
feed_path = generator.generate

puts
puts "Feed: #{feed_path}"
puts
puts "To serve locally:"
puts "  cd #{File.join(root, 'output')} && ruby -run -e httpd . -p 8080"
puts "  Feed URL: http://localhost:8080/feed.xml"
puts
puts File.read(feed_path)
