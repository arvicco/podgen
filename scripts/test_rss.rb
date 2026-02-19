#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: RSS Source — fetches crypto RSS feeds and prints parsed items

require "bundler/setup"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "sources", "rss_source")

puts "=== RSS Source Test ==="
puts

feeds = [
  "https://www.coindesk.com/arc/outboundfeeds/rss/",
  "https://cointelegraph.com/rss",
  "https://cryptoslate.com/feed/"
]

source = RSSSource.new(feeds: feeds)
results = source.research([])

results.each do |entry|
  puts "== #{entry[:topic]} =="
  entry[:findings].each_with_index do |f, i|
    puts "  [#{i + 1}] #{f[:title]}"
    puts "      #{f[:url]}"
    puts "      #{f[:summary]&.slice(0, 200)}..."
    puts
  end
end

total = results.sum { |r| r[:findings].length }
puts "=== Test complete: #{total} total findings ==="
