# frozen_string_literal: true

require "open3"
require "json"
require "tmpdir"

class YouTubeDownloader
  DEFAULT_BROWSER = "chrome"

  def initialize(logger: nil)
    @logger = logger
    @verified = false
    @browser = ENV.fetch("YOUTUBE_BROWSER", DEFAULT_BROWSER)
  end

  # Returns { id:, title:, description:, duration:, url:, uploader:, thumbnail: }
  def fetch_metadata(url)
    verify_yt_dlp!
    log("Fetching metadata: #{url}")
    stdout, stderr, status = Open3.capture3(
      "yt-dlp", *cookies_args, "--dump-json", "--no-playlist", url
    )
    raise "yt-dlp metadata failed: #{stderr.strip}" unless status.success?

    data = JSON.parse(stdout)
    canonical_url = data["webpage_url"] || url

    {
      id: data["id"],
      title: data["title"],
      description: data["description"].to_s[0, 2000],
      duration: data["duration"],
      url: canonical_url,
      uploader: data["uploader"],
      thumbnail: data["thumbnail"]
    }
  end

  # Downloads the video thumbnail. Returns temp file path or nil on failure.
  def download_thumbnail(url)
    verify_yt_dlp!
    path = File.join(Dir.tmpdir, "podgen_thumb_#{Process.pid}.%(ext)s")

    log("Downloading thumbnail: #{url}")
    _stdout, stderr, status = Open3.capture3(
      "yt-dlp", *cookies_args,
      "--write-thumbnail", "--skip-download",
      "--convert-thumbnails", "jpg",
      "--no-playlist",
      "-o", path,
      url
    )

    unless status.success?
      log("Thumbnail download failed (non-fatal): #{stderr.strip}")
      return nil
    end

    # yt-dlp writes thumbnail as the output path with image extension
    thumb = Dir.glob(File.join(Dir.tmpdir, "podgen_thumb_#{Process.pid}.{jpg,webp,png}")).first
    unless thumb && File.exist?(thumb) && File.size(thumb) > 0
      log("Thumbnail file not found after download (non-fatal)")
      return nil
    end

    log("Downloaded thumbnail: #{(File.size(thumb) / 1024.0).round(1)} KB")
    thumb
  rescue => e
    log("Thumbnail download error (non-fatal): #{e.message}")
    nil
  end

  # Downloads audio as MP3, returns temp file path
  def download_audio(url)
    output_template = File.join(Dir.tmpdir, "podgen_yt_#{Process.pid}.%(ext)s")
    expected_path = File.join(Dir.tmpdir, "podgen_yt_#{Process.pid}.mp3")

    log("Downloading audio: #{url}")
    _stdout, stderr, status = Open3.capture3(
      "yt-dlp", *cookies_args,
      "-x", "--audio-format", "mp3",
      "--no-playlist",
      "-o", output_template,
      url
    )
    raise "yt-dlp download failed: #{stderr.strip}" unless status.success?
    raise "Downloaded file not found: #{expected_path}" unless File.exist?(expected_path)
    raise "Downloaded file is empty" unless File.size(expected_path) > 0

    log("Downloaded: #{(File.size(expected_path) / (1024.0 * 1024)).round(2)} MB")
    expected_path
  end

  # Fetches auto-captions or manual subs for the given language.
  # Returns plain text (SRT timestamps stripped) or nil on any error.
  def fetch_captions(url, language:)
    Dir.mktmpdir("podgen_subs") do |dir|
      output_template = File.join(dir, "subs")

      _stdout, _stderr, status = Open3.capture3(
        "yt-dlp", *cookies_args,
        "--write-auto-subs", "--write-subs",
        "--sub-lang", language,
        "--sub-format", "srt",
        "--skip-download",
        "--no-playlist",
        "-o", output_template,
        url
      )

      unless status.success?
        log("Caption fetch failed (non-fatal)")
        return nil
      end

      # Find the downloaded subtitle file
      sub_file = Dir.glob(File.join(dir, "subs*.srt")).first
      unless sub_file
        log("No captions found for language '#{language}'")
        return nil
      end

      srt_content = File.read(sub_file, encoding: "UTF-8")
      text = strip_srt_timestamps(srt_content)

      if text.empty?
        log("Captions file was empty")
        return nil
      end

      log("Fetched captions: #{text.length} chars (#{language})")
      text
    end
  rescue => e
    log("Caption fetch error (non-fatal): #{e.message}")
    nil
  end

  private

  def cookies_args
    ["--cookies-from-browser", @browser]
  end

  def strip_srt_timestamps(srt)
    srt.lines
      .reject { |line| line.strip =~ /^\d+$/ }                          # sequence numbers
      .reject { |line| line.strip =~ /^\d{2}:\d{2}:\d{2}[.,]\d{3}\s*-->/ } # timestamp lines
      .map(&:strip)
      .reject(&:empty?)
      .join(" ")
      .gsub(/\s+/, " ")
      .strip
  end

  def verify_yt_dlp!
    return if @verified

    _out, _err, status = Open3.capture3("yt-dlp", "--version")
    unless status.success?
      raise "yt-dlp is not working correctly. Install with: brew install yt-dlp"
    end
    @verified = true
  rescue Errno::ENOENT
    raise "yt-dlp is not installed or not on $PATH. Install with: brew install yt-dlp"
  end

  def log(message)
    if @logger
      @logger.log("[YouTubeDownloader] #{message}")
    else
      puts "[YouTubeDownloader] #{message}"
    end
  end
end
