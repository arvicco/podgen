# frozen_string_literal: true

require "yaml"
require "date"
require "set"

class EpisodeHistory
  LOOKBACK_DAYS = 7

  def initialize(history_path)
    @path = history_path
  end

  # Returns array of recent episode hashes (within lookback window)
  def recent_episodes
    return [] unless File.exist?(@path)

    entries = YAML.load_file(@path) || []
    cutoff = (Date.today - LOOKBACK_DAYS).to_s
    entries.select { |e| e["date"] >= cutoff }
  end

  # Returns Set of all URLs from recent episodes
  def recent_urls
    recent_episodes.flat_map { |e| e["urls"] || [] }.to_set
  end

  # Returns formatted string of recent topics for the topic agent prompt
  def recent_topics_summary
    summary = recent_episodes.map { |e|
      "- #{e['date']}: #{(e['topics'] || []).join('; ')}"
    }.join("\n")
    summary.empty? ? nil : summary
  end

  # Append a new episode entry and prune old entries
  def record!(date:, title:, topics:, urls:)
    entries = File.exist?(@path) ? (YAML.load_file(@path) || []) : []
    entries << {
      "date" => date.to_s,
      "title" => title,
      "topics" => topics,
      "urls" => urls
    }

    # Prune entries older than lookback window
    cutoff = (Date.today - LOOKBACK_DAYS).to_s
    entries.select! { |e| e["date"] >= cutoff }

    File.write(@path, entries.to_yaml)
  end
end
