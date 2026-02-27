# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "optparse"

# Load CLI dispatcher + all commands
require "cli"
require "cli/generate_command"
require "cli/publish_command"
require "cli/translate_command"
require "cli/stats_command"
require "cli/validate_command"
require "cli/scrap_command"
require "cli/rss_command"

class TestCLIOptions < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cli_test")
    build_test_podcast(@tmpdir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Invalid options should fail with exit 2 ──────────────────────

  def test_generate_rejects_unknown_option
    code, _, err = run_cli("generate", "test_pod", "--bogus")
    assert_equal 2, code
    assert_includes err, "invalid option: --bogus"
  end

  def test_publish_rejects_unknown_option
    code, _, err = run_cli("publish", "test_pod", "--lingk")
    assert_equal 2, code
    assert_includes err, "invalid option: --lingk"
  end

  def test_translate_rejects_unknown_option
    code, _, err = run_cli("translate", "test_pod", "--langs")
    assert_equal 2, code
    assert_includes err, "invalid option: --langs"
  end

  def test_stats_rejects_unknown_option
    code, _, err = run_cli("stats", "test_pod", "--everything")
    assert_equal 2, code
    assert_includes err, "invalid option: --everything"
  end

  def test_validate_rejects_unknown_option
    code, _, err = run_cli("validate", "test_pod", "--verbose-all")
    assert_equal 2, code
    assert_includes err, "invalid option: --verbose-all"
  end

  def test_rss_rejects_unknown_option
    code, _, err = run_cli("rss", "test_pod", "--format")
    assert_equal 2, code
    assert_includes err, "invalid option: --format"
  end

  def test_rss_rejects_missing_argument
    code, _, err = run_cli("rss", "test_pod", "--base-url")
    assert_equal 2, code
    assert_includes err, "missing argument: --base-url"
  end

  def test_global_rejects_unknown_option
    code, _, err = run_cli("--bogus", "generate", "test_pod")
    assert_equal 2, code
    assert_includes err, "invalid option: --bogus"
  end

  # ── Typos near valid options should fail ─────────────────────────

  def test_publish_lingq_typo
    code, _, err = run_cli("publish", "test_pod", "--lingk")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end

  def test_generate_dry_run_typo
    code, _, err = run_cli("generate", "test_pod", "--dryrun")
    assert_equal 2, code
    assert_includes err, "invalid option"
  end

  # ── Valid options should be accepted ─────────────────────────────

  def test_generate_accepts_dry_run
    code, _, _ = run_cli("--dry-run", "generate", "test_pod")
    assert_equal 0, code
  end

  def test_generate_accepts_skip_and_cut
    cmd = PodgenCLI::GenerateCommand.new(
      ["--skip", "5", "--cut", "10", "test_pod"],
      { dry_run: true }
    )
    assert_equal 5.0, cmd.instance_variable_get(:@options)[:skip]
    assert_equal 10.0, cmd.instance_variable_get(:@options)[:cut]
  end

  def test_generate_accepts_long_form_skip_and_cut
    cmd = PodgenCLI::GenerateCommand.new(
      ["--skip-intro", "3", "--cut-outro", "7", "test_pod"],
      { dry_run: true }
    )
    assert_equal 3.0, cmd.instance_variable_get(:@options)[:skip]
    assert_equal 7.0, cmd.instance_variable_get(:@options)[:cut]
  end

  def test_publish_accepts_lingq
    cmd = PodgenCLI::PublishCommand.new(["--lingq", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:lingq]
  end

  def test_publish_accepts_dry_run
    cmd = PodgenCLI::PublishCommand.new(["--dry-run", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:dry_run]
  end

  def test_translate_accepts_last_and_lang
    cmd = PodgenCLI::TranslateCommand.new(
      ["--last", "3", "--lang", "it", "test_pod"], {}
    )
    assert_equal 3, cmd.instance_variable_get(:@last_n)
    assert_equal "it", cmd.instance_variable_get(:@lang_filter)
  end

  def test_translate_accepts_dry_run
    cmd = PodgenCLI::TranslateCommand.new(["--dry-run", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:dry_run]
  end

  def test_stats_accepts_all
    cmd = PodgenCLI::StatsCommand.new(["--all"], {})
    assert_equal true, cmd.instance_variable_get(:@all)
  end

  def test_validate_accepts_all
    cmd = PodgenCLI::ValidateCommand.new(["--all"], {})
    assert_equal true, cmd.instance_variable_get(:@all)
  end

  def test_rss_accepts_base_url
    cmd = PodgenCLI::RssCommand.new(["--base-url", "https://example.com", "test_pod"], {})
    assert_equal "https://example.com", cmd.instance_variable_get(:@options)[:base_url]
  end

  # ── Generate language pipeline flags ─────────────────────────────

  def test_generate_accepts_file_flag
    cmd = PodgenCLI::GenerateCommand.new(["--file", "/tmp/test.mp3", "test_pod"], {})
    assert_equal "/tmp/test.mp3", cmd.instance_variable_get(:@options)[:file]
  end

  def test_generate_accepts_url_flag
    cmd = PodgenCLI::GenerateCommand.new(["--url", "https://youtube.com/watch?v=abc", "test_pod"], {})
    assert_equal "https://youtube.com/watch?v=abc", cmd.instance_variable_get(:@options)[:url]
  end

  def test_generate_accepts_title_flag
    cmd = PodgenCLI::GenerateCommand.new(["--title", "My Episode", "test_pod"], {})
    assert_equal "My Episode", cmd.instance_variable_get(:@options)[:title]
  end

  def test_generate_accepts_image_flags
    cmd = PodgenCLI::GenerateCommand.new(
      ["--image", "/tmp/cover.jpg", "--base-image", "/tmp/base.jpg", "test_pod"], {}
    )
    assert_equal "/tmp/cover.jpg", cmd.instance_variable_get(:@options)[:image]
    assert_equal "/tmp/base.jpg", cmd.instance_variable_get(:@options)[:base_image]
  end

  def test_generate_accepts_lingq_flag
    cmd = PodgenCLI::GenerateCommand.new(["--lingq", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:lingq]
  end

  def test_generate_accepts_autotrim_flag
    cmd = PodgenCLI::GenerateCommand.new(["--autotrim", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:autotrim]
  end

  def test_generate_accepts_force_flag
    cmd = PodgenCLI::GenerateCommand.new(["--force", "test_pod"], {})
    assert_equal true, cmd.instance_variable_get(:@options)[:force]
  end

  # ── Unknown command should fail ──────────────────────────────────

  def test_unknown_command_fails
    code, _, err = run_cli("frobnicate", "test_pod")
    assert_equal 2, code
    assert_includes err, "Unknown command: frobnicate"
  end

  def test_no_command_shows_help
    code, out, _ = run_cli
    assert_equal 2, code
    assert_includes out, "Usage:"
  end

  private

  def run_cli(*args)
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    code = PodgenCLI.run(args.flatten)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def build_test_podcast(dir)
    pod = File.join(dir, "podcasts", "test_pod")
    out = File.join(dir, "output", "test_pod", "episodes")
    FileUtils.mkdir_p([pod, out])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Test Pod

      ## Format
      - Short episodes

      ## Tone
      Casual.

      ## Topics
      - Testing
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => ["testing"]))
  end
end
