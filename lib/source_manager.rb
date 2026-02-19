# frozen_string_literal: true

require "set"

require_relative "agents/research_agent"
require_relative "sources/rss_source"
require_relative "sources/hn_source"
require_relative "sources/claude_web_source"

class SourceManager
  REGISTRY = {
    "exa" => ->(opts) { ResearchAgent.new(**opts) },
    "rss" => ->(opts) { RSSSource.new(**opts) },
    "hackernews" => ->(opts) { HNSource.new(**opts) },
    "claude_web" => ->(opts) { ClaudeWebSource.new(**opts) }
  }.freeze

  def initialize(source_config:, exclude_urls: Set.new, logger: nil)
    @source_config = source_config
    @exclude_urls = exclude_urls
    @logger = logger
  end

  # Runs all enabled sources and merges results.
  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics)
    all_results = []
    seen_urls = @exclude_urls.dup

    enabled_sources.each do |name, source|
      log("Running source: #{name}")
      start = Time.now

      begin
        # ResearchAgent (exa) takes exclude_urls in its constructor, not in research().
        # Check if the source's research method accepts keyword args before passing them.
        accepts_keywords = source.method(:research).parameters.any? { |type, _| type == :key || type == :keyreq }
        results = if accepts_keywords
          source.research(topics, exclude_urls: seen_urls)
        else
          source.research(topics)
        end
      rescue => e
        log("Source '#{name}' failed: #{e.message}")
        next
      end

      elapsed = (Time.now - start).round(2)
      finding_count = results.sum { |r| r[:findings].length }
      log("Source '#{name}' returned #{finding_count} findings (#{elapsed}s)")

      # Track URLs from this source to dedup across sources
      results.each do |r|
        r[:findings].each { |f| seen_urls.add(f[:url]) }
      end

      all_results = merge_results(all_results, results)
    end

    total = all_results.sum { |r| r[:findings].length }
    log("All sources complete: #{total} total findings across #{all_results.length} topics")
    all_results
  end

  private

  def enabled_sources
    @source_config.filter_map do |name, config|
      factory = REGISTRY[name]
      unless factory
        log("Unknown source '#{name}', skipping")
        next
      end

      opts = { logger: @logger }

      # Pass source-specific options
      case name
      when "exa"
        opts[:exclude_urls] = @exclude_urls
      when "rss"
        opts[:feeds] = config.is_a?(Array) ? config : []
      end

      [name, factory.call(opts)]
    end
  end

  # Merge new results into existing. Combine findings for matching topics; append new topics.
  def merge_results(existing, new_results)
    merged = existing.dup
    topic_index = {}
    merged.each_with_index { |r, i| topic_index[r[:topic]] = i }

    new_results.each do |result|
      if topic_index.key?(result[:topic])
        idx = topic_index[result[:topic]]
        # Append new findings, skipping duplicate URLs
        existing_urls = merged[idx][:findings].map { |f| f[:url] }.to_set
        new_findings = result[:findings].reject { |f| existing_urls.include?(f[:url]) }
        merged[idx][:findings].concat(new_findings)
      else
        topic_index[result[:topic]] = merged.length
        merged << result
      end
    end

    merged
  end

  def log(message)
    if @logger
      @logger.log("[SourceManager] #{message}")
    else
      puts "[SourceManager] #{message}"
    end
  end
end
