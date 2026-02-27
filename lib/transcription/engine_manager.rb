# frozen_string_literal: true

require_relative "openai_engine"
require_relative "elevenlabs_engine"
require_relative "groq_engine"
require_relative "reconciler"

module Transcription
  class EngineManager
    REGISTRY = {
      "open" => OpenaiEngine,
      "elab" => ElevenlabsEngine,
      "groq" => GroqEngine
    }.freeze

    def initialize(engine_codes:, language: "sl", target_language: nil, logger: nil)
      @engine_codes = engine_codes
      @language = language
      @target_language = target_language
      @logger = logger
    end

    # Single engine: returns { text:, segments:, speech_start:, speech_end:, cleaned: }
    # Comparison mode (2+ engines): returns { primary:, all: { "open" => {...}, ... }, errors: {}, reconciled: }
    # Optional captions: plain text from YouTube auto-captions (used as reference)
    def transcribe(audio_path, captions: nil)
      if @engine_codes.length == 1
        result = build_engine(@engine_codes.first).transcribe(audio_path)
        result[:cleaned] = run_cleanup(result[:text], captions: captions)
        result
      else
        transcribe_comparison(audio_path, captions: captions)
      end
    end

    private

    def transcribe_comparison(audio_path, captions: nil)
      results = {}
      errors = {}

      threads = @engine_codes.map do |code|
        Thread.new(code) do |c|
          Thread.current[:engine] = c
          engine = build_engine(c)
          log("Starting engine: #{c}")
          start = Time.now
          results[c] = engine.transcribe(audio_path)
          elapsed = (Time.now - start).round(2)
          log("Engine '#{c}' completed in #{elapsed}s")
        rescue => e
          errors[c] = e.message
          log("Engine '#{c}' failed: #{e.message}")
        end
      end

      threads.each(&:join)

      # Use configured primary, fall back to first successful engine
      primary_code = @engine_codes.first
      primary_result = results[primary_code]

      unless primary_result
        fallback_code = @engine_codes.find { |c| results[c] }
        raise "All engines failed: #{errors}" unless fallback_code
        log("Primary engine '#{primary_code}' failed, falling back to '#{fallback_code}'")
        primary_code = fallback_code
        primary_result = results[fallback_code]
      end

      raise "No engines succeeded" if results.empty?

      comparison = {
        primary: primary_result,
        all: results,
        errors: errors,
        reconciled: nil
      }

      # Reconcile if 2+ sources available (engines + optional captions)
      texts = results.transform_values { |r| r[:text] }
      texts["captions"] = captions if captions

      if texts.size >= 2
        begin
          comparison[:reconciled] = build_reconciler.reconcile(texts)
        rescue => e
          log("Reconciliation failed (non-fatal): #{e.message}")
        end
      end

      comparison
    end

    def run_cleanup(text, captions: nil)
      build_reconciler.cleanup(text, captions: captions)
    rescue => e
      log("Cleanup failed (non-fatal): #{e.message}")
      nil
    end

    def build_reconciler
      Reconciler.new(language: @target_language || @language, logger: @logger)
    end

    def build_engine(code)
      klass = REGISTRY[code]
      raise "Unknown transcription engine: #{code}" unless klass

      klass.new(language: @language, logger: @logger)
    end

    def log(message)
      if @logger
        @logger.log("[EngineManager] #{message}")
      else
        puts "[EngineManager] #{message}"
      end
    end
  end
end
