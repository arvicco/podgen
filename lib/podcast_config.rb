# frozen_string_literal: true

require "fileutils"
require "date"

class PodcastConfig
  attr_reader :name, :guidelines_path, :queue_path, :episodes_dir, :feed_path, :log_dir, :history_path

  def initialize(name)
    @name = name
    @root = File.expand_path("..", __dir__)
    podcast_dir = File.join(@root, "podcasts", name)

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
    File.read(@guidelines_path)
  end

  def queue_topics
    YAML.load_file(@queue_path)["topics"]
  end

  def ensure_directories!
    FileUtils.mkdir_p(@episodes_dir)
    FileUtils.mkdir_p(@log_dir)
  end

  # Returns the next available episode basename (without extension) for the given date.
  # First run:  fulgur_news-2026-02-18
  # Second run: fulgur_news-2026-02-18a
  # Third run:  fulgur_news-2026-02-18b
  def episode_basename(date = Date.today)
    date_str = date.strftime("%Y-%m-%d")
    prefix = "#{@name}-#{date_str}"
    existing = Dir.glob(File.join(@episodes_dir, "#{prefix}*.mp3"))
      .map { |f| File.basename(f, ".mp3") }
      .reject { |f| f.include?("_concat") }

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

  def log_path(date = Date.today)
    File.join(@log_dir, "#{episode_basename(date)}.log")
  end

  def self.available
    root = File.expand_path("..", __dir__)
    Dir.glob(File.join(root, "podcasts", "*"))
      .select { |f| Dir.exist?(f) }
      .map { |f| File.basename(f) }
      .sort
  end
end
