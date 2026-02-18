# frozen_string_literal: true

require "anthropic"
require "date"

class TopicQuery < Anthropic::BaseModel
  required :query, String
end

class TopicList < Anthropic::BaseModel
  required :queries, Anthropic::ArrayOf[TopicQuery]
end

class TopicAgent
  MAX_RETRIES = 3

  def initialize(guidelines:, recent_topics: nil, logger: nil)
    @logger = logger
    @client = Anthropic::Client.new
    @model = ENV.fetch("CLAUDE_MODEL", "claude-opus-4-6")
    @guidelines = guidelines
    @recent_topics = recent_topics
  end

  # Output: array of topic query strings (same format ResearchAgent expects)
  def generate
    log("Generating topics with #{@model}")
    today = Date.today.strftime("%Y-%m-%d")

    retries = 0
    begin
      retries += 1
      start = Time.now

      message = @client.messages.create(
        model: @model,
        max_tokens: 1024,
        system: build_system_prompt,
        messages: [
          {
            role: "user",
            content: build_user_prompt(today)
          }
        ],
        output_config: { format: TopicList }
      )

      elapsed = (Time.now - start).round(2)
      log_usage(message, elapsed)

      result = message.parsed_output
      raise "Structured output parsing failed" if result.nil?

      queries = result.queries.map(&:query)
      queries.each { |q| log("  → #{q}") }
      queries

    rescue Anthropic::Errors::APIError => e
      if retries <= MAX_RETRIES
        sleep_time = 2**retries
        log("API error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
        sleep(sleep_time)
        retry
      else
        raise "TopicAgent failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    end
  end

  private

  def build_user_prompt(today)
    prompt = "Today's date is #{today}. Generate 4 specific, timely search queries for this podcast episode."
    if @recent_topics && !@recent_topics.empty?
      prompt += "\n\nIMPORTANT: The following topics were already covered in recent episodes.\n" \
                "Generate queries about DIFFERENT subjects — do not repeat these:\n" \
                "#{@recent_topics}"
    end
    prompt
  end

  def build_system_prompt
    [
      {
        type: "text",
        text: <<~PROMPT
          You are a podcast producer generating search queries for today's episode.
          Based on the podcast guidelines below and today's date, generate exactly 4
          specific, timely search queries that would find the most interesting recent
          news for each topic area defined in the guidelines.

          Each query should be:
          - Specific enough to return focused, relevant results
          - Time-aware (reference this week, recent events, or current trends)
          - Aligned with the podcast's topic areas and editorial voice
          - Different from each other, covering distinct topic areas from the guidelines
        PROMPT
      },
      {
        type: "text",
        text: @guidelines,
        cache_control: { type: "ephemeral" }
      }
    ]
  end

  def log_usage(message, elapsed)
    usage = message.usage
    log("Topics generated in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
    cache_create = usage.cache_creation_input_tokens || 0
    cache_read = usage.cache_read_input_tokens || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end

  def log(message)
    if @logger
      @logger.log("[TopicAgent] #{message}")
    else
      puts "[TopicAgent] #{message}"
    end
  end
end
