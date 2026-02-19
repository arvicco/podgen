# frozen_string_literal: true

require "optparse"
require_relative "cli/version"

module PodgenCLI
  COMMANDS = {
    "generate"  => ["Run the full podcast pipeline",       "cli/generate_command",  "GenerateCommand"],
    "rss"       => ["Generate RSS feed for a podcast",     "cli/rss_command",       "RssCommand"],
    "list"      => ["List available podcasts",             "cli/list_command",      "ListCommand"],
    "test"      => ["Run a standalone test script",        "cli/test_command",      "TestCommand"],
    "schedule"  => ["Install launchd scheduler",           "cli/schedule_command",  "ScheduleCommand"]
  }.freeze

  def self.run(argv)
    options = { verbosity: :normal }

    global = OptionParser.new do |opts|
      opts.banner = "Usage: podgen [options] <command> [command-options]"
      opts.separator ""
      opts.separator "Commands:"
      max_name = COMMANDS.keys.map(&:length).max
      COMMANDS.each do |name, (desc, _, _)|
        opts.separator "  #{name.ljust(max_name)}   #{desc}"
      end
      opts.separator ""
      opts.separator "Global options:"

      opts.on("-v", "--verbose", "Verbose output") { options[:verbosity] = :verbose }
      opts.on("-q", "--quiet",   "Suppress terminal output (errors still shown)") { options[:verbosity] = :quiet }
      opts.on("-V", "--version", "Print version and exit") do
        puts "podgen #{VERSION}"
        return 0
      end
      opts.on("-h", "--help", "Show this help") do
        puts opts
        return 0
      end
    end

    begin
      global.order!(argv)
    rescue OptionParser::InvalidOption => e
      $stderr.puts "#{e.message}\n\n#{global}"
      return 2
    end

    command_name = argv.shift

    unless command_name
      puts global
      return 2
    end

    entry = COMMANDS[command_name]
    unless entry
      $stderr.puts "Unknown command: #{command_name}\n\n#{global}"
      return 2
    end

    _, require_path, class_name = entry
    require_relative require_path

    cmd = PodgenCLI.const_get(class_name).new(argv, options)
    cmd.run
  end
end
