# frozen_string_literal: true

require "anthropic"
require "fileutils"
require "date"

class Segment < Anthropic::BaseModel
  required :name, String
  required :text, String
end

class PodcastScript < Anthropic::BaseModel
  required :title, String
  required :segments, Anthropic::ArrayOf[Segment]
end

class ScriptAgent
  MAX_RETRIES = 3

  def initialize(logger: nil)
    @logger = logger
    @client = Anthropic::Client.new # reads ENV["ANTHROPIC_API_KEY"] automatically
    @model = ENV.fetch("CLAUDE_MODEL", "claude-opus-4-6")
    @root = File.expand_path("../..", __dir__)
    @guidelines = File.read(File.join(@root, "config", "guidelines.md"))
  end

  # Input: array of { topic:, findings: [{ title:, url:, summary: }] }
  # Output: { title:, segments: [{ name:, text: }] }
  def generate(research_data)
    log("Generating script with #{@model}")
    research_text = format_research(research_data)

    retries = 0
    begin
      retries += 1
      start = Time.now

      message = @client.messages.create(
        model: @model,
        max_tokens: 8192,
        system: build_system_prompt,
        messages: [
          {
            role: "user",
            content: "Write a podcast script based on this research:\n\n#{research_text}"
          }
        ],
        output_config: { format: PodcastScript }
      )

      elapsed = (Time.now - start).round(2)
      log_usage(message, elapsed)

      script = message.parsed_output
      raise "Structured output parsing failed" if script.nil?

      result = {
        title: script.title,
        segments: script.segments.map { |s| { name: s.name, text: s.text } }
      }

      save_script_debug(result)
      result

    rescue Anthropic::Errors::APIError => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("API error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
        sleep(sleep_time)
        retry
      else
        raise "ScriptAgent failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    end
  end

  private

  def build_system_prompt
    [
      {
        type: "text",
        text: <<~PROMPT
          You are an expert podcast scriptwriter. Generate a complete podcast script
          following the provided guidelines exactly. The script must include:
          - An "intro" segment with a brief news hook
          - Numbered main segments ("segment_1", "segment_2") covering one topic each
          - An "outro" segment with a practical takeaway

          Write naturally as spoken word — no stage directions, no timestamps, no markdown.
          Each segment's text should be the exact words the host will speak aloud.
        PROMPT
      },
      {
        type: "text",
        text: @guidelines,
        cache_control: { type: "ephemeral" }
      }
    ]
  end

  def format_research(research_data)
    research_data.map do |item|
      findings = item[:findings].map do |f|
        "  - #{f[:title]} (#{f[:url]})\n    #{f[:summary]}"
      end.join("\n")
      "## #{item[:topic]}\n#{findings}"
    end.join("\n\n")
  end

  def save_script_debug(script)
    episodes_dir = File.join(@root, "output", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    path = File.join(episodes_dir, "#{Date.today.strftime('%Y-%m-%d')}_script.md")

    File.open(path, "w") do |f|
      f.puts "# #{script[:title]}"
      f.puts
      script[:segments].each do |seg|
        f.puts "## #{seg[:name]}"
        f.puts
        f.puts seg[:text]
        f.puts
      end
    end

    log("Script saved to #{path}")
  end

  def log_usage(message, elapsed)
    usage = message.usage
    log("Script generated in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
    cache_create = usage.cache_creation_input_tokens || 0
    cache_read = usage.cache_read_input_tokens || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end

  def log(message)
    if @logger
      @logger.log("[ScriptAgent] #{message}")
    else
      puts "[ScriptAgent] #{message}"
    end
  end
end
