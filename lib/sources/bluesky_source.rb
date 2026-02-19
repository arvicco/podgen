# frozen_string_literal: true

require "httparty"
require "set"
require "json"

class BlueskySource
  MAX_RETRIES = 2
  RESULTS_PER_TOPIC = 5
  PDS_HOST = "https://bsky.social"
  SEARCH_ENDPOINT = "/xrpc/app.bsky.feed.searchPosts"
  SESSION_ENDPOINT = "/xrpc/com.atproto.server.createSession"

  def initialize(logger: nil, **_options)
    @logger = logger
    @handle = ENV["BLUESKY_HANDLE"]
    @app_password = ENV["BLUESKY_APP_PASSWORD"]
    @access_token = nil
  end

  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics, exclude_urls: Set.new)
    unless @handle && @app_password
      log("BLUESKY_HANDLE or BLUESKY_APP_PASSWORD not set, skipping Bluesky source")
      return topics.map { |t| { topic: t, findings: [] } }
    end

    authenticate!

    topics.map do |topic|
      log("Searching Bluesky: #{topic}")
      start = Time.now
      findings = search_topic(topic, exclude_urls)
      elapsed = (Time.now - start).round(2)
      log("Bluesky found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def authenticate!
    response = HTTParty.post(
      "#{PDS_HOST}#{SESSION_ENDPOINT}",
      headers: { "Content-Type" => "application/json" },
      body: { identifier: @handle, password: @app_password }.to_json,
      timeout: 15
    )

    unless response.success?
      error = response.parsed_response
      raise "Bluesky auth failed: #{error['message'] || response.code}"
    end

    @access_token = response.parsed_response["accessJwt"]
    log("Authenticated as #{@handle}")
  end

  def search_topic(topic, exclude_urls)
    response = request_with_retry(
      q: topic,
      limit: RESULTS_PER_TOPIC * 2,
      sort: "latest"
    )

    return [] unless response && response["posts"]

    response["posts"].filter_map do |post|
      record = post["record"] || {}
      text = record["text"].to_s.strip
      next if text.empty?

      author = post.dig("author", "handle") || "unknown"
      uri = post["uri"].to_s

      # Build web URL from AT URI: at://did:plc:xxx/app.bsky.feed.post/yyy
      post_url = at_uri_to_url(uri, author)
      next if exclude_urls.include?(post_url)

      # Use first line or first 120 chars as title
      title = text.lines.first.to_s.strip
      title = "#{title[0, 117]}..." if title.length > 120

      # Full text as summary, capped at 500 chars
      summary = text.length > 500 ? "#{text[0, 497]}..." : text

      like_count = post["likeCount"] || 0
      repost_count = post["repostCount"] || 0
      summary = "#{summary} [#{like_count} likes, #{repost_count} reposts on Bluesky]"

      {
        title: "@#{author}: #{title}",
        url: post_url,
        summary: summary
      }
    end.first(RESULTS_PER_TOPIC)
  rescue => e
    log("Failed to search Bluesky for '#{topic}': #{e.message}")
    []
  end

  def at_uri_to_url(at_uri, handle)
    # at://did:plc:abc123/app.bsky.feed.post/xyz789 → https://bsky.app/profile/handle/post/xyz789
    if at_uri.match?(%r{/app\.bsky\.feed\.post/})
      rkey = at_uri.split("/").last
      "https://bsky.app/profile/#{handle}/post/#{rkey}"
    else
      "https://bsky.app/profile/#{handle}"
    end
  end

  def request_with_retry(**params)
    attempts = 0
    begin
      attempts += 1
      response = HTTParty.get(
        "#{PDS_HOST}#{SEARCH_ENDPOINT}",
        query: params,
        headers: { "Authorization" => "Bearer #{@access_token}" },
        timeout: 15
      )

      unless response.success?
        raise "HTTP #{response.code} from Bluesky API"
      end

      response.parsed_response
    rescue => e
      if attempts <= MAX_RETRIES
        sleep_time = 2**attempts
        log("Bluesky API error: #{e.message}, retry #{attempts}/#{MAX_RETRIES} in #{sleep_time}s")
        sleep(sleep_time)
        retry
      end
      raise
    end
  end

  def log(message)
    if @logger
      @logger.log("[BlueskySource] #{message}")
    else
      puts "[BlueskySource] #{message}"
    end
  end
end
