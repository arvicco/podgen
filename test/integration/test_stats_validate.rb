# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "yaml"
require "cli/stats_command"
require "cli/validate_command"

class TestStatsValidate < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_sv_test")
    build_fixtures(@tmpdir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Stats ────────────────────────────────────────────────────────

  def test_stats_news_podcast
    code, out, = run_stats(["test_news"], :normal)
    assert_equal 0, code
    assert_includes out, "Test News"
    assert_match(/Episodes:\s+2/, out)
    assert_includes out, "https://example.com/test_news"
  end

  def test_stats_verbose_lists_episodes
    code, out, = run_stats(["test_news"], :verbose)
    assert_equal 0, code
    assert_includes out, "test_news-2026-01-15.mp3"
    assert_includes out, "test_news-2026-01-20.mp3"
    assert_match(/Research cache.*1 file/, out)
    assert_match(/History.*2 entries.*2 unique topics/, out)
  end

  def test_stats_language_pipeline
    code, out, = run_stats(["test_lang"], :verbose)
    assert_equal 0, code
    assert_includes out, "language"
    assert_match(/Tails.*1 file/, out)
  end

  def test_stats_all_table
    code, out, = run_stats(["--all"], :normal)
    assert_equal 0, code
    assert_includes out, "Podcast"
    assert_includes out, "Episodes"
    assert_includes out, "test_news"
    assert_includes out, "test_lang"
    assert_includes out, "test_multi"
    assert_includes out, "test_empty"
    assert_includes out, "test_broken"
  end

  def test_stats_empty_podcast
    code, out, = run_stats(["test_empty"], :normal)
    assert_equal 0, code
    assert_match(/Episodes:\s+0/, out)
    assert_includes out, "not generated"
  end

  def test_stats_no_args_shows_usage
    code, _, err = run_stats([], :normal)
    assert_equal 2, code
    assert_includes err, "Usage:"
  end

  # ── Validate ─────────────────────────────────────────────────────

  def test_validate_clean_news_podcast
    code, out, = run_validate(["test_news"], :verbose)
    assert_equal 0, code
    assert_includes out, "0 errors"
    assert_includes out, "0 warning"
    assert_includes out, "Guidelines: all required sections present"
    assert_match(/Episodes: 2 MP3/, out)
    assert_match(/Transcripts: 2\/2/, out)
    assert_match(/Feed: well-formed XML, 2 episodes/, out)
    assert_match(/Cover:.*cover\.jpg/, out)
    assert_includes out, "Base URL:"
    assert_match(/History: 2 entries/, out)
    assert_includes out, "News: queue.yml present"
  end

  def test_validate_language_pipeline
    code, out, = run_validate(["test_lang"], :verbose)
    assert_equal 0, code
    assert_includes out, "open, elab, groq"
    assert_includes out, "0 errors"
  end

  def test_validate_multi_language_warns
    code, out, = run_validate(["test_multi"], :normal)
    assert_equal 1, code
    assert_includes out, "feed-ja.xml"
  end

  def test_validate_broken_podcast_errors
    code, out, = run_validate(["test_broken"], :verbose)
    assert_equal 2, code
    # Errors
    assert_includes out, "missing required sections"
    assert_includes out, "does not start with http"
    assert_match(/Cover:.*not found/, out)
    assert_includes out, "zero-byte"
    # Warnings
    assert_includes out, "unexpected naming"
    assert_includes out, "unknown_source"
    assert_match(/Orphans:.*transcript/, out)
    assert_includes out, "_concat"
    assert_includes out, "feed.xml not found"
    assert_includes out, "history.yml not found"
    assert_includes out, "queue.yml not found"
  end

  def test_validate_empty_podcast_warnings_only
    code, out, = run_validate(["test_empty"], :verbose)
    assert_equal 1, code
    assert_includes out, "Guidelines: all required sections present"
    assert_includes out, "directory not found"
    assert_includes out, "feed.xml not found"
    assert_includes out, "no image configured"
    assert_includes out, "history.yml not found"
    assert_includes out, "0 errors"
  end

  def test_validate_quiet_suppresses_output
    code, out, = run_validate(["test_broken"], :quiet)
    assert_equal 2, code
    assert out.strip.empty?, "Quiet mode should suppress output"
  end

  def test_validate_verbose_shows_pass_markers
    _, out, = run_validate(["test_news"], :verbose)
    pass_lines = out.lines.count { |l| l.include?("\u2713") }
    assert pass_lines >= 6, "Expected >=6 pass markers, got #{pass_lines}"
  end

  def test_validate_normal_hides_pass_markers
    _, out, = run_validate(["test_news"], :normal)
    pass_lines = out.lines.count { |l| l.include?("\u2713") }
    assert_equal 0, pass_lines
  end

  def test_validate_all_returns_worst_exit
    code, = run_validate(["--all"], :quiet)
    assert_equal 2, code
  end

  def test_validate_no_args_shows_usage
    code, _, err = run_validate([], :normal)
    assert_equal 2, code
    assert_includes err, "Usage:"
  end

  # ── Format helpers ───────────────────────────────────────────────

  def test_stats_format_size
    cmd = PodgenCLI::StatsCommand.new([], verbosity: :normal)
    assert_equal "0 B",    cmd.send(:format_size, 0)
    assert_equal "500 B",  cmd.send(:format_size, 500)
    assert_equal "1 KB",   cmd.send(:format_size, 1_000)
    assert_equal "2 MB",   cmd.send(:format_size, 1_500_000)
    assert_equal "2.5 GB", cmd.send(:format_size, 2_500_000_000)
  end

  def test_stats_format_duration
    cmd = PodgenCLI::StatsCommand.new([], verbosity: :normal)
    assert_equal "0m",      cmd.send(:format_duration, 0)
    assert_equal "1m",      cmd.send(:format_duration, 90)
    assert_equal "1h 0m",   cmd.send(:format_duration, 3600)
    assert_equal "1h 30m",  cmd.send(:format_duration, 5432)
  end

  def test_stats_format_duration_short
    cmd = PodgenCLI::StatsCommand.new([], verbosity: :normal)
    assert_equal "0:00",  cmd.send(:format_duration_short, 0)
    assert_equal "1:05",  cmd.send(:format_duration_short, 65)
    assert_equal "10:00", cmd.send(:format_duration_short, 600)
  end

  def test_stats_truncate
    cmd = PodgenCLI::StatsCommand.new([], verbosity: :normal)
    assert_equal "hello",    cmd.send(:truncate, "hello", 10)
    assert_equal "hello",    cmd.send(:truncate, "hello", 5)
    assert_equal "hello w\u2026", cmd.send(:truncate, "hello world", 8)
    assert_equal "\u2026",   cmd.send(:truncate, "ab", 1)
  end

  def test_validate_format_size
    cmd = PodgenCLI::ValidateCommand.new([], verbosity: :normal)
    assert_equal "1.5 MB", cmd.send(:format_size, 1_500_000)
    assert_equal "999 B",  cmd.send(:format_size, 999)
  end

  private

  def run_stats(args, verbosity)
    capture_command { PodgenCLI::StatsCommand.new(args, verbosity: verbosity).run }
  end

  def run_validate(args, verbosity)
    capture_command { PodgenCLI::ValidateCommand.new(args, verbosity: verbosity).run }
  end

  def capture_command
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    result = yield
    [result, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def fake_file(path, content = "content")
    File.write(path, content)
  end

  # ── Fixture builders ─────────────────────────────────────────────

  def build_fixtures(dir)
    build_news_podcast(dir)
    build_language_podcast(dir)
    build_multi_language_podcast(dir)
    build_broken_podcast(dir)
    build_empty_podcast(dir)
  end

  def build_news_podcast(dir)
    pod = File.join(dir, "podcasts", "test_news")
    out = File.join(dir, "output", "test_news")
    eps = File.join(out, "episodes")
    FileUtils.mkdir_p([pod, eps, File.join(out, "research_cache")])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      # Podcast Guidelines

      ## Podcast
      - name: Test News
      - author: Test Author
      - base_url: https://example.com/test_news
      - image: cover.jpg

      ## Format
      - Target length: 10 minutes

      ## Tone
      Conversational and direct.

      ## Topics
      - Technology news
      - Science updates

      ## Sources
      - exa
      - hackernews
      - rss:
        - https://example.com/feed1.xml
        - https://example.com/feed2.xml
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => %w[tech science]))
    fake_file(File.join(pod, "cover.jpg"), "x" * 50_000)
    fake_file(File.join(out, "cover.jpg"), "x" * 50_000)

    fake_file(File.join(eps, "test_news-2026-01-15.mp3"), "x" * 5_000_000)
    fake_file(File.join(eps, "test_news-2026-01-15_script.md"), "# Episode 1")
    fake_file(File.join(eps, "test_news-2026-01-15_script.html"), "<h1>Episode 1</h1>")
    fake_file(File.join(eps, "test_news-2026-01-20.mp3"), "x" * 6_000_000)
    fake_file(File.join(eps, "test_news-2026-01-20_script.md"), "# Episode 2")
    fake_file(File.join(eps, "test_news-2026-01-20_script.html"), "<h1>Episode 2</h1>")

    fake_file(File.join(out, "research_cache", "abc123.json"), '{"data":"cached"}')

    File.write(File.join(out, "history.yml"), YAML.dump([
      { "date" => "2026-01-15", "title" => "Episode 1", "topics" => ["tech"] },
      { "date" => "2026-01-20", "title" => "Episode 2", "topics" => ["science"] }
    ]))

    File.write(File.join(out, "feed.xml"), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Test News</title>
        <item><title>Episode 1</title></item>
        <item><title>Episode 2</title></item>
      </channel></rss>
    XML
  end

  def build_language_podcast(dir)
    pod = File.join(dir, "podcasts", "test_lang")
    out = File.join(dir, "output", "test_lang")
    eps = File.join(out, "episodes")
    tails = File.join(out, "tails")
    FileUtils.mkdir_p([pod, eps, tails])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      # Podcast Guidelines

      ## Podcast
      - name: Test Lang
      - type: language
      - base_url: https://example.com/test_lang
      - image: cover.jpg

      ## Format
      - Source audio with intro/outro stripped

      ## Tone
      Clear and educational.

      ## Sources
      - rss:
        - https://example.com/lang_feed.xml

      ## Audio
      - engine:
        - open
        - elab
        - groq
      - language: sl
      - target_language: Slovenian
      - skip: 30
      - autotrim: true
    MD

    fake_file(File.join(pod, "cover.jpg"), "x" * 80_000)
    fake_file(File.join(out, "cover.jpg"), "x" * 80_000)

    fake_file(File.join(eps, "test_lang-2026-01-10.mp3"), "x" * 4_000_000)
    fake_file(File.join(eps, "test_lang-2026-01-10_transcript.md"), "Transcript")
    fake_file(File.join(eps, "test_lang-2026-01-10_transcript.html"), "<p>Transcript</p>")
    fake_file(File.join(tails, "test_lang-2026-01-10_tail.mp3"), "x" * 500_000)

    File.write(File.join(out, "history.yml"), YAML.dump([
      { "date" => "2026-01-10", "title" => "Lang Episode 1", "topics" => ["stories"] }
    ]))

    File.write(File.join(out, "feed.xml"), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Test Lang</title>
        <item><title>Lang Episode 1</title></item>
      </channel></rss>
    XML
  end

  def build_multi_language_podcast(dir)
    pod = File.join(dir, "podcasts", "test_multi")
    out = File.join(dir, "output", "test_multi")
    eps = File.join(out, "episodes")
    FileUtils.mkdir_p([pod, eps])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      # Podcast Guidelines

      ## Podcast
      - name: Test Multi
      - author: Multi Author
      - base_url: https://example.com/test_multi
      - image: cover.jpg
      - language:
        - en
        - ja: voice123

      ## Format
      - Two segments

      ## Tone
      Friendly.

      ## Topics
      - Multilingual news

      ## Sources
      - exa
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => ["news"]))
    fake_file(File.join(pod, "cover.jpg"), "x" * 60_000)
    fake_file(File.join(out, "cover.jpg"), "x" * 60_000)

    fake_file(File.join(eps, "test_multi-2026-02-01.mp3"), "x" * 5_000_000)
    fake_file(File.join(eps, "test_multi-2026-02-01-ja.mp3"), "x" * 5_500_000)
    fake_file(File.join(eps, "test_multi-2026-02-01_script.md"), "# Multi 1")
    fake_file(File.join(eps, "test_multi-2026-02-01_script.html"), "<h1>Multi 1</h1>")

    File.write(File.join(out, "history.yml"), YAML.dump([
      { "date" => "2026-02-01", "title" => "Multi Episode 1", "topics" => ["news"] }
    ]))

    File.write(File.join(out, "feed.xml"), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Test Multi</title>
        <item><title>Multi Episode 1</title></item>
      </channel></rss>
    XML
  end

  def build_broken_podcast(dir)
    pod = File.join(dir, "podcasts", "test_broken")
    out = File.join(dir, "output", "test_broken")
    eps = File.join(out, "episodes")
    FileUtils.mkdir_p([pod, eps])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      # Podcast Guidelines

      ## Podcast
      - name: Test Broken
      - base_url: ftp://bad-protocol.com/broken
      - image: missing.jpg

      ## Tone
      Whatever.

      ## Sources
      - exa
      - unknown_source
    MD

    File.write(File.join(eps, "test_broken-2026-01-01.mp3"), "")
    fake_file(File.join(eps, "random_name.mp3"), "x" * 100_000)
    fake_file(File.join(eps, "deleted_episode_script.md"), "orphan")
    fake_file(File.join(eps, "deleted_episode_script.html"), "orphan")
    fake_file(File.join(eps, "test_broken-2026-01-01_concat.mp3"), "stale")
  end

  def build_empty_podcast(dir)
    pod = File.join(dir, "podcasts", "test_empty")
    FileUtils.mkdir_p(pod)

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      # Podcast Guidelines

      ## Podcast
      - name: Test Empty
      - base_url: https://example.com/test_empty

      ## Format
      - Short episodes

      ## Tone
      Casual.

      ## Topics
      - General news
    MD
  end
end
