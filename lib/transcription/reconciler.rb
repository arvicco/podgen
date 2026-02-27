# frozen_string_literal: true

require "anthropic"

module Transcription
  class Reconciler
    MAX_RETRIES = 3

    def initialize(language: "Slovenian", logger: nil)
      @client = Anthropic::Client.new
      @model = ENV.fetch("CLAUDE_MODEL", "claude-opus-4-6")
      @language = language
      @logger = logger
    end

    # Multi-engine: reconcile 2+ transcripts sentence by sentence
    # Input: { "open" => "text...", "elab" => "text..." }
    # Output: reconciled text string
    def reconcile(transcripts)
      raise ArgumentError, "Need 2+ transcripts to reconcile" if transcripts.size < 2

      log("Reconciling #{transcripts.size} engine transcripts with #{@model}")
      call_api(reconcile_system_prompt, reconcile_user_prompt(transcripts))
    end

    # Single-engine: clean up grammar, fix obvious errors, regularize punctuation
    # Input: raw transcript text string
    # Output: cleaned text string
    def cleanup(text, captions: nil)
      raise ArgumentError, "Text is empty" if text.to_s.strip.empty?

      log("Cleaning up transcript with #{@model}")
      call_api(cleanup_system_prompt, cleanup_user_prompt(text, captions: captions))
    end

    private

    def call_api(system, user_content)
      retries = 0
      begin
        retries += 1
        start = Time.now

        message = @client.messages.create(
          model: @model,
          max_tokens: 16384,
          system: system,
          messages: [
            { role: "user", content: user_content }
          ]
        )

        elapsed = (Time.now - start).round(2)
        log_usage(message, elapsed)

        text = message.content
          .select { |block| block.type.to_s == "text" }
          .map(&:text)
          .join("\n")
          .strip

        raise "Empty response from reconciler" if text.empty?

        log("Result: #{text.length} chars")
        text

      rescue Anthropic::Errors::APIError => e
        if retries <= MAX_RETRIES
          sleep_time = 2**retries
          log("API error (attempt #{retries}/#{MAX_RETRIES}): #{e.message}. Retrying in #{sleep_time}s...")
          sleep(sleep_time)
          retry
        else
          raise "Reconciler failed after #{MAX_RETRIES} retries: #{e.message}"
        end
      end
    end

    # Shared cleanup rules applied to both modes
    CLEANUP_RULES = <<~RULES
      - Fix obvious grammar and spelling errors
      - Regularize punctuation (proper sentence endings, quotation marks, dashes)
      - Remove hallucination artifacts: repeated phrases, nonsense text, filler artifacts
      - Remove STT artifacts like "[glazba]", "[music]", "[applause]" or similar tags
      - Do NOT change the meaning or rephrase sentences — only fix errors and clean up
      - Do NOT add content that isn't in the original
      - Preserve the original language — do NOT translate into English or any other language
      - Output ONLY the cleaned transcript text — no commentary, no headers, no engine labels
    RULES

    FORMATTING_RULES = <<~RULES
      - Divide text into paragraphs — separate them with a blank line
      - Start a new paragraph on topic shifts, scene changes, or after dialog exchanges
      - Format direct speech with straight double quotes "..."
        Example: Pirina je rekla: "Povej še kaj!"
        Example: "Kako si ljubezniva," je odvrnila Pirina. "Tudi ti si se zelo potrudila."
      - Use straight double quotes "..." for all direct speech (never »...« or „...")
      - When a speaker's dialog continues across multiple sentences, keep it in ONE paragraph
      - Separate different speakers' turns with a blank line
    RULES

    # --- Multi-engine reconciliation ---

    def reconcile_system_prompt
      <<~PROMPT
        You are a transcript reconciliation expert. You receive transcripts of the same audio from multiple speech-to-text engines. Your job is to produce the single best transcript.

        Reconciliation rules:
        - Compare the transcripts sentence by sentence
        - For each sentence, pick the best rendering (best grammar, most accurate words, most natural phrasing)
        - If a sentence appears in only one engine and looks like a hallucination (repetitive, nonsensical, or out of context), omit it
        - If a "captions" source is included, it contains auto-generated YouTube captions — these are lower quality (no punctuation, timing artifacts, possible errors) but can help as a tiebreaker when STT engines disagree on a word or phrase

        Cleanup rules:
        #{CLEANUP_RULES}
        Formatting rules:
        #{FORMATTING_RULES}
      PROMPT
    end

    def reconcile_user_prompt(transcripts)
      parts = transcripts.map do |code, text|
        "=== Engine: #{code} ===\n#{text}"
      end

      parts.join("\n\n") + <<~INSTRUCTIONS

        ---

        Reconcile these #{transcripts.size} transcripts of the same #{@language} audio into a single best transcript.
        Format with paragraphs and uniform dialog markers. Only output the transcript text, nothing else.
      INSTRUCTIONS
    end

    # --- Single-engine cleanup ---

    def cleanup_system_prompt
      <<~PROMPT
        You are a transcript cleanup expert. You receive a raw transcript from a speech-to-text engine. Your job is to produce a clean, polished version.

        Rules:
        #{CLEANUP_RULES}
        Formatting rules:
        #{FORMATTING_RULES}
      PROMPT
    end

    def cleanup_user_prompt(text, captions: nil)
      prompt = <<~PROMPT
        Clean up this #{@language} transcript:

        #{text}
      PROMPT

      if captions
        prompt += <<~CAPTIONS

          ---

          Reference: auto-generated YouTube captions (lower quality, use only to verify unclear words):

          #{captions}
        CAPTIONS
      end

      prompt += <<~INSTRUCTIONS

        ---

        Format with paragraphs and uniform dialog markers. Only output the transcript text, nothing else.
      INSTRUCTIONS

      prompt
    end

    def log_usage(message, elapsed)
      usage = message.usage
      log("Completed in #{elapsed}s (#{message.stop_reason})")
      log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
      cache_create = usage.cache_creation_input_tokens || 0
      cache_read = usage.cache_read_input_tokens || 0
      log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
    end

    def log(message)
      if @logger
        @logger.log("[Reconciler] #{message}")
      else
        puts "[Reconciler] #{message}"
      end
    end
  end
end
