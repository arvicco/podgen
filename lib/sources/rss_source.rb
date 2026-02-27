# frozen_string_literal: true

require "net/http"
require "rss"
require "uri"
require "set"
require "time"

class RSSSource
  MAX_RETRIES = 2
  MAX_REDIRECTS = 3
  LOOKBACK_HOURS = 48

  def initialize(feeds: [], logger: nil, **_options)
    @feeds = feeds
    @logger = logger
  end

  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  # RSS items are matched to user topics by keyword overlap;
  # unmatched items go under a fallback topic.
  def research(topics, exclude_urls: Set.new)
    findings = []

    @feeds.each do |feed_entry|
      feed_url = feed_entry.is_a?(Hash) ? feed_entry[:url] : feed_entry
      items = fetch_feed(feed_url)
      items.each do |item|
        next if exclude_urls.include?(item[:url])
        findings << item
      end
    end

    # Deduplicate by URL within RSS results
    seen = Set.new
    findings.select! do |f|
      next false if seen.include?(f[:url])
      seen.add(f[:url])
      true
    end

    log("RSS total: #{findings.length} items from #{@feeds.length} feed(s)")

    return [] if findings.empty?

    distribute_by_topic(topics, findings)
  end

  # Fetches episode metadata with audio enclosures from configured feeds.
  # Returns: [{ title:, description:, audio_url:, pub_date:, link: }]
  # Sorted newest-first. Excludes URLs in exclude_urls set.
  def fetch_episodes(exclude_urls: Set.new)
    episodes = []

    @feeds.each do |feed_entry|
      # Support both plain URL strings and hashes with options
      feed_url, feed_opts = if feed_entry.is_a?(Hash)
        [feed_entry[:url], feed_entry]
      else
        [feed_entry, {}]
      end

      items = fetch_feed_episodes(feed_url)
      items.each do |item|
        next if exclude_urls.include?(item[:audio_url])
        item[:skip] = feed_opts[:skip] if feed_opts[:skip]
        item[:cut] = feed_opts[:cut] if feed_opts[:cut]
        item[:autotrim] = feed_opts[:autotrim] if feed_opts[:autotrim]
        item[:base_image] = feed_opts[:base_image] if feed_opts[:base_image]
        item[:image] = feed_opts[:image] if feed_opts[:image]
        episodes << item
      end
    end

    # Deduplicate by audio URL
    seen = Set.new
    episodes.select! do |ep|
      next false if seen.include?(ep[:audio_url])
      seen.add(ep[:audio_url])
      true
    end

    # Sort newest-first
    episodes.sort_by { |ep| ep[:pub_date] || Time.at(0) }.reverse
  end

  private

  # Distribute RSS items across user topics by keyword matching.
  # Items that don't match any topic go under a fallback bucket.
  def distribute_by_topic(topics, findings)
    keyword_map = topics.map { |t| [t, topic_keywords(t)] }
    buckets = {}

    findings.each do |item|
      text = "#{item[:title]} #{item[:summary]}".downcase
      matched_topic = keyword_map.find { |_topic, keywords|
        keywords.any? { |kw| text.include?(kw) }
      }&.first

      bucket_name = matched_topic || "Other recent headlines (RSS)"
      buckets[bucket_name] ||= []
      buckets[bucket_name] << item
    end

    buckets.map { |topic, items| { topic: topic, findings: items } }
  end

  # Tokenize a topic string into significant lowercase keywords (3+ chars).
  def topic_keywords(topic)
    topic.downcase.scan(/[a-z0-9]+/).select { |w| w.length >= 3 }
  end

  def fetch_feed(feed_url)
    log("Fetching RSS: #{feed_url}")
    attempts = 0
    begin
      attempts += 1
      body = http_get_with_redirects(feed_url)
      parse_feed(body)
    rescue => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("Error fetching #{feed_url}: #{e.message}, retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
        sleep(sleep_time)
        retry
      end
      log("Failed to fetch #{feed_url} after #{MAX_RETRIES} retries: #{e.message}")
      []
    end
  end

  def http_get_with_redirects(url, redirects_left = MAX_REDIRECTS)
    uri = URI.parse(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 15) do |http|
      http.get(uri.request_uri, { "User-Agent" => "PodcastAgent/1.0" })
    end

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      raise "Too many redirects for #{url}" if redirects_left <= 0
      location = response["location"]
      # Handle relative redirects
      location = URI.join(url, location).to_s unless location.start_with?("http")
      log("Following redirect → #{location}")
      http_get_with_redirects(location, redirects_left - 1)
    else
      raise "HTTP #{response.code} from #{url}"
    end
  end

  def parse_feed(xml)
    cutoff = Time.now - (LOOKBACK_HOURS * 3600)
    feed = RSS::Parser.parse(xml, false)
    return [] unless feed

    feed.items.filter_map do |item|
      pub_date = item.respond_to?(:pubDate) ? item.pubDate : nil
      pub_date ||= item.respond_to?(:dc_date) ? item.dc_date : nil

      # Skip items older than lookback window (allow items without dates)
      if pub_date
        pub_time = pub_date.is_a?(Time) ? pub_date : Time.parse(pub_date.to_s)
        next if pub_time < cutoff
      end

      title = item.title.to_s.strip
      link = item.link.to_s.strip
      next if title.empty? || link.empty?

      summary = strip_html(item.description.to_s).strip
      summary = summary[0, 500] if summary.length > 500

      { title: title, url: link, summary: summary }
    end
  rescue RSS::Error, RSS::NotWellFormedError => e
    log("RSS parse error: #{e.message}")
    []
  end

  def strip_html(html)
    html.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
  end

  def fetch_feed_episodes(feed_url)
    log("Fetching RSS episodes: #{feed_url}")
    attempts = 0
    begin
      attempts += 1
      body = http_get_with_redirects(feed_url)
      parse_feed_episodes(body)
    rescue => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("Error fetching #{feed_url}: #{e.message}, retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
        sleep(sleep_time)
        retry
      end
      log("Failed to fetch #{feed_url} after #{MAX_RETRIES} retries: #{e.message}")
      []
    end
  end

  def parse_feed_episodes(xml)
    feed = RSS::Parser.parse(xml, false)
    return [] unless feed

    feed.items.filter_map do |item|
      # Only include items with audio enclosures
      enclosure = item.respond_to?(:enclosure) ? item.enclosure : nil
      next unless enclosure
      next unless enclosure.respond_to?(:url) && enclosure.url
      next unless enclosure.respond_to?(:type) && enclosure.type.to_s.start_with?("audio")

      pub_date = item.respond_to?(:pubDate) ? item.pubDate : nil
      pub_date ||= item.respond_to?(:dc_date) ? item.dc_date : nil
      pub_time = if pub_date
        pub_date.is_a?(Time) ? pub_date : Time.parse(pub_date.to_s)
      end

      title = item.title.to_s.strip
      next if title.empty?

      description = strip_html(item.description.to_s).strip
      link = item.link.to_s.strip

      {
        title: title,
        description: description,
        audio_url: enclosure.url.to_s.strip,
        pub_date: pub_time,
        link: link
      }
    end
  rescue RSS::Error, RSS::NotWellFormedError => e
    log("RSS parse error: #{e.message}")
    []
  end

  def log(message)
    if @logger
      @logger.log("[RSSSource] #{message}")
    else
      puts "[RSSSource] #{message}"
    end
  end
end
