# frozen_string_literal: true

require "httparty"
require "set"

class HNSource
  MAX_RETRIES = 2
  RESULTS_PER_TOPIC = 3
  LOOKBACK_HOURS = 48
  API_BASE = "https://hn.algolia.com/api/v1/search_by_date"

  def initialize(logger: nil, **_options)
    @logger = logger
  end

  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics, exclude_urls: Set.new)
    topics.map do |topic|
      log("Searching HN: #{topic}")
      start = Time.now
      findings = search_topic(topic, exclude_urls)
      elapsed = (Time.now - start).round(2)
      log("HN found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic, exclude_urls)
    cutoff_timestamp = (Time.now - (LOOKBACK_HOURS * 3600)).to_i

    response = request_with_retry(
      query: topic,
      tags: "story",
      numericFilters: "created_at_i>#{cutoff_timestamp}",
      hitsPerPage: RESULTS_PER_TOPIC
    )

    return [] unless response && response["hits"]

    response["hits"].filter_map do |hit|
      title = hit["title"].to_s.strip
      next if title.empty?

      url = hit["url"]
      url = "https://news.ycombinator.com/item?id=#{hit['objectID']}" if url.nil? || url.empty?

      next if exclude_urls.include?(url)

      points = hit["points"] || 0
      comments = hit["num_comments"] || 0

      {
        title: title,
        url: url,
        summary: "#{points} points, #{comments} comments on Hacker News"
      }
    end
  rescue => e
    log("Failed to search HN for '#{topic}': #{e.message}")
    []
  end

  def request_with_retry(**params)
    attempts = 0
    begin
      attempts += 1
      response = HTTParty.get(API_BASE, query: params, timeout: 15)

      unless response.success?
        raise "HTTP #{response.code} from HN Algolia API"
      end

      response.parsed_response
    rescue => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("HN API error: #{e.message}, retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
        sleep(sleep_time)
        retry
      end
      raise
    end
  end

  def log(message)
    if @logger
      @logger.log("[HNSource] #{message}")
    else
      puts "[HNSource] #{message}"
    end
  end
end
