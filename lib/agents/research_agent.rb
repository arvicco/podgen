# frozen_string_literal: true

require "exa-ai"
require "set"

class ResearchAgent
  MAX_RETRIES = 3
  RESULTS_PER_TOPIC = 5

  def initialize(results_per_topic: RESULTS_PER_TOPIC, exclude_urls: Set.new, logger: nil)
    @results_per_topic = results_per_topic
    @exclude_urls = exclude_urls
    @logger = logger

    Exa.configure do |config|
      config.api_key = ENV.fetch("EXA_API_KEY") {
        raise "EXA_API_KEY environment variable is not set"
      }
    end
    @client = Exa::Client.new(timeout: 30)
  end

  # Input: array of topic strings
  # Output: array of { topic:, findings: [{ title:, url:, summary: }] }
  def research(topics)
    topics.map do |topic|
      log("Researching: #{topic}")
      start = Time.now
      findings = search_topic(topic)
      elapsed = (Time.now - start).round(2)
      log("Found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic)
    results = search_with_retry(
      topic,
      num_results: @results_per_topic,
      type: "auto",
      category: "news",
      summary: { query: "Summarize this article's key points for a podcast segment" },
      start_published_date: (Date.today - 7).iso8601
    )

    all = results.results.map do |r|
      {
        title: r["title"],
        url: r["url"],
        summary: r["summary"]
      }
    end

    if @exclude_urls.any?
      before = all.length
      all.reject! { |r| @exclude_urls.include?(r[:url]) }
      filtered = before - all.length
      log("Filtered #{filtered} previously-used URL(s) for '#{topic}'") if filtered > 0
    end

    all
  rescue Exa::Error => e
    log("Failed to research '#{topic}' after #{MAX_RETRIES} attempts: #{e.message}")
    []
  end

  def search_with_retry(query, **params)
    attempts = 0
    begin
      attempts += 1
      @client.search(query, **params)
    rescue Exa::TooManyRequests, Exa::ServerError => e
      raise if attempts >= MAX_RETRIES
      sleep_time = 2**attempts
      log("#{e.class} on '#{query}', retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
      sleep(sleep_time)
      retry
    end
  end

  def log(message)
    if @logger
      @logger.log("[ResearchAgent] #{message}")
    else
      puts "[ResearchAgent] #{message}"
    end
  end
end
