# frozen_string_literal: true

require "fileutils"
require "time"

module PodcastAgent
  class Logger
    # verbosity: :normal (default), :verbose, or :quiet
    # File logging always writes full detail regardless of verbosity.
    # Terminal output is gated: :quiet suppresses stdout, :verbose is same as :normal (for future use).
    def initialize(log_path: nil, verbosity: :normal)
      if log_path
        @log_file = log_path
        FileUtils.mkdir_p(File.dirname(@log_file))
      else
        root = File.expand_path("../..", __dir__)
        log_dir = File.join(root, "logs", "runs")
        FileUtils.mkdir_p(log_dir)
        @log_file = File.join(log_dir, "#{Date.today.strftime('%Y-%m-%d')}.log")
      end
      @verbosity = verbosity
      @start_times = {}
    end

    def log(message)
      entry = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}"
      puts entry unless @verbosity == :quiet
      File.open(@log_file, "a") { |f| f.puts(entry) }
    end

    def phase_start(name)
      @start_times[name] = Time.now
      log("START #{name}")
    end

    def phase_end(name)
      elapsed = if @start_times[name]
        Time.now - @start_times[name]
      else
        0
      end
      log("END #{name} (#{elapsed.round(2)}s)")
    end

    def error(message)
      entry = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] ERROR #{message}"
      $stderr.puts entry
      File.open(@log_file, "a") { |f| f.puts(entry) }
    end

    def log_file_path
      @log_file
    end
  end
end
