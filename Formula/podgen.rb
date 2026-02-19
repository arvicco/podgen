# frozen_string_literal: true

# Homebrew formula template for podgen.
#
# To use this, create a tap repo (e.g. homebrew-podgen) and copy this file
# into Formula/podgen.rb. Update the url and sha256 for each release.
#
# Users install with:
#   brew tap <user>/podgen
#   brew install podgen
#
class Podgen < Formula
  desc "Autonomous podcast generation pipeline"
  homepage "https://github.com/your-user/podgen"
  url "https://github.com/your-user/podgen/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "UPDATE_WITH_ACTUAL_SHA256"
  license "MIT"

  depends_on "ruby"
  depends_on "ffmpeg"

  def install
    ENV["GEM_HOME"] = libexec
    system "gem", "install", *std_gem_args(lib_dir: libexec),
           "--no-document", *Dir["*.gemspec"]

    bin.install Dir["bin/*"]
    bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV["GEM_HOME"])

    # Install supporting scripts (scheduler, test runners)
    (libexec/"scripts").install Dir["scripts/*"]

    # Install assets directory placeholder
    (libexec/"assets").mkpath
  end

  def caveats
    <<~EOS
      podgen requires a project directory with configuration files.

      1. Create a working directory:
         mkdir -p ~/podgen && cd ~/podgen

      2. Create a .env file with your API keys:
         ANTHROPIC_API_KEY=sk-ant-...
         ELEVENLABS_API_KEY=...
         ELEVENLABS_VOICE_ID=...
         EXA_API_KEY=...

      3. Create a podcast:
         mkdir -p podcasts/my_podcast
         # Add guidelines.md and queue.yml (see README)

      4. Drop intro/outro music (optional):
         cp intro.mp3 assets/intro.mp3
         cp outro.mp3 assets/outro.mp3

      5. Run:
         podgen generate my_podcast
    EOS
  end

  test do
    assert_match "podgen #{version}", shell_output("#{bin}/podgen --version")
  end
end
