# frozen_string_literal: true

require "rexml/document"
require "date"
require "fileutils"

class RssGenerator
  def initialize(episodes_dir:, feed_path:, podcast_name: nil, logger: nil)
    @logger = logger
    @episodes_dir = episodes_dir
    @feed_path = feed_path
    @title = ENV.fetch("PODCAST_TITLE") { podcast_name || "Podcast" }
    @author = ENV.fetch("PODCAST_AUTHOR", "Podcast Agent")
  end

  def generate
    episodes = scan_episodes
    log("Found #{episodes.length} episodes")

    doc = build_feed(episodes)

    FileUtils.mkdir_p(File.dirname(@feed_path))
    File.open(@feed_path, "w") do |f|
      formatter = REXML::Formatters::Pretty.new(2)
      formatter.compact = true
      f.puts '<?xml version="1.0" encoding="UTF-8"?>'
      formatter.write(doc.root, f)
      f.puts
    end

    log("Feed written to #{@feed_path}")
    @feed_path
  end

  private

  def scan_episodes
    pattern = File.join(@episodes_dir, "*.mp3")
    Dir.glob(pattern)
      .reject { |f| f.include?("_concat") }
      .sort
      .reverse
      .map do |path|
        filename = File.basename(path, ".mp3")
        # Extract date from patterns like "name-2026-02-18" or "name-2026-02-18a"
        date_match = filename.match(/(\d{4}-\d{2}-\d{2})/)
        next unless date_match
        date = Date.parse(date_match[1]) rescue nil
        next unless date

        {
          path: path,
          filename: File.basename(path),
          date: date,
          size: File.size(path)
        }
      end
      .compact
  end

  def build_feed(episodes)
    doc = REXML::Document.new
    rss = doc.add_element("rss", {
      "version" => "2.0",
      "xmlns:itunes" => "http://www.itunes.com/dtds/podcast-1.0.dtd",
      "xmlns:content" => "http://purl.org/rss/1.0/modules/content/"
    })

    channel = rss.add_element("channel")
    add_text(channel, "title", @title)
    add_text(channel, "description", "Auto-generated podcast by Podcast Agent")
    add_text(channel, "language", "en")
    add_text(channel, "generator", "Podcast Agent (podgen)")
    add_text(channel, "itunes:author", @author)
    add_text(channel, "itunes:explicit", "false")
    add_text(channel, "lastBuildDate", Time.now.strftime("%a, %d %b %Y %H:%M:%S %z"))

    episodes.each do |ep|
      item = channel.add_element("item")
      title = "#{@title} — #{ep[:date].strftime('%B %d, %Y')}"
      add_text(item, "title", title)
      add_text(item, "pubDate", ep[:date].to_time.strftime("%a, %d %b %Y 06:00:00 %z"))
      add_text(item, "itunes:author", @author)
      add_text(item, "itunes:duration", estimate_duration(ep[:size]))

      enclosure = item.add_element("enclosure", {
        "url" => ep[:filename],
        "length" => ep[:size].to_s,
        "type" => "audio/mpeg"
      })

      add_text(item, "guid", ep[:filename])
    end

    doc
  end

  def add_text(parent, name, text)
    el = parent.add_element(name)
    el.text = text
    el
  end

  # Rough estimate: 192kbps MP3 → bytes / (192000/8) = seconds
  def estimate_duration(size_bytes)
    seconds = size_bytes / (192_000.0 / 8)
    minutes = (seconds / 60).to_i
    secs = (seconds % 60).to_i
    format("%d:%02d", minutes, secs)
  end

  def log(message)
    if @logger
      @logger.log("[RssGenerator] #{message}")
    else
      puts "[RssGenerator] #{message}"
    end
  end
end
