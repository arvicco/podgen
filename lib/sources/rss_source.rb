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
  # All RSS items go under a single synthetic topic.
  def research(topics, exclude_urls: Set.new)
    findings = []

    @feeds.each do |feed_url|
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

    [{ topic: "Recent headlines (RSS)", findings: findings }]
  end

  private

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

  def log(message)
    if @logger
      @logger.log("[RSSSource] #{message}")
    else
      puts "[RSSSource] #{message}"
    end
  end
end
