# frozen_string_literal: true

require "anthropic"

class DescriptionAgent
  MAX_RETRIES = 3
  TRANSCRIPT_LIMIT = 2000

  def initialize(logger: nil)
    @logger = logger
    @client = Anthropic::Client.new
    @model = ENV.fetch("CLAUDE_WEB_MODEL", "claude-haiku-4-5-20251001")
  end

  # Cleans a YouTube/RSS episode title by stripping category prefixes, labels, and noise.
  # e.g. "PRAVLJICA ZA OTROKE: Lačni medved" → "Lačni medved"
  # Returns cleaned title, or original on failure.
  def clean_title(title:)
    return title if title.to_s.strip.empty?

    log("Cleaning title: \"#{title}\"")
    start = Time.now

    message = @client.messages.create(
      model: @model,
      max_tokens: 256,
      system: clean_title_system_prompt,
      messages: [
        { role: "user", content: title }
      ]
    )

    elapsed = (Time.now - start).round(2)
    result = message.content.first.text.strip
    log_usage(message, elapsed, "clean_title")

    if result.empty?
      log("Cleaned title was empty, keeping original")
      return title
    end

    if result != title
      log("Title cleaned: \"#{title}\" → \"#{result}\"")
    else
      log("Title already clean")
    end
    result
  rescue => e
    log("Warning: Title cleanup failed: #{e.message} (non-fatal, keeping original)")
    title
  end

  # Cleans a YouTube/RSS episode description by extracting only story-relevant content.
  # Drops links, credits, promos, hashtags, emoji headers, parent notes, etc.
  # Returns cleaned description string, or original on failure.
  def clean(title:, description:)
    return description if description.to_s.strip.empty?

    log("Cleaning description for \"#{title}\" (#{description.length} chars)")
    start = Time.now

    message = @client.messages.create(
      model: @model,
      max_tokens: 1024,
      system: clean_system_prompt,
      messages: [
        {
          role: "user",
          content: "Title: #{title}\n\nDescription:\n#{description}"
        }
      ]
    )

    elapsed = (Time.now - start).round(2)
    result = message.content.first.text.strip
    log_usage(message, elapsed, "clean")

    if result.empty?
      log("Cleaned description was empty, keeping original")
      return description
    end

    log("Description cleaned: #{description.length} → #{result.length} chars")
    result
  rescue => e
    log("Warning: Description cleanup failed: #{e.message} (non-fatal, keeping original)")
    description
  end

  # Generates a short description from the transcript for local file episodes.
  # Returns generated description string, or empty string on failure.
  def generate(title:, transcript:)
    return "" if transcript.to_s.strip.empty?

    truncated = transcript[0, TRANSCRIPT_LIMIT]
    log("Generating description for \"#{title}\" from transcript (#{truncated.length} chars)")
    start = Time.now

    message = @client.messages.create(
      model: @model,
      max_tokens: 512,
      system: generate_system_prompt,
      messages: [
        {
          role: "user",
          content: "Title: #{title}\n\nTranscript:\n#{truncated}"
        }
      ]
    )

    elapsed = (Time.now - start).round(2)
    result = message.content.first.text.strip
    log_usage(message, elapsed, "generate")

    log("Description generated: #{result.length} chars")
    result
  rescue => e
    log("Warning: Description generation failed: #{e.message} (non-fatal)")
    ""
  end

  private

  def clean_title_system_prompt
    <<~PROMPT
      Extract ONLY the proper name of the story, episode, or work. Strip away ALL descriptive text.

      Remove:
      - Category/genre prefixes (e.g. "PRAVLJICA ZA OTROKE:", "FAIRY TALE:", "KIDS STORY:")
      - Subtitles and taglines after colon or dash (e.g. "Title: gentle bedtime story" → "Title", "Title - a calming tale for kids" → "Title")
      - Descriptions of the content (e.g. "mirna Grimmova pravljica za lahko noč", "a peaceful Grimm fairy tale")
      - Series labels (e.g. "S1E3 -", "Episode 12:")
      - Channel names or branding
      - Emoji
      - Audience labels (e.g. "for kids", "za otroke", "für Kinder")
      - Mood/tone descriptors (e.g. "calming", "gentle", "mirna", "pomirjujoča")
      - Redundant quotes or brackets around the title

      The result should be JUST the proper name — like a book title on a library shelf.
      Examples:
      - "Trnuljčica: mirna Grimmova pravljica za lahko noč" → "Trnuljčica"
      - "PRAVLJICA ZA OTROKE: Lačni medved" → "Lačni medved"
      - "The Three Bears - A Bedtime Story for Kids" → "The Three Bears"
      - "Sleeping Beauty" → "Sleeping Beauty"

      Keep the core title exactly as written (preserve language, capitalization, punctuation).
      If the entire title IS just the proper name, return it unchanged.
      Output only the cleaned title, nothing else.
    PROMPT
  end

  def clean_system_prompt
    <<~PROMPT
      Extract ONLY the story synopsis or content summary from this episode description. Return just the plot or topic — nothing else.

      Remove ALL of the following:
      - Links and URLs
      - Emoji-prefixed lines
      - Credits, attributions, music credits
      - Target audience mentions (e.g. "for children aged 3-7", "ideal for bedtime")
      - Usage suggestions (e.g. "perfect for evening ritual", "great for learning")
      - Tone/style descriptions (e.g. "gentle pace", "soft voice", "calming")
      - Parent/teacher/listener notes
      - Hashtags
      - Playlist or channel promotions
      - Subscription calls to action
      - Timestamps or chapter markers
      - Social media handles
      - Copyright notices

      Return ONLY the plot summary or content description — 1-3 sentences max.
      If there is no relevant content description, return the title as-is.
      Do not add any commentary, labels, or explanation. Output the cleaned text directly.
    PROMPT
  end

  def generate_system_prompt
    <<~PROMPT
      Generate a brief 1-2 sentence description of this episode based on the transcript.
      Focus on what the episode is about — the story, topic, or main content.
      Write in the same language as the transcript.
      Do not add any commentary, labels, or explanation. Output the description directly.
    PROMPT
  end

  def log_usage(message, elapsed, operation)
    usage = message.usage
    log("Description #{operation} in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
  end

  def log(message)
    if @logger
      @logger.log("[DescriptionAgent] #{message}")
    else
      puts "[DescriptionAgent] #{message}"
    end
  end
end
