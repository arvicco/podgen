# frozen_string_literal: true

# Homebrew formula for podgen.
#
# This repo (arvicco/homebrew-podgen) doubles as a Homebrew tap.
# Install with:
#   brew tap arvicco/podgen
#   brew install podgen
#
class Podgen < Formula
  desc "Autonomous podcast generation pipeline"
  homepage "https://github.com/arvicco/homebrew-podgen"
  url "https://github.com/arvicco/homebrew-podgen/archive/refs/tags/v1.8.0.tar.gz"
  sha256 "91f141203d77614a6d3467670ca21500cef4fdfdc94dfd201fc24d3d4da36292"
  license "MIT"

  depends_on "ffmpeg"

  # Optional: cover image generation (language pipeline LingQ upload)
  depends_on "imagemagick" => :recommended
  depends_on "librsvg" => :recommended
  depends_on "fontconfig" => :recommended

  # Ruby 3.2+ required — uses whatever ruby is on PATH (rbenv, asdf, system, etc.)
  # No `depends_on "ruby"` to avoid pulling Homebrew's heavyweight Ruby build.

  def install
    # Install gems into libexec so they don't pollute the system gem path
    ENV["GEM_HOME"] = libexec
    ENV["GEM_PATH"] = libexec

    system "gem", "build", "podgen.gemspec"
    system "gem", "install", "--no-document", "--install-dir", libexec,
           Dir["podgen-*.gem"].first

    # Create a wrapper that sets GEM_HOME/GEM_PATH and PODGEN_ROOT
    (bin/"podgen").write <<~BASH
      #!/bin/bash
      export GEM_HOME="#{libexec}"
      export GEM_PATH="#{libexec}"
      export PODGEN_ROOT="${PODGEN_ROOT:-${PODGEN_HOME:-$HOME/.podgen}}"
      exec ruby "#{libexec}/gems/podgen-#{version}/bin/podgen" "$@"
    BASH
  end

  def post_install
    # Create default project skeleton at ~/.podgen
    podgen_home = Pathname.new(Dir.home) / ".podgen"
    (podgen_home / "podcasts").mkpath
    (podgen_home / "output").mkpath
    (podgen_home / "logs").mkpath

    # Create .env template if it doesn't exist
    env_file = podgen_home / ".env"
    unless env_file.exist?
      env_file.write <<~ENV
        # podgen API keys — fill these in
        ANTHROPIC_API_KEY=
        ELEVENLABS_API_KEY=
        ELEVENLABS_VOICE_ID=
        EXA_API_KEY=
        ELEVENLABS_MODEL_ID=eleven_multilingual_v2
        ELEVENLABS_OUTPUT_FORMAT=mp3_44100_128
        CLAUDE_MODEL=claude-opus-4-6
        # Optional: Bluesky source (free)
        BLUESKY_HANDLE=
        BLUESKY_APP_PASSWORD=
        # Optional: X/Twitter source via SocialData.tools (~$0.01/run)
        SOCIALDATA_API_KEY=
        # Optional: Language pipeline (OpenAI Whisper transcription)
        OPENAI_API_KEY=
      ENV
    end
  end

  def caveats
    <<~EOS
      Requires Ruby 3.2+ on your PATH (via rbenv, asdf, or similar).

      podgen has created a project directory at ~/.podgen

      To get started:
        1. Edit ~/.podgen/.env and add your API keys
        2. Create a podcast:
             mkdir -p ~/.podgen/podcasts/my_podcast
             # Add guidelines.md and queue.yml (see README)
        3. Optionally add intro/outro music:
             cp intro.mp3 ~/.podgen/podcasts/my_podcast/intro.mp3
        4. Generate an episode:
             podgen generate my_podcast

      For per-episode cover images (language pipeline), install a handwriting font:
        brew install --cask font-patrick-hand

      You can also run podgen from any project directory that contains
      a podcasts/ folder, or set $PODGEN_HOME to a custom location.
    EOS
  end

  test do
    assert_match "podgen #{version}", shell_output("#{bin}/podgen --version")
  end
end
