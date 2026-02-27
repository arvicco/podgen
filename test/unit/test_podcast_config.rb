# frozen_string_literal: true

require_relative "../test_helper"
require "podcast_config"

class TestPodcastConfig < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_test")
    @podcasts_dir = File.join(@tmpdir, "podcasts", "myshow")
    @output_dir = File.join(@tmpdir, "output", "myshow")
    FileUtils.mkdir_p(@podcasts_dir)
    FileUtils.mkdir_p(File.join(@output_dir, "episodes"))
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- ## Podcast section (new consolidated format) ---

  def test_parses_podcast_section_name
    write_guidelines(<<~MD)
      ## Podcast
      - name: My Great Show
      - author: Jane Doe

      ## Format
      Short episodes.

      ## Tone
      Casual.

      ## Topics
      - Tech
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "My Great Show", config.title
    assert_equal "Jane Doe", config.author
  end

  def test_parses_podcast_section_type
    write_guidelines(<<~MD)
      ## Podcast
      - name: Lang Show
      - type: language

      ## Format
      Source audio.

      ## Tone
      Educational.
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "language", config.type
  end

  def test_parses_base_url_and_image
    write_guidelines(<<~MD)
      ## Podcast
      - name: Show
      - base_url: https://example.com/show
      - image: cover.jpg

      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "https://example.com/show", config.base_url
    assert_equal "cover.jpg", config.image
  end

  def test_parses_languages_with_voice_ids
    write_guidelines(<<~MD)
      ## Podcast
      - name: Multi Show
      - language:
        - en
        - es: voice_es_123
        - fr: voice_fr_456

      ## Format
      Two segments.

      ## Tone
      Friendly.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    langs = config.languages
    assert_equal 3, langs.length
    assert_equal({ "code" => "en" }, langs[0])
    assert_equal({ "code" => "es", "voice_id" => "voice_es_123" }, langs[1])
    assert_equal({ "code" => "fr", "voice_id" => "voice_fr_456" }, langs[2])
  end

  def test_defaults_when_podcast_section_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "myshow", config.title  # falls back to dir name
    assert_equal "Podcast Agent", config.author
    assert_equal "news", config.type
    assert_nil config.base_url
    assert_nil config.image
    assert_equal [{ "code" => "en" }], config.languages
  end

  # --- ## Sources section ---

  def test_parses_flat_sources
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - exa
      - hackernews
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "exa" => true, "hackernews" => true }, config.sources)
  end

  def test_parses_sources_with_nested_urls
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed1.xml
        - https://example.com/feed2.xml
      - hackernews
    MD

    config = PodcastConfig.new("myshow")
    expected = {
      "rss" => ["https://example.com/feed1.xml", "https://example.com/feed2.xml"],
      "hackernews" => true
    }
    assert_equal expected, config.sources
  end

  def test_parses_inline_comma_sources
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - x: @user1, @user2
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "x" => ["@user1", "@user2"] }, config.sources)
  end

  def test_parses_rss_with_skip_and_cut
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed1 skip: 38 cut: 10
        - https://example.com/feed2
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal 2, feeds.length
    assert_equal({ url: "https://example.com/feed1", skip: 38.0, cut: 10.0 }, feeds[0])
    assert_equal "https://example.com/feed2", feeds[1]
  end

  def test_parses_rss_with_skip_only
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed skip: 27
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal [{ url: "https://example.com/feed", skip: 27.0 }], feeds
  end

  def test_parses_rss_with_cut_only
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed cut: 15
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal [{ url: "https://example.com/feed", cut: 15.0 }], feeds
  end

  def test_parses_rss_with_autotrim
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed skip: 30 autotrim: true
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal [{ url: "https://example.com/feed", skip: 30.0, autotrim: true }], feeds
  end

  def test_parses_rss_with_bare_autotrim
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed skip: 38 autotrim
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal [{ url: "https://example.com/feed", skip: 38.0, autotrim: true }], feeds
  end

  def test_parses_audio_bare_autotrim
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Audio
      - engine:
        - open
        - groq
      - language: sl
      - autotrim
    MD

    config = PodcastConfig.new("myshow")
    assert_equal true, config.autotrim
  end

  def test_defaults_to_exa_when_sources_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "exa" => true }, config.sources)
  end

  # --- ## Audio section ---

  def test_parses_audio_engines
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Audio
      - engine:
        - open
        - groq
      - language: sl
      - target_language: Slovenian
      - skip: 30.5
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open", "groq"], config.transcription_engines
    assert_equal "sl", config.transcription_language
    assert_equal "Slovenian", config.target_language
    assert_in_delta 30.5, config.skip
  end

  def test_parses_audio_autotrim
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Audio
      - engine:
        - open
        - groq
      - language: sl
      - autotrim: true
    MD

    config = PodcastConfig.new("myshow")
    assert_equal true, config.autotrim
  end

  def test_audio_defaults
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open"], config.transcription_engines
    assert_nil config.transcription_language
    assert_nil config.target_language
    assert_nil config.skip
    assert_nil config.autotrim
  end

  # --- Legacy format fallback ---

  def test_legacy_name_and_type_sections
    write_guidelines(<<~MD)
      ## Name
      Legacy Show

      ## Type
      language

      ## Format
      Source audio.

      ## Tone
      Clear.
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "Legacy Show", config.title
    assert_equal "language", config.type
  end

  def test_legacy_language_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Language
      - en
      - it: voice_it_789
    MD

    config = PodcastConfig.new("myshow")
    langs = config.languages
    assert_equal 2, langs.length
    assert_equal({ "code" => "en" }, langs[0])
    assert_equal({ "code" => "it", "voice_id" => "voice_it_789" }, langs[1])
  end

  def test_legacy_transcription_engine_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Transcription Engine
      - open
      - elab
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open", "elab"], config.transcription_engines
  end

  # --- episode_basename ---

  def test_episode_basename_first_run
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "myshow-2026-03-01", config.episode_basename(Date.new(2026, 3, 1))
  end

  def test_episode_basename_suffix_generation
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    # Create a fake first episode MP3
    eps_dir = File.join(@output_dir, "episodes")
    File.write(File.join(eps_dir, "myshow-2026-03-01.mp3"), "x")

    config = PodcastConfig.new("myshow")
    assert_equal "myshow-2026-03-01a", config.episode_basename(Date.new(2026, 3, 1))
  end

  def test_episode_basename_ignores_language_suffixed_files
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    eps_dir = File.join(@output_dir, "episodes")
    File.write(File.join(eps_dir, "myshow-2026-03-01.mp3"), "x")
    File.write(File.join(eps_dir, "myshow-2026-03-01-es.mp3"), "x")
    File.write(File.join(eps_dir, "myshow-2026-03-01-fr.mp3"), "x")

    config = PodcastConfig.new("myshow")
    # Only the base mp3 counts, not the language-suffixed ones
    assert_equal "myshow-2026-03-01a", config.episode_basename(Date.new(2026, 3, 1))
  end

  # --- ## Image section ---

  def test_cover_reads_from_image_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - cover: artwork.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "artwork.jpg", config.cover
  end

  def test_cover_falls_back_to_podcast_image
    write_guidelines(<<~MD)
      ## Podcast
      - name: Show
      - image: cover.jpg

      ## Format
      Short.

      ## Tone
      Fun.
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "cover.jpg", config.cover
  end

  def test_image_delegates_to_cover
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - cover: new_cover.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "new_cover.jpg", config.image
  end

  def test_image_section_overrides_podcast_image
    write_guidelines(<<~MD)
      ## Podcast
      - name: Show
      - image: old.jpg

      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - cover: new.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "new.jpg", config.cover
    assert_equal "new.jpg", config.image
  end

  def test_cover_base_image_from_image_section
    # Create a base image file so the path resolves
    File.write(File.join(@podcasts_dir, "base.jpg"), "x")

    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - base_image: base.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert_equal File.join(@podcasts_dir, "base.jpg"), config.cover_base_image
  end

  def test_cover_base_image_falls_back_to_lingq
    File.write(File.join(@podcasts_dir, "lingq_base.jpg"), "x")

    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## LingQ
      - collection: 123
      - base_image: lingq_base.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert_equal File.join(@podcasts_dir, "lingq_base.jpg"), config.cover_base_image
  end

  def test_cover_options_from_image_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - font: Noto Sans
      - font_color: white
      - font_size: 72
      - text_width: 900
      - text_gravity: south
      - text_x_offset: 10
      - text_y_offset: 50
    MD

    config = PodcastConfig.new("myshow")
    opts = config.cover_options
    assert_equal "Noto Sans", opts[:font]
    assert_equal "white", opts[:font_color]
    assert_equal 72, opts[:font_size]
    assert_equal 900, opts[:text_width]
    assert_equal "south", opts[:gravity]
    assert_equal 10, opts[:x_offset]
    assert_equal 50, opts[:y_offset]
  end

  def test_cover_options_falls_back_to_lingq
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## LingQ
      - collection: 123
      - font: Patrick Hand
      - font_color: #2B3A67
      - font_size: 126
    MD

    config = PodcastConfig.new("myshow")
    opts = config.cover_options
    assert_equal "Patrick Hand", opts[:font]
    assert_equal "#2B3A67", opts[:font_color]
    assert_equal 126, opts[:font_size]
  end

  def test_cover_generation_enabled_from_image_section
    File.write(File.join(@podcasts_dir, "base.jpg"), "x")

    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - base_image: base.jpg
    MD

    config = PodcastConfig.new("myshow")
    assert config.cover_generation_enabled?
  end

  def test_cover_generation_disabled_when_no_base_image
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Image
      - cover: artwork.jpg
    MD

    config = PodcastConfig.new("myshow")
    refute config.cover_generation_enabled?
  end

  def test_parses_rss_with_per_feed_image_options
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Sources
      - rss:
        - https://example.com/feed base_image: cover.jpg
        - https://example.com/feed2 image: none
    MD

    config = PodcastConfig.new("myshow")
    feeds = config.sources["rss"]
    assert_equal 2, feeds.length
    assert_equal "https://example.com/feed", feeds[0][:url]
    assert_equal File.join(@podcasts_dir, "cover.jpg"), feeds[0][:base_image]
    assert_equal "https://example.com/feed2", feeds[1][:url]
    assert_equal "none", feeds[1][:image]
  end

  # --- LingQ section ---

  def test_parses_lingq_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## LingQ
      - collection: 12345
      - level: 3
      - tags: podcast, slovenian
      - accent: sl-SI
      - status: new
    MD

    config = PodcastConfig.new("myshow")
    lc = config.lingq_config
    refute_nil lc
    assert_equal 12345, lc[:collection]
    assert_equal 3, lc[:level]
    assert_equal ["podcast", "slovenian"], lc[:tags]
    assert_equal "sl-SI", lc[:accent]
    assert_equal "new", lc[:status]
  end

  def test_lingq_nil_when_section_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_nil config.lingq_config
  end

  private

  def write_guidelines(content)
    File.write(File.join(@podcasts_dir, "guidelines.md"), content)
  end
end
