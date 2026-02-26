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

  # Parses languages from ## Podcast section (new format) or ## Language section (legacy)
  # Returns: [{ "code" => "en" }, { "code" => "es" }, { "code" => "fr", "voice_id" => "pN..." }]
  # Defaults to [{ "code" => "en" }] if section is missing
  def languages
    @languages ||= podcast_section[:languages] || parse_language_section(guidelines)
  end

  # Extracts name from ## Podcast (new) or ## Name (legacy), falls back to directory name
  def title
    @title ||= podcast_section[:name] || extract_heading("Name") || @name
  end

  # Extracts author from ## Podcast (new) or ## Author (legacy), falls back to "Podcast Agent"
  def author
    @author ||= podcast_section[:author] || extract_heading("Author") || "Podcast Agent"
  end

  # Extracts type from ## Podcast (new) or ## Type (legacy), falls back to "news"
  def type
    @type ||= podcast_section[:type] || extract_heading("Type") || "news"
  end

  # Extracts description from ## Podcast section
  def description
    @description ||= podcast_section[:description]
  end

  # Extracts base_url from ## Podcast section (for RSS enclosure URLs)
  def base_url
    @base_url ||= podcast_section[:base_url]
  end

  # Extracts image from ## Podcast section (for RSS feed artwork)
  def image
    @image ||= podcast_section[:image]
  end

  # Returns path to pronunciation.pls if it exists in the podcast directory, nil otherwise
  def pronunciation_pls_path
    path = File.join(@podcast_dir, "pronunciation.pls")
    File.exist?(path) ? path : nil
  end

  # Extracts target_language from ## Audio (new) or ## Target Language (legacy)
  def target_language
    @target_language ||= audio_section[:target_language] || extract_heading("Target Language")
  end

  # Extracts language from ## Audio (new) or ## Transcription Language (legacy)
  def transcription_language
    @transcription_language ||= audio_section[:language] || extract_heading("Transcription Language")
  end

  # Extracts skip_intro from ## Audio (new) or ## Skip Intro (legacy)
  # Returns Float or nil if not configured
  def skip_intro
    @skip_intro ||= begin
      val = audio_section[:skip_intro]
      return val if val
      val = extract_heading("Skip Intro")
      val ? val.to_f : nil
    end
  end

  # Parses engines from ## Audio (new) or ## Transcription Engine (legacy)
  # Returns array of engine codes: ["open"], ["open", "elab", "groq"], etc.
  # Default (missing section): ["open"]
  def transcription_engines
    @transcription_engines ||= audio_section[:engines] || parse_transcription_engine_section(guidelines)
  end

  # Parses "## LingQ" section from guidelines.md
  # Returns hash: { collection:, level:, tags:, image:, accent:, status:,
  #   base_image:, font:, font_color:, font_size:, text_width:,
  #   text_gravity:, text_x_offset:, text_y_offset: } or nil
  def lingq_config
    @lingq_config ||= parse_lingq_section(guidelines)
  end

  # LingQ upload enabled if section exists with collection AND API key is set
  def lingq_enabled?
    config = lingq_config
    config && config[:collection] && ENV["LINGQ_API_KEY"] && !ENV["LINGQ_API_KEY"].empty?
  end

  # Cover generation enabled if base_image is configured and exists on disk
  def cover_generation_enabled?
    config = lingq_config
    config && config[:base_image] && File.exist?(config[:base_image])
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

  def transcript_path(date = Date.today)
    File.join(@episodes_dir, "#{episode_basename(date)}_transcript.md")
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

  # Memoized parse of ## Podcast section (new consolidated format)
  def podcast_section
    @podcast_section ||= parse_podcast_section(guidelines)
  end

  # Memoized parse of ## Audio section (new consolidated format)
  def audio_section
    @audio_section ||= parse_audio_section(guidelines)
  end

  # Parses ## Podcast key-value list: name, type, author, language (with sub-items)
  def parse_podcast_section(text)
    match = text.match(/^## Podcast\s*\n(.*?)(?=^## |\z)/m)
    return {} unless match

    config = {}
    current_key = nil

    match[1].each_line do |line|
      next if line.strip.start_with?("<!--") || line.strip.start_with?("-->")

      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          if value.empty?
            current_key = key
          else
            current_key = nil
            config[key.to_sym] = value
          end
        end
      elsif current_key == "language" && line.match?(/^\s+- \S/)
        entry = line.strip.sub(/^- /, "").strip
        config[:languages] ||= []
        if entry.include?(":")
          code, voice_id = entry.split(":", 2).map(&:strip)
          config[:languages] << { "code" => code, "voice_id" => voice_id }
        else
          config[:languages] << { "code" => entry }
        end
      end
    end

    config
  end

  # Parses ## Audio key-value list: engine (with sub-items), language, target_language, skip_intro
  def parse_audio_section(text)
    match = text.match(/^## Audio\s*\n(.*?)(?=^## |\z)/m)
    return {} unless match

    config = {}
    current_key = nil

    match[1].each_line do |line|
      if line.match?(/^- \S/)
        item = line.strip.sub(/^- /, "")
        if item.include?(":")
          key, value = item.split(":", 2)
          key = key.strip
          value = value.strip
          if value.empty?
            current_key = key
          else
            current_key = nil
            case key
            when "skip_intro"
              config[:skip_intro] = value.to_f
            else
              config[key.to_sym] = value
            end
          end
        end
      elsif current_key == "engine" && line.match?(/^\s+- \S/)
        entry = line.strip.sub(/^- /, "").strip
        config[:engines] ||= []
        config[:engines] << entry unless entry.empty?
      end
    end

    config
  end

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

  def parse_transcription_engine_section(text)
    default = ["open"]

    match = text.match(/^## Transcription Engine\s*\n(.*?)(?=^## |\z)/m)
    return default unless match

    engines = []
    match[1].each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      code = line.sub(/^- /, "").strip
      engines << code unless code.empty?
    end

    engines.empty? ? default : engines
  end

  def parse_lingq_section(text)
    match = text.match(/^## LingQ\s*\n(.*?)(?=^## |\z)/m)
    return nil unless match

    config = {}
    match[1].each_line do |line|
      line = line.strip
      next unless line.start_with?("- ")

      entry = line.sub(/^- /, "").strip
      next unless entry.include?(":")

      key, value = entry.split(":", 2).map(&:strip)
      case key
      when "collection"
        config[:collection] = value.to_i
      when "level"
        config[:level] = value.to_i
      when "tags"
        config[:tags] = value.split(",").map(&:strip)
      when "image"
        config[:image] = resolve_path(value)
      when "base_image"
        config[:base_image] = resolve_path(value)
      when "font"
        config[:font] = value
      when "font_color"
        config[:font_color] = value
      when "font_size"
        config[:font_size] = value.to_i
      when "text_width"
        config[:text_width] = value.to_i
      when "text_gravity"
        config[:text_gravity] = value
      when "text_x_offset"
        config[:text_x_offset] = value.to_i
      when "text_y_offset"
        config[:text_y_offset] = value.to_i
      when "accent"
        config[:accent] = value
      when "status"
        config[:status] = value
      end
    end

    config.empty? ? nil : config
  end

  # Resolves a path relative to the podcast directory.
  # Absolute paths are returned as-is.
  def resolve_path(value)
    return value if value.start_with?("/")

    File.join(@podcast_dir, value)
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
