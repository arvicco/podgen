# frozen_string_literal: true

require "anthropic"
require "set"

class ClaudeWebSource
  MAX_RETRIES = 3
  MODEL = "claude-haiku-4-5-20251001"
  MAX_SEARCH_USES = 3

  def initialize(logger: nil, **_options)
    @logger = logger
    @client = Anthropic::Client.new
  end

  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics, exclude_urls: Set.new)
    topics.map do |topic|
      log("Claude web search: #{topic}")
      start = Time.now
      findings = search_topic(topic, exclude_urls)
      elapsed = (Time.now - start).round(2)
      log("Claude web found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic, exclude_urls)
    message = request_with_retry(topic)
    return [] unless message

    findings = extract_findings(message)
    findings.reject! { |f| exclude_urls.include?(f[:url]) }
    findings
  rescue => e
    log("Failed Claude web search for '#{topic}': #{e.message}")
    []
  end

  def request_with_retry(topic)
    attempts = 0
    begin
      attempts += 1
      @client.messages.create(
        model: MODEL,
        max_tokens: 1024,
        tools: [{ type: "web_search_20250305", name: "web_search", max_uses: MAX_SEARCH_USES }],
        messages: [
          {
            role: "user",
            content: "Find 3 recent, notable articles about: #{topic}. " \
                     "Focus on news from the last 48 hours. " \
                     "For each article, mention its title and key points."
          }
        ]
      )
    rescue Anthropic::Errors::APIError => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("API error (attempt #{attempts}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
        sleep(sleep_time)
        retry
      end
      log("Claude web search failed after #{MAX_RETRIES} retries: #{e.message}")
      nil
    end
  end

  def extract_findings(message)
    # Collect cited URLs with their summaries from text blocks
    findings_by_url = {}

    message.content.each do |block|
      # Extract from text citations (best source of URL + summary)
      if block.is_a?(Hash) ? block[:type] == "text" : (block.respond_to?(:type) && block.type == "text")
        citations = if block.is_a?(Hash)
          block[:citations] || []
        else
          block.respond_to?(:citations) ? (block.citations || []) : []
        end

        citations.each do |cite|
          url = cite.is_a?(Hash) ? cite[:url] : cite.url
          title = cite.is_a?(Hash) ? cite[:title] : cite.title
          cited_text = cite.is_a?(Hash) ? cite[:cited_text] : cite.cited_text

          next unless url && !url.empty?
          next if findings_by_url.key?(url)

          findings_by_url[url] = {
            title: title.to_s,
            url: url,
            summary: cited_text.to_s[0, 500]
          }
        end
      end

      # Fallback: extract from web_search_tool_result blocks
      block_type = block.is_a?(Hash) ? block[:type] : (block.respond_to?(:type) ? block.type : nil)
      next unless block_type == "web_search_tool_result"

      results = block.is_a?(Hash) ? block[:content] : (block.respond_to?(:content) ? block.content : [])
      (results || []).each do |result|
        result_type = result.is_a?(Hash) ? result[:type] : (result.respond_to?(:type) ? result.type : nil)
        next unless result_type == "web_search_result"

        url = result.is_a?(Hash) ? result[:url] : result.url
        title = result.is_a?(Hash) ? result[:title] : result.title

        next unless url && !url.empty?
        next if findings_by_url.key?(url)

        findings_by_url[url] = {
          title: title.to_s,
          url: url,
          summary: ""
        }
      end
    end

    findings_by_url.values.first(5)
  end

  def log(message)
    if @logger
      @logger.log("[ClaudeWebSource] #{message}")
    else
      puts "[ClaudeWebSource] #{message}"
    end
  end
end
