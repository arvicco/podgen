#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: SourceManager without Exa — verifies the pipeline works when
# a podcast excludes exa from its ## Sources config.
# Uses only hackernews + rss (no API keys needed besides what's in .env).

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "source_manager")

puts "=== SourceManager Test (no Exa) ==="
puts

# Simulate a podcast config with exa excluded
source_config = {
  "hackernews" => true,
  "rss" => [
    "https://www.coindesk.com/arc/outboundfeeds/rss/",
    "https://cointelegraph.com/rss"
  ]
}

topics = ["Bitcoin ETF", "AI agents"]

puts "Source config: #{source_config.inspect}"
puts "Topics: #{topics.inspect}"
puts

manager = SourceManager.new(source_config: source_config)
research_data = manager.research(topics)

puts
puts "--- Merged Results ---"
research_data.each do |entry|
  puts
  puts "== #{entry[:topic]} (#{entry[:findings].length} findings) =="
  entry[:findings].first(3).each_with_index do |f, i|
    puts "  [#{i + 1}] #{f[:title]}"
    puts "      #{f[:url]}"
    puts "      #{f[:summary]&.slice(0, 150)}"
  end
  remaining = entry[:findings].length - 3
  puts "  ... and #{remaining} more" if remaining > 0
end

total = research_data.sum { |r| r[:findings].length }
puts
puts "=== Test complete: #{total} total findings across #{research_data.length} topics ==="
