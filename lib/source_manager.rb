# frozen_string_literal: true

require "set"

require_relative "agents/research_agent"
require_relative "sources/rss_source"
require_relative "sources/hn_source"
require_relative "sources/claude_web_source"
require_relative "sources/bluesky_source"
require_relative "sources/x_source"

class SourceManager
  REGISTRY = {
    "exa" => ->(opts) { ResearchAgent.new(**opts) },
    "rss" => ->(opts) { RSSSource.new(**opts) },
    "hackernews" => ->(opts) { HNSource.new(**opts) },
    "claude_web" => ->(opts) { ClaudeWebSource.new(**opts) },
    "bluesky" => ->(opts) { BlueskySource.new(**opts) },
    "x" => ->(opts) { XSource.new(**opts) }
  }.freeze

  def initialize(source_config:, exclude_urls: Set.new, logger: nil, cache_dir: nil)
    @source_config = source_config
    @exclude_urls = exclude_urls
    @logger = logger
    @cache = if cache_dir
      require_relative "research_cache"
      ResearchCache.new(cache_dir)
    end
  end

  # Runs all enabled sources in parallel and merges results.
  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics)
    sources = enabled_sources
    results_by_source = {}

    threads = sources.map do |name, source|
      Thread.new(name, source) do |src_name, src|
        Thread.current[:name] = src_name
        log("Running source: #{src_name}")
        start = Time.now

        begin
          # Check cache first
          if @cache
            cached = @cache.get(src_name, topics)
            if cached
              log("Cache hit for source '#{src_name}'")
              results_by_source[src_name] = cached
              next
            end
          end

          accepts_keywords = src.method(:research).parameters.any? { |type, _| type == :key || type == :keyreq }
          results = if accepts_keywords
            src.research(topics, exclude_urls: @exclude_urls)
          else
            src.research(topics)
          end

          # Normalize keys to symbols
          results = results.map { |r| normalize_result(r) }

          elapsed = (Time.now - start).round(2)
          finding_count = results.sum { |r| r[:findings].length }
          log("Source '#{src_name}' returned #{finding_count} findings (#{elapsed}s)")

          # Cache results
          @cache&.set(src_name, topics, results)

          results_by_source[src_name] = results
        rescue => e
          log("Source '#{src_name}' failed: #{e.message}")
        end
      end
    end

    threads.each(&:join)

    # Merge results sequentially in original source order for deterministic output
    all_results = []
    seen_urls = @exclude_urls.dup

    sources.each do |name, _source|
      results = results_by_source[name]
      next unless results

      # Cross-source URL dedup
      results.each do |r|
        r[:findings].reject! { |f| seen_urls.include?(f[:url]) }
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
      when "x"
        opts[:priority_handles] = config.is_a?(Array) ? config : []
      end

      [name, factory.call(opts)]
    end
  end

  # Normalize a result hash to use symbol keys consistently.
  # Accepts either string or symbol keys and outputs symbol keys.
  def normalize_result(result)
    topic = result[:topic] || result["topic"]
    findings = (result[:findings] || result["findings"] || []).map do |f|
      {
        title: f[:title] || f["title"],
        url: f[:url] || f["url"],
        summary: f[:summary] || f["summary"]
      }
    end
    { topic: topic, findings: findings }
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
