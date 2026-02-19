# frozen_string_literal: true

module PodgenCLI
  class ScheduleCommand
    def initialize(args, options)
      @podcast_name = args.shift
      @options = options
    end

    def run
      script_path = File.join(File.expand_path("../../..", __dir__), "scripts", "install_scheduler.sh")

      unless @podcast_name
        puts "Usage: podgen schedule <podcast_name>"
        puts
        puts "Installs a daily launchd scheduler (6:00 AM) for the given podcast."
        return 2
      end

      exec("bash", script_path, @podcast_name)
    end
  end
end
