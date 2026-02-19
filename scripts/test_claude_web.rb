#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Claude Web Search Source — uses Anthropic API with web_search tool

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "sources", "claude_web_source")

puts "=== Claude Web Search Source Test ==="
puts

source = ClaudeWebSource.new
topics = ["Bitcoin ETF latest news"]
results = source.research(topics)

results.each do |entry|
  puts "== #{entry[:topic]} =="
  if entry[:findings].empty?
    puts "  (no results)"
  else
    entry[:findings].each_with_index do |f, i|
      puts "  [#{i + 1}] #{f[:title]}"
      puts "      #{f[:url]}"
      puts "      #{f[:summary]&.slice(0, 200)}..."
      puts
    end
  end
  puts
end

total = results.sum { |r| r[:findings].length }
puts "=== Test complete: #{total} total findings ==="
