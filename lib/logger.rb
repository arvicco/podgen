# frozen_string_literal: true

require "fileutils"
require "time"

module PodcastAgent
  class Logger
    def initialize
      @root = File.expand_path("../..", __dir__)
      @log_dir = File.join(@root, "logs", "runs")
      FileUtils.mkdir_p(@log_dir)
      @log_file = File.join(@log_dir, "#{Date.today.strftime('%Y-%m-%d')}.log")
      @start_times = {}
    end

    def log(message)
      entry = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{message}"
      puts entry
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
      log("ERROR #{message}")
    end

    def log_file_path
      @log_file
    end
  end
end
