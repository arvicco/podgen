# frozen_string_literal: true

require "httparty"
require "set"

class XSource
  MAX_RETRIES = 2
  RESULTS_PER_TOPIC = 5
  API_BASE = "https://api.socialdata.tools/twitter/search"

  def initialize(logger: nil, priority_handles: [], **_options)
    @logger = logger
    @api_key = ENV["SOCIALDATA_API_KEY"]
    @priority_handles = priority_handles.map { |h| h.delete_prefix("@") }
  end

  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics, exclude_urls: Set.new)
    unless @api_key
      log("SOCIALDATA_API_KEY not set, skipping X source")
      return topics.map { |t| { topic: t, findings: [] } }
    end

    topics.map do |topic|
      log("Searching X: #{topic}")
      start = Time.now
      findings = search_topic(topic, exclude_urls)
      elapsed = (Time.now - start).round(2)
      log("X found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic, exclude_urls)
    seen_urls = exclude_urls.dup
    findings = []

    # Phase 1: Priority accounts — search their tweets first
    if @priority_handles.any?
      from_clause = @priority_handles.map { |h| "from:#{h}" }.join(" OR ")
      priority_query = "(#{from_clause}) #{topic} -is:retweet"

      priority_tweets = fetch_tweets(priority_query)
      priority_findings = parse_tweets(priority_tweets, seen_urls)
      findings.concat(priority_findings)

      log("Priority accounts returned #{priority_findings.length} results for '#{topic}'") if priority_findings.any?
    end

    # Phase 2: General search — fill remaining slots
    remaining = RESULTS_PER_TOPIC - findings.length
    if remaining > 0
      general_query = "#{topic} lang:en -is:retweet"
      general_tweets = fetch_tweets(general_query)
      general_findings = parse_tweets(general_tweets, seen_urls)
      findings.concat(general_findings.first(remaining))
    end

    findings
  rescue => e
    log("Failed to search X for '#{topic}': #{e.message}")
    []
  end

  def fetch_tweets(query)
    response = request_with_retry(query: query, type: "Latest")
    tweets = response["tweets"]
    tweets.is_a?(Array) ? tweets : []
  end

  def parse_tweets(tweets, seen_urls)
    tweets.filter_map do |tweet|
      text = tweet["full_text"].to_s.strip
      text = tweet["text"].to_s.strip if text.empty?
      next if text.empty?

      user = tweet["user"] || {}
      screen_name = user["screen_name"] || "unknown"
      tweet_id = tweet["id_str"] || tweet["id"].to_s

      tweet_url = "https://x.com/#{screen_name}/status/#{tweet_id}"
      next if seen_urls.include?(tweet_url)

      seen_urls.add(tweet_url)

      # Use first line or first 120 chars as title
      title = text.lines.first.to_s.strip
      title = "#{title[0, 117]}..." if title.length > 120

      # Full text as summary, capped at 500 chars
      summary = text.length > 500 ? "#{text[0, 497]}..." : text

      favorites = tweet["favorite_count"] || 0
      retweets = tweet["retweet_count"] || 0
      summary = "#{summary} [#{favorites} likes, #{retweets} retweets on X]"

      {
        title: "@#{screen_name}: #{title}",
        url: tweet_url,
        summary: summary
      }
    end
  end

  def request_with_retry(**params)
    attempts = 0
    begin
      attempts += 1
      response = HTTParty.get(
        API_BASE,
        query: params,
        headers: {
          "Authorization" => "Bearer #{@api_key}",
          "Accept" => "application/json"
        },
        timeout: 15
      )

      unless response.success?
        raise "HTTP #{response.code} from SocialData API"
      end

      response.parsed_response
    rescue => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("SocialData API error: #{e.message}, retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
        sleep(sleep_time)
        retry
      end
      raise
    end
  end

  def log(message)
    if @logger
      @logger.log("[XSource] #{message}")
    else
      puts "[XSource] #{message}"
    end
  end
end
