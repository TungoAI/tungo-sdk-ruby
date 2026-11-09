# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = 'tungo-sdk'
  spec.version       = '0.1.0'
  spec.authors       = ['Tungo AI']
  spec.email         = ['dev@tungo.kz']
  spec.summary       = 'Official Ruby SDK for Tungo AI Platform API (1C AI Accountant, Automations, Webhooks)'
  spec.description   = 'Official zero-dependency Ruby SDK for the Tungo AI Platform API (https://api.tungo.kz).'
  spec.homepage      = 'https://tungo.kz'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'
  spec.metadata = {
    'homepage_uri' => 'https://tungo.kz',
    'source_code_uri' => 'https://github.com/TungoAI/tungo-sdk-ruby',
    'documentation_uri' => 'https://api.tungo.kz/docs',
    'bug_tracker_uri' => 'https://github.com/TungoAI/tungo-sdk-ruby/issues',
    'rubygems_mfa_required' => 'true'
  }
  spec.files         = Dir['lib/**/*.rb', 'README.md', 'LICENSE']
  spec.require_paths = ['lib']
end
