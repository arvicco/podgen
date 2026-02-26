# frozen_string_literal: true

require "optparse"
require_relative "cli/version"

module PodgenCLI
  COMMANDS = {
    "generate"  => ["Run the full podcast pipeline",       "cli/generate_command",  "GenerateCommand"],
    "scrap"     => ["Remove last episode and history",     "cli/scrap_command",     "ScrapCommand"],
    "rss"       => ["Generate RSS feed for a podcast",     "cli/rss_command",       "RssCommand"],
    "publish"   => ["Publish to Cloudflare R2 or LingQ",    "cli/publish_command",   "PublishCommand"],
    "stats"     => ["Show podcast statistics",             "cli/stats_command",     "StatsCommand"],
    "validate"  => ["Validate podcast config and output",  "cli/validate_command",  "ValidateCommand"],
    "list"      => ["List available podcasts",             "cli/list_command",      "ListCommand"],
    "test"      => ["Run a standalone test script",        "cli/test_command",      "TestCommand"],
    "schedule"  => ["Install launchd scheduler",           "cli/schedule_command",  "ScheduleCommand"]
  }.freeze

  def self.run(argv)
    options = { verbosity: :normal }

    global = OptionParser.new do |opts|
      opts.banner = "Usage: podgen [options] <command> [args]"
      opts.separator ""
      opts.separator "Fully autonomous podcast generation pipeline."
      opts.separator ""
      opts.separator "Commands:"
      opts.separator "  generate <podcast>             Run the full pipeline (news or language)"
      opts.separator "  scrap <podcast>                Remove last episode files + history entry"
      opts.separator "  rss <podcast>                  Generate RSS feed"
      opts.separator "  publish <podcast>              Publish to Cloudflare R2 (--lingq for LingQ)"
      opts.separator "  stats <podcast> | --all        Show podcast statistics"
      opts.separator "  validate <podcast> | --all     Validate config and output"
      opts.separator "  list                           List available podcasts"
      opts.separator "  test <name> [args]             Run a standalone test"
      opts.separator "  schedule <podcast>             Install launchd scheduler"
      opts.separator ""
      opts.separator "Pipelines (configured via ## Type in guidelines.md):"
      opts.separator "  news      Research topics, write script, TTS, assemble MP3 (default)"
      opts.separator "  language  Download from RSS, trim music, transcribe, assemble MP3"
      opts.separator ""
      opts.separator "Transcription engines (## Transcription Engine in guidelines.md):"
      opts.separator "  open      OpenAI Whisper / gpt-4o-transcribe (default)"
      opts.separator "  elab      ElevenLabs Scribe v2"
      opts.separator "  groq      Groq hosted Whisper"
      opts.separator "  List multiple engines for side-by-side comparison mode."
      opts.separator ""
      opts.separator "Tests:"
      opts.separator "  research, rss, hn, claude_web, bluesky, x, script, tts,"
      opts.separator "  assembly, translation, transcription, sources"
      opts.separator "  Example: podgen test transcription lahko_noc elab"
      opts.separator "           podgen test transcription audio.mp3 all"
      opts.separator ""
      opts.separator "Options:"

      opts.on("-v", "--verbose", "Verbose output") { options[:verbosity] = :verbose }
      opts.on("-q", "--quiet",   "Suppress terminal output (errors still shown)") { options[:verbosity] = :quiet }
      opts.on("--dry-run", "Validate config, skip API calls and file output") { options[:dry_run] = true }
      opts.on("--lingq", "Enable LingQ upload (generate) or publish to LingQ (publish)") { options[:lingq] = true }
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
