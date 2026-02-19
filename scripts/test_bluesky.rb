#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Bluesky Source — searches Bluesky via authenticated AT Protocol API
# Requires BLUESKY_HANDLE and BLUESKY_APP_PASSWORD in .env

require "bundler/setup"
require "dotenv"

root = File.expand_path("..", __dir__)
Dotenv.load(File.join(root, ".env"))

require_relative File.join(root, "lib", "sources", "bluesky_source")

puts "=== Bluesky Source Test ==="
puts

unless ENV["BLUESKY_HANDLE"] && ENV["BLUESKY_APP_PASSWORD"]
  puts "BLUESKY_HANDLE and BLUESKY_APP_PASSWORD not set in .env — skipping"
  puts "Create an app password at: https://bsky.app/settings/app-passwords"
  exit 0
end

source = BlueskySource.new
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
