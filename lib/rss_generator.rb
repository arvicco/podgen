# frozen_string_literal: true

require "rexml/document"
require "date"
require "fileutils"
require "yaml"

class RssGenerator
  def initialize(episodes_dir:, feed_path:, title: "Podcast", description: nil, author: "Podcast Agent", language: "en", base_url: nil, image: nil, history_path: nil, logger: nil)
    @logger = logger
    @episodes_dir = episodes_dir
    @feed_path = feed_path
    @title = title
    @description = description
    @author = author
    @language = language
    @base_url = base_url&.chomp("/")
    @image = image
    @title_map = build_title_map(history_path)
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
      .select { |f| matches_language?(File.basename(f, ".mp3")) }
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

  # English episodes have no language suffix; non-English end with -xx (e.g. -es, -fr)
  def matches_language?(basename)
    if @language == "en"
      !basename.match?(/-[a-z]{2}$/)
    else
      basename.end_with?("-#{@language}")
    end
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
    add_text(channel, "description", @description || "Podcast by #{@author}")
    add_text(channel, "link", @base_url) if @base_url
    add_text(channel, "language", @language)
    add_text(channel, "generator", "Podcast Agent (podgen)")
    add_text(channel, "itunes:author", @author)
    if @image && @base_url
      image_url = "#{@base_url}/#{@image}"
      itunes_image = channel.add_element("itunes:image")
      itunes_image.add_attribute("href", image_url)
      rss_image = channel.add_element("image")
      add_text(rss_image, "url", image_url)
      add_text(rss_image, "title", @title)
      add_text(rss_image, "link", @base_url)
    end
    add_text(channel, "itunes:explicit", "false")
    add_text(channel, "lastBuildDate", Time.now.strftime("%a, %d %b %Y %H:%M:%S %z"))

    episodes.each do |ep|
      item = channel.add_element("item")
      ep_title = @title_map[ep[:filename]]
      title = ep_title || "#{@title} — #{ep[:date].strftime('%B %d, %Y')}"
      add_text(item, "title", title)
      add_text(item, "pubDate", ep[:date].to_time.strftime("%a, %d %b %Y 06:00:00 %z"))
      add_text(item, "itunes:author", @author)
      add_text(item, "itunes:duration", estimate_duration(ep[:size]))

      ep_url = @base_url ? "#{@base_url}/episodes/#{ep[:filename]}" : ep[:filename]
      enclosure = item.add_element("enclosure", {
        "url" => ep_url,
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

  # Build a map from MP3 filename → episode title using history.yml.
  # History entries are chronological; same-day episodes get suffixes: "", "a", "b", etc.
  SUFFIXES = [""] + ("a".."z").to_a

  def build_title_map(history_path)
    return {} unless history_path && File.exist?(history_path)

    entries = YAML.load_file(history_path) rescue nil
    return {} unless entries.is_a?(Array)

    # Determine the podcast name prefix from the episodes directory
    podcast_name = File.basename(File.dirname(@episodes_dir))

    # Group entries by date, preserving order within each date
    by_date = {}
    entries.each do |entry|
      date = entry["date"]
      next unless date
      (by_date[date] ||= []) << entry
    end

    map = {}
    by_date.each do |date, date_entries|
      date_entries.each_with_index do |entry, idx|
        suffix = SUFFIXES[idx] || idx.to_s
        filename = "#{podcast_name}-#{date}#{suffix}.mp3"
        map[filename] = entry["title"] if entry["title"]
      end
    end
    map
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
