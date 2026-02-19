# frozen_string_literal: true

require "fileutils"
require "date"

class PodcastConfig
  attr_reader :name, :podcast_dir, :guidelines_path, :queue_path, :episodes_dir, :feed_path, :log_dir, :history_path

  def initialize(name)
    @name = name
    @root = self.class.root
    @podcast_dir = File.join(@root, "podcasts", name)
    podcast_dir = @podcast_dir

    unless Dir.exist?(podcast_dir)
      raise "Unknown podcast: #{name}. Available: #{self.class.available.join(', ')}"
    end

    @guidelines_path = File.join(podcast_dir, "guidelines.md")
    @queue_path      = File.join(podcast_dir, "queue.yml")
    @env_path        = File.join(podcast_dir, ".env")
    @episodes_dir    = File.join(@root, "output", name, "episodes")
    @feed_path       = File.join(@root, "output", name, "feed.xml")
    @history_path    = File.join(@root, "output", name, "history.yml")
    @log_dir         = File.join(@root, "logs", name)
  end

  # Load per-podcast .env overrides on top of root .env.
  # Must be called after Dotenv.load (root .env).
  def load_env!
    return unless File.exist?(@env_path)

    require "dotenv"
    Dotenv.overload(@env_path)
  end

  def guidelines
    @guidelines_text ||= File.read(@guidelines_path)
  end

  # Parses the ## Sources section from guidelines.md
  # Returns: { "exa" => true, "hackernews" => true, "rss" => ["url1", ...], "claude_web" => true }
  # Defaults to { "exa" => true } if section is missing
  def sources
    @sources ||= parse_sources_section(guidelines)
  end

  # Parses the ## Language section from guidelines.md
  # Returns: [{ "code" => "en" }, { "code" => "es" }, { "code" => "fr", "voice_id" => "pN..." }]
  # Defaults to [{ "code" => "en" }] if section is missing
  def languages
    @languages ||= parse_language_section(guidelines)
  end

  # Extracts "## Name" from guidelines.md, falls back to directory name
  def title
    @title ||= extract_heading("Name") || @name
  end

  # Extracts "## Author" from guidelines.md, falls back to "Podcast Agent"
  def author
    @author ||= extract_heading("Author") || "Podcast Agent"
  end

  def queue_topics
    YAML.load_file(@queue_path)["topics"]
  end

  def ensure_directories!
    FileUtils.mkdir_p(@episodes_dir)
    FileUtils.mkdir_p(@log_dir)
  end

  # Returns the next available episode basename (without extension) for the given date.
  # First run:  ruby_world-2026-02-18
  # Second run: ruby_world-2026-02-18a
  # Third run:  ruby_world-2026-02-18b
  def episode_basename(date = Date.today)
    date_str = date.strftime("%Y-%m-%d")
    prefix = "#{@name}-#{date_str}"
    existing = Dir.glob(File.join(@episodes_dir, "#{prefix}*.mp3"))
      .map { |f| File.basename(f, ".mp3") }
      .reject { |f| f.include?("_concat") }
      .reject { |f| f.match?(/-[a-z]{2}$/) } # exclude language-suffixed files (e.g. -es, -fr)

    if existing.empty?
      prefix
    else
      suffix_index = existing.length - 1
      "#{prefix}#{('a'.ord + suffix_index).chr}"
    end
  end

  def episode_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}.mp3")
  end

  def script_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}_script.md")
  end

  # Returns basename with language suffix for non-English, e.g. "ruby_world-2026-02-18-es"
  def episode_basename_for_language(date, language_code:)
    base = episode_basename(date)
    language_code == "en" ? base : "#{base}-#{language_code}"
  end

  def episode_path_for_language(date, language_code:)
    File.join(@episodes_dir, "#{episode_basename_for_language(date, language_code: language_code)}.mp3")
  end

  def script_path_for_language(date, language_code:)
    File.join(@episodes_dir, "#{episode_basename_for_language(date, language_code: language_code)}_script.md")
  end

  def log_path(date = Date.today)
    File.join(@log_dir, "#{episode_basename(date)}.log")
  end

  # Project root: resolved via PODGEN_ROOT env var (set by bin/podgen),
  # falling back to the code location (for direct script usage).
  def self.root
    ENV["PODGEN_ROOT"] || File.expand_path("..", __dir__)
  end

  def self.available
    Dir.glob(File.join(root, "podcasts", "*"))
      .select { |f| Dir.exist?(f) }
      .map { |f| File.basename(f) }
      .sort
  end

  private

  # Extracts the first line of content under a ## heading
  def extract_heading(heading)
    match = guidelines.match(/^## #{Regexp.escape(heading)}\s*\n(.+?)(?:\n|$)/)
    match ? match[1].strip : nil
  end

  def parse_language_section(text)
    default = [{ "code" => "en" }]

    match = text.match(/^## Language\s*\n(.*?)(?=^## |\z)/m)
    return default unless match

    languages = []
    match[1].each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      entry = line.sub(/^- /, "").strip
      if entry.include?(":")
        code, voice_id = entry.split(":", 2).map(&:strip)
        languages << { "code" => code, "voice_id" => voice_id }
      else
        languages << { "code" => entry }
      end
    end

    languages.empty? ? default : languages
  end

  def parse_sources_section(text)
    default = { "exa" => true }

    # Extract text between ## Sources and the next ## heading (or EOF)
    match = text.match(/^## Sources\s*\n(.*?)(?=^## |\z)/m)
    return default unless match

    section = match[1]
    sources = {}
    current_key = nil

    section.each_line do |line|
      # Top-level item: "- name", "- name:", or "- name: val1, val2"
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          current_key = key.strip
          inline = value.strip
          if inline.empty?
            # "- name:" with sub-list to follow
            sources[current_key] = []
          else
            # "- name: val1, val2" inline comma-separated
            current_key = nil
            sources[key.strip] = inline.split(",").map(&:strip)
          end
        else
          current_key = nil
          sources[item] = true
        end
      # Sub-item: "  - value" (indented under a key with colon)
      elsif current_key && line.match?(/^\s+- \S/)
        value = line.strip.sub(/^- /, "")
        sources[current_key] << value
      end
    end

    sources.empty? ? default : sources
  end
end
