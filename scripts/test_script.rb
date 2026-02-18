#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 3 test: Run the ScriptAgent with minimal research data
# Uses short mock research to keep API costs low during testing.

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "script_agent")

puts "=== Script Agent Test ==="
puts

# Mock research data (mimics ResearchAgent output)
research_data = [
  {
    topic: "AI developer tools and agent frameworks",
    findings: [
      {
        title: "OpenAI Agents SDK vs LangGraph: 2026 Comparison",
        url: "https://example.com/ai-agents",
        summary: "OpenAI released its Agents SDK in early 2026, offering a simpler alternative to LangGraph. The SDK focuses on tool use and handoffs between agents, while LangGraph provides more control over state management and complex workflows."
      },
      {
        title: "Claude Code and the Rise of Agentic Development",
        url: "https://example.com/claude-code",
        summary: "Anthropic's Claude Code CLI tool has become popular among developers for its ability to autonomously write, test, and debug code. It represents a shift toward AI agents that can handle multi-step software engineering tasks."
      }
    ]
  },
  {
    topic: "Ruby on Rails ecosystem updates",
    findings: [
      {
        title: "Rails 8 Authentication Generator",
        url: "https://example.com/rails-auth",
        summary: "Rails 8 introduces a built-in authentication generator that replaces the need for Devise in many projects. It generates a complete auth system with sessions, password resets, and email verification."
      }
    ]
  }
]

agent = ScriptAgent.new
script = agent.generate(research_data)

puts
puts "=== Generated Script ==="
puts "Title: #{script[:title]}"
puts "Segments: #{script[:segments].length}"
puts

script[:segments].each do |seg|
  puts "--- #{seg[:name]} (#{seg[:text].length} chars) ---"
  puts seg[:text][0..300]
  puts "..." if seg[:text].length > 300
  puts
end

puts "=== Test complete ==="
