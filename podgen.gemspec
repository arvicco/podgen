# frozen_string_literal: true

require_relative "lib/cli/version"

Gem::Specification.new do |spec|
  spec.name          = "podgen"
  spec.version       = PodgenCLI::VERSION
  spec.authors       = ["Podcast Agent"]
  spec.summary       = "Autonomous podcast generation pipeline"
  spec.description   = "Researches topics, writes a script, generates TTS audio, and assembles a final MP3 podcast episode."
  spec.homepage      = "https://github.com/your-user/podgen"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files         = Dir["lib/**/*.rb", "bin/*", "assets/.keep", "scripts/*.rb", "scripts/*.sh"]
  spec.bindir        = "bin"
  spec.executables   = ["podgen"]

  spec.add_dependency "dotenv"
  spec.add_dependency "anthropic"
  spec.add_dependency "exa-ai"
  spec.add_dependency "httparty"
  spec.add_dependency "rexml"
  spec.add_dependency "rss"
  spec.add_dependency "base64"
end
