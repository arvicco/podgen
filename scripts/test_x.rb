#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: X (Twitter) Source — searches via SocialData API for test topics
# Requires SOCIALDATA_API_KEY in .env

require "bundler/setup"
require "dotenv"

root = File.expand_path("..", __dir__)
Dotenv.load(File.join(root, ".env"))

require_relative File.join(root, "lib", "sources", "x_source")

puts "=== X (Twitter) Source Test ==="
puts

unless ENV["SOCIALDATA_API_KEY"]
  puts "SOCIALDATA_API_KEY not set in .env — skipping"
  exit 0
end

source = XSource.new
topics = ["Ruby programming", "Bitcoin"]
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
