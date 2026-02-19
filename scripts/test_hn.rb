#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Hacker News Source — searches HN Algolia API for test topics

require "bundler/setup"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "sources", "hn_source")

puts "=== Hacker News Source Test ==="
puts

source = HNSource.new
topics = ["Bitcoin", "AI agents"]
results = source.research(topics)

results.each do |entry|
  puts "== #{entry[:topic]} =="
  if entry[:findings].empty?
    puts "  (no results)"
  else
    entry[:findings].each_with_index do |f, i|
      puts "  [#{i + 1}] #{f[:title]}"
      puts "      #{f[:url]}"
      puts "      #{f[:summary]}"
      puts
    end
  end
  puts
end

total = results.sum { |r| r[:findings].length }
puts "=== Test complete: #{total} total findings ==="
